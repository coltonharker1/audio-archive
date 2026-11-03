import Foundation
import GRDB

public enum JobType: String, Codable, Sendable {
    case prep, transcribe, summarize, peaks

    /// How many of this type can run at once. Parallel Whisper runs were killed
    /// for running out of memory in the April 2026 batch, so it's limited to one.
    var limit: Int {
        switch self {
        case .prep, .summarize, .peaks: 2
        case .transcribe: 1
        }
    }

    var maxAttempts: Int {
        switch self {
        case .prep: 3
        case .transcribe, .summarize, .peaks: 2
        }
    }
}

public enum JobStatus: String, Codable, Sendable {
    case pending, running, complete, failed
}

public struct Job: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var sourceId: Int64?
    public var trackId: Int64?
    public var type: JobType
    public var status: JobStatus = .pending
    public var attempt: Int = 0
    public var maxAttempts: Int
    public var model: String?
    /// A comparison transcript, stored apart and never replacing the real one.
    public var candidate: Bool = false
    public var error: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var nextAttemptAt: Date?
    public var pid: Int32?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func make(_ type: JobType, sourceID: Int64? = nil, trackID: Int64? = nil, model: String? = nil, now: Date) -> Job {
        Job(sourceId: sourceID, trackId: trackID, type: type, maxAttempts: type.maxAttempts, model: model, createdAt: now)
    }
}

