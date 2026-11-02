import Foundation
import GRDB

/// One timed line from Whisper.
public struct TranscriptLine: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Segment: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var sourceId: Int64
    public var startTime: Double
    public var endTime: Double
    public var text: String
    public var edited: Bool = false

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The fields of a stored summary that the app shows.
public struct SummaryDetails: Decodable, Equatable, Sendable {
    public let summaryShort: String?
    public let summaryLong: String?
    public let people: [String]?
    public let places: [String]?
    public let organizations: [String]?
    public let tags: [String]?
    public let notableQuotes: [String]?

    enum CodingKeys: String, CodingKey {
        case summaryShort = "summary_short"
        case summaryLong = "summary_long"
        case people, places, organizations, tags
        case notableQuotes = "notable_quotes"
    }

    public var mentioned: [String] {
        var seen = Set<String>()
        return ((people ?? []) + (places ?? []) + (organizations ?? [])).filter { seen.insert($0).inserted }
    }
}

extension Track {
    public var summaryDetails: SummaryDetails? {
        summary.flatMap { try? JSONDecoder().decode(SummaryDetails.self, from: Data($0.utf8)) }
    }
}

/// A comparison transcript waiting for a decision.
public struct TranscriptCandidate: Equatable, Sendable {
    public let model: String
    public let lines: [TranscriptLine]
}

/// Everything the read-along screen shows for one source.
public struct ReadAlong: Equatable, Sendable {
    public let segments: [Segment]
    public let track: Track?
    public let transcriptModel: String?
    public let candidate: TranscriptCandidate?
    public let isComparing: Bool
}

/// The line playing at a given time, found quickly in a sorted list. Returns nil
/// before the first line. Between lines, the previous one stays current.
public func segmentIndex(at time: Double, in segments: [Segment]) -> Int? {
    var low = 0
    var high = segments.count - 1
    var found: Int?
    while low <= high {
        let middle = (low + high) / 2
        if segments[middle].startTime <= time {
            found = middle
            low = middle + 1
        } else {
            high = middle - 1
        }
    }
    return found
}

public enum TranscriptError: LocalizedError, Equatable {
    case emptyLine
    case noCandidate

    public var errorDescription: String? {
        switch self {
        case .emptyLine: "A line can’t be empty."
        case .noCandidate: "There’s no comparison transcript to use."
        }
    }
}

extension Library {
    public func readAlongUpdates(sourceID: Int64) -> AsyncValueObservation<ReadAlong> {
        ValueObservation.tracking { db -> ReadAlong in
            let segments = try Segment
                .filter(Column("source_id") == sourceID)
                .order(Column("start_time"), Column("id"))
                .fetchAll(db)
            let track = try Track
                .filter(Column("source_id") == sourceID)
                .filter(sql: "start_marker_id IS NULL")
                .fetchOne(db)
            let model = try String.fetchOne(db, sql: "SELECT transcript_model FROM source WHERE id = ?", arguments: [sourceID])

            var candidate: TranscriptCandidate?
            if let row = try Row.fetchOne(db, sql: "SELECT model, segments FROM transcript_candidate WHERE source_id = ?", arguments: [sourceID]) {
                let json: String = row["segments"]
                candidate = TranscriptCandidate(
                    model: row["model"],
                    lines: (try? JSONDecoder().decode([TranscriptLine].self, from: Data(json.utf8))) ?? []
                )
            }
            let isComparing = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM job WHERE source_id = ? AND candidate = 1 AND status IN ('pending', 'running'))",
                arguments: [sourceID]
            ) ?? false