/// The durable job queue. Every rule lives in SQL against the `job` table, so
/// state survives a crash and the rules can be tested without running any tools.
public enum JobStore {
    /// Claims the next job that's ready, respecting order between stages and the
    /// limit for each type. Returns nil when nothing can start right now.
    public static func claimNext(_ db: Database, now: Date = Date()) throws -> Job? {
        let running = try Row.fetchAll(db, sql: "SELECT type, count(*) AS n FROM job WHERE status = 'running' GROUP BY type")
        var atLimit: [String] = []
        for row in running {
            let name: String = row["type"]
            if let type = JobType(rawValue: name), (row["n"] as Int) >= type.limit { atLimit.append(name) }
        }

        let excluded = atLimit.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
            SELECT j.* FROM job j
            LEFT JOIN track t ON t.id = j.track_id
            WHERE j.status = 'pending'
              AND (j.next_attempt_at IS NULL OR j.next_attempt_at <= ?)
              AND j.type NOT IN (\(excluded))
              AND CASE j.type
                WHEN 'transcribe' THEN NOT EXISTS (
                    SELECT 1 FROM job p WHERE p.source_id = j.source_id AND p.type = 'prep' AND p.status != 'complete')
                WHEN 'summarize' THEN NOT EXISTS (
                    SELECT 1 FROM job p WHERE p.source_id = t.source_id AND p.type = 'transcribe' AND p.candidate = 0 AND p.status != 'complete')
                ELSE 1 END
            ORDER BY j.id
            LIMIT 1
            """
        guard var job = try Job.fetchOne(db, sql: sql, arguments: [now]) else { return nil }
        job.status = .running
        job.attempt += 1
        job.startedAt = now
        job.nextAttemptAt = nil
        try job.update(db)
        return job
    }

    public static func recordPID(_ db: Database, jobID: Int64, pid: Int32) throws {
        try db.execute(sql: "UPDATE job SET pid = ? WHERE id = ?", arguments: [pid, jobID])
    }

    public static func complete(_ db: Database, jobID: Int64, now: Date = Date()) throws {
        try db.execute(
            sql: "UPDATE job SET status = 'complete', finished_at = ?, error = NULL, pid = NULL WHERE id = ?",
            arguments: [now, jobID]
        )
    }

    /// Records a failure. Retries with growing delays, then fails for good along
    /// with the later stages that depended on this one, so they don't waste retries.
    public static func fail(_ db: Database, jobID: Int64, message: String, now: Date = Date()) throws {
        guard let job = try Job.fetchOne(db, key: jobID) else { return }

        if job.attempt < job.maxAttempts {
            let delay = TimeInterval(job.attempt * 30)
            try db.execute(
                sql: "UPDATE job SET status = 'pending', error = ?, pid = NULL, next_attempt_at = ? WHERE id = ?",
                arguments: [message, now.addingTimeInterval(delay), jobID]
            )
            return
        }

        try db.execute(
            sql: "UPDATE job SET status = 'failed', error = ?, finished_at = ?, pid = NULL WHERE id = ?",
            arguments: [message, now, jobID]
        )

        // Nothing depends on a comparison, so its failure stays its own.
        guard let source = job.sourceId, !job.candidate else { return }
        let blocked = "Waiting on an earlier step that failed."
        if job.type == .prep {
            try db.execute(
                sql: "UPDATE job SET status = 'failed', error = ?, finished_at = ? WHERE status = 'pending' AND type = 'transcribe' AND source_id = ?",
                arguments: [blocked, now, source]
            )
        }
        try db.execute(
            sql: """
                UPDATE job SET status = 'failed', error = ?, finished_at = ?
                WHERE status = 'pending' AND type = 'summarize'
                  AND track_id IN (SELECT id FROM track WHERE source_id = ?)
                """,
            arguments: [blocked, now, source]
        )
    }

    /// Puts a job back when it was stopped rather than failing, such as on quit.
    /// Stopping isn't the job's fault, so the attempt doesn't count.
    public static func requeue(_ db: Database, jobID: Int64) throws {
        try db.execute(
            sql: "UPDATE job SET status = 'pending', attempt = max(attempt - 1, 0), started_at = NULL, pid = NULL WHERE id = ?",
            arguments: [jobID]
        )
    }

    /// Recovers after a crash or force-quit: jobs still marked running can't be,
    /// so they go back in the queue. Returns the process IDs they recorded.
    public static func resetInterrupted(_ db: Database) throws -> [Int32] {
        let pids = try Int32.fetchAll(db, sql: "SELECT pid FROM job WHERE status = 'running' AND pid IS NOT NULL")
        try db.execute(sql: """
            UPDATE job SET status = 'pending', attempt = max(attempt - 1, 0), started_at = NULL, pid = NULL
            WHERE status = 'running'
            """)
        return pids
    }

    /// Gives a tape's failed jobs a fresh start.
    public static func retry(_ db: Database, tapeID: Int64) throws {
        try db.execute(
            sql: """
                UPDATE job SET status = 'pending', attempt = 0, error = NULL, finished_at = NULL, next_attempt_at = NULL
                WHERE status = 'failed' AND (
                    source_id IN (SELECT id FROM source WHERE tape_id = ?)
                    OR track_id IN (SELECT t.id FROM track t JOIN source s ON s.id = t.source_id WHERE s.tape_id = ?)
                )
                """,
            arguments: [tapeID, tapeID]
        )
    }

    /// Adds transcription for sources that have never had any, without summaries.
    /// Tapes imported from the site already have descriptions there.
    public static func enqueueMissingTranscripts(_ db: Database, now: Date = Date(), hasModel: (String) -> Bool) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.id, s.prep_path, t.medium FROM source s
            JOIN tape t ON t.id = s.tape_id
            WHERE s.transcript_model IS NULL
              AND s.sha256 IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM job j WHERE j.source_id = s.id AND j.type = 'transcribe')
            ORDER BY s.id
            """)
        for row in rows {
            let source: Int64 = row["id"]
            let medium: String? = row["medium"]
            if (row["prep_path"] as String?) == nil {
                var prep = Job.make(.prep, sourceID: source, now: now)
                try prep.insert(db)
            }
            let model = WhisperModel.preferred(for: TapeFormat(medium: medium), hasModel: hasModel)
            var transcribe = Job.make(.transcribe, sourceID: source, model: model, now: now)
            try transcribe.insert(db)
        }
    }

    /// Adds waveform drawing for sources that don't have it yet. It has no
    /// dependencies, so a tape can be reviewed before it's been transcribed.
    public static func enqueueMissingPeaks(_ db: Database, now: Date = Date()) throws {
        let sources = try Int64.fetchAll(db, sql: """
            SELECT s.id FROM source s
            WHERE s.peaks_path IS NULL AND s.sha256 IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM job j WHERE j.source_id = s.id AND j.type = 'peaks')
            ORDER BY s.id
            """)
        for source in sources {
            var job = Job.make(.peaks, sourceID: source, now: now)
            try job.insert(db)
        }
    }

    /// Adds the whole pipeline for a newly added source.
    static func enqueuePipeline(_ db: Database, sourceID: Int64, trackID: Int64, model: String, now: Date) throws {
        var prep = Job.make(.prep, sourceID: sourceID, now: now)
        var transcribe = Job.make(.transcribe, sourceID: sourceID, model: model, now: now)
        var summarize = Job.make(.summarize, trackID: trackID, now: now)
        try prep.insert(db)
        try transcribe.insert(db)
        try summarize.insert(db)
    }

    /// Each tape's current state. Active work wins over a failure elsewhere on the
    /// tape, so the shelf shows what's happening now.
    static func statuses(_ db: Database) throws -> [Int64: TapeStatus] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT j.id, j.type, j.status, j.error, COALESCE(s.tape_id, ts.tape_id) AS tape_id
            FROM job j
            LEFT JOIN source s ON s.id = j.source_id
            LEFT JOIN track t ON t.id = j.track_id
            LEFT JOIN source ts ON ts.id = t.source_id
            WHERE j.status IN ('pending', 'running', 'failed')
            ORDER BY j.id
            """)

        var result: [Int64: TapeStatus] = [:]
        for row in rows {
            guard let tape: Int64 = row["tape_id"], let status = JobStatus(rawValue: row["status"]) else { continue }
            switch (status, result[tape]) {
            case (.running, _):
                if let type = JobType(rawValue: row["type"]) {
                    result[tape] = .working(type: type, jobID: row["id"])
                }
            case (.pending, .some(.working)):
                break
            case (.pending, _):
                result[tape] = .waiting
            case (.failed, nil):
                let error: String? = row["error"]
                result[tape] = .failed(error ?? "Something went wrong.")
            case (.failed, .some(.failed(let existing))) where existing.hasPrefix("Waiting on"):
                let error: String? = row["error"]
                result[tape] = .failed(error ?? existing)
            default:
                break
            }
        }
        return result
    }
}

public enum WhisperModel {
    /// Larger models improved clear sermons but made a phone call worse, because
    /// they can't recover bandwidth the audio doesn't have. So reels get medium and
    /// narrow formats get base, falling back to base if medium isn't installed.
    public static func preferred(for format: TapeFormat, hasModel: (String) -> Bool) -> String {
        switch format {
        case .sevenInchReel, .fiveInchReel: hasModel("medium") ? "medium" : "base"
        case .cassette, .microcassette, .unknown: "base"
        }
    }
}