            return ReadAlong(segments: segments, track: track, transcriptModel: model, candidate: candidate, isComparing: isComparing)
        }
        .values(in: database.writer)
    }

    /// Saves a corrected line. Its timing stays, so click-to-seek keeps working.
    public func updateSegment(id: Int64, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptError.emptyLine }
        try await database.writer.write { db in
            let current = try String.fetchOne(db, sql: "SELECT text FROM segment WHERE id = ?", arguments: [id])
            guard current != trimmed else { return }
            try db.execute(sql: "UPDATE segment SET text = ?, edited = 1 WHERE id = ?", arguments: [trimmed, id])
        }
    }

    public func setContext(tapeID: Int64, context: String) async throws {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE tape SET context = ? WHERE id = ?",
                arguments: [trimmed.isEmpty ? nil : trimmed, tapeID]
            )
        }
    }

    public func setApproved(tapeID: Int64, approved: Bool, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE tape SET approved_at = ? WHERE id = ?",
                arguments: [approved ? now : nil, tapeID]
            )
        }
    }

    /// Queues a summary for each of a tape's tracks. This is always something you
    /// ask for, because it uses Claude and tapes on the site have their own text.
    public func requestSummary(tapeID: Int64, now: Date = Date()) async throws {
        try await database.writer.write { db in
            let tracks = try Int64.fetchAll(db, sql: """
                SELECT t.id FROM track t
                JOIN source s ON s.id = t.source_id
                WHERE s.tape_id = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM job j WHERE j.track_id = t.id AND j.status IN ('pending', 'running'))
                """, arguments: [tapeID])
            for track in tracks {
                var job = Job.make(.summarize, trackID: track, now: now)
                try job.insert(db)
            }
        }
    }

    /// The model to compare against: whichever of base and medium wasn't used.
    public static func comparisonModel(for current: String?) -> String {
        current == "medium" ? "base" : "medium"
    }

    public func requestComparison(sourceID: Int64, model: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            let active = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM job WHERE source_id = ? AND candidate = 1 AND status IN ('pending', 'running'))",
                arguments: [sourceID]
            ) ?? false
            guard !active else { return }
            try db.execute(sql: "DELETE FROM transcript_candidate WHERE source_id = ?", arguments: [sourceID])
            var job = Job.make(.transcribe, sourceID: sourceID, model: model, now: now)
            job.candidate = true
            try job.insert(db)
        }
    }

    public func discardCandidate(sourceID: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM transcript_candidate WHERE source_id = ?", arguments: [sourceID])
        }
    }

    /// Replaces the transcript with the comparison. The view warns first if this
    /// would replace lines you corrected.
    public func adoptCandidate(sourceID: Int64) async throws {
        try await database.writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT model, segments FROM transcript_candidate WHERE source_id = ?", arguments: [sourceID]) else {
                throw TranscriptError.noCandidate
            }
            let json: String = row["segments"]
            let model: String = row["model"]
            let lines = try JSONDecoder().decode([TranscriptLine].self, from: Data(json.utf8))

            try db.execute(sql: "DELETE FROM segment WHERE source_id = ?", arguments: [sourceID])
            for line in lines {
                try db.execute(
                    sql: "INSERT INTO segment (source_id, start_time, end_time, text) VALUES (?, ?, ?, ?)",
                    arguments: [sourceID, line.start, line.end, line.text]
                )
            }
            try db.execute(sql: "UPDATE source SET transcript_model = ? WHERE id = ?", arguments: [model, sourceID])
            try db.execute(sql: "DELETE FROM transcript_candidate WHERE source_id = ?", arguments: [sourceID])
        }
    }
}

// MARK: Search

public struct SearchMoment: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let sourceID: Int64
    public let time: Double
    /// The line with its matching words marked between the highlight characters.
    public let snippet: String
}

public struct SearchTapeResult: Identifiable, Equatable, Sendable {
    public let tapeID: Int64
    public let title: String
    public let catalogNumber: String?
    public let medium: String?
    public let matchedDetails: Bool
    public let moments: [SearchMoment]

    public var id: Int64 { tapeID }
}

public enum SearchHighlight {
    public static let start = "\u{1}"
    public static let end = "\u{2}"
}

extension Library {
    /// Finds every moment a phrase was said, plus tapes whose details mention it.
    /// Words match by prefix as you type, and by word form, so "tornado" finds
    /// "tornadoes". Wrap text in quotes to match an exact phrase.
    public func search(_ text: String, limit: Int = 300) async throws -> [SearchTapeResult] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        return try await database.writer.read { db in
            let isQuoted = query.count > 2 && query.hasPrefix("\"") && query.hasSuffix("\"")
            let pattern = isQuoted
                ? FTS5Pattern(matchingPhrase: String(query.dropFirst().dropLast()))
                : FTS5Pattern(matchingAllPrefixesIn: query)

            var moments: [Int64: [SearchMoment]] = [:]
            if let pattern {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT g.id, g.source_id, g.start_time, s.tape_id,
                           snippet(segment_fts, 0, ?, ?, '…', 24) AS snippet
                    FROM segment_fts
                    JOIN segment g ON g.id = segment_fts.rowid
                    JOIN source s ON s.id = g.source_id
                    WHERE segment_fts MATCH ?
                    ORDER BY s.tape_id, s.position, g.start_time
                    LIMIT ?
                    """, arguments: [SearchHighlight.start, SearchHighlight.end, pattern, limit])
                for row in rows {
                    let tape: Int64 = row["tape_id"]
                    moments[tape, default: []].append(SearchMoment(
                        id: row["id"],
                        sourceID: row["source_id"],
                        time: row["start_time"],
                        snippet: row["snippet"]
                    ))
                }
            }

            let like = "%" + query.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            let detailMatches = Set(try Int64.fetchAll(db, sql: """
                SELECT id FROM tape
                WHERE title LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\' OR context LIKE ? ESCAPE '\\'
                """, arguments: [like, like, like]))

            let tapes = try Tape
                .order(sql: "catalog_number IS NULL, catalog_number, created_at")
                .fetchAll(db)
            return tapes.compactMap { tape in
                guard let id = tape.id else { return nil }
                let found = moments[id] ?? []
                guard !found.isEmpty || detailMatches.contains(id) else { return nil }
                return SearchTapeResult(
                    tapeID: id,
                    title: tape.title,
                    catalogNumber: tape.catalogNumber,
                    medium: tape.medium,
                    matchedDetails: detailMatches.contains(id),
                    moments: found
                )
            }
        }
    }
}

// MARK: Comparing transcripts

/// One place where two transcripts disagree.
public struct TranscriptChange: Identifiable, Equatable, Sendable {
    public let id: Int
    /// When this is said in the audio, for hearing it.
    public let time: Double
    public let before: String
    public let current: String
    public let candidate: String
    public let after: String
}

public enum TranscriptComparison {
    private struct Word {
        let text: String
        let normalized: String
        let time: Double
    }

    private static func words(_ lines: [(time: Double, text: String)]) -> [Word] {
        lines.flatMap { line in
            line.text.split(whereSeparator: \.isWhitespace).map { piece -> Word in
                let text = String(piece)
                let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber }
                return Word(text: text, normalized: normalized.isEmpty ? text : normalized, time: line.time)
            }
        }
    }

    /// Lists differences word by word, ignoring case and punctuation, which vary
    /// between models without changing what was heard. Nearby differences merge.
    public static func changes(
        current: [Segment],
        candidate: [TranscriptLine],
        contextWords: Int = 5,
        mergeGap: Int = 2
    ) -> [TranscriptChange] {
        let old = words(current.map { ($0.startTime, $0.text) })
        let new = words(candidate.map { ($0.start, $0.text) })
        let difference = new.map(\.normalized).difference(from: old.map(\.normalized))

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty else { return [] }

        // Walk both lists together, recording runs of difference on each side.
        var regions: [(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int)] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                let startI = i
                let startJ = j
                while removed.contains(i) || inserted.contains(j) {
                    if removed.contains(i) { i += 1 }
                    if inserted.contains(j) { j += 1 }
                }
                if let last = regions.last, startI - last.oldEnd <= mergeGap {
                    regions[regions.count - 1] = (last.oldStart, i, last.newStart, j)
                } else {
                    regions.append((startI, i, startJ, j))
                }
            } else {
                i += 1
                j += 1
            }
        }

        func text(_ list: [Word], _ range: Range<Int>) -> String {
            list[range].map(\.text).joined(separator: " ")
        }

        return regions.enumerated().map { index, region in
            let time: Double
            if region.oldStart < old.count {
                time = old[region.oldStart].time
            } else if region.newStart < new.count {
                time = new[region.newStart].time
            } else {
                time = old.last?.time ?? 0
            }
            return TranscriptChange(
                id: index,
                time: time,
                before: text(old, max(0, region.oldStart - contextWords)..<region.oldStart),
                current: text(old, region.oldStart..<region.oldEnd),
                candidate: text(new, region.newStart..<region.newEnd),
                after: text(old, region.oldEnd..<min(old.count, region.oldEnd + contextWords))
            )
        }
    }
}
