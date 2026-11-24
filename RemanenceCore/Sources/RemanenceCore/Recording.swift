import Foundation
import GRDB

public struct Machine: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var name: String
    public var medium: String
    public var speeds: String
    public var inputName: String?
    public var knobNote: String?
    public var deviceUid: String?
    public var channelMode: String?

    public var speedOptions: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(speeds.utf8))) ?? []
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A new recording in progress: where its audio is going.
public struct CaptureTarget: Equatable, Sendable {
    public let tapeID: Int64
    public let sourceID: Int64
    public let url: URL
    public let side: String
}

extension Library {
    public func machines() async throws -> [Machine] {
        try await database.writer.read { db in try Machine.order(Column("id")).fetchAll(db) }
    }

    /// Remembers what worked last time on a machine.
    public func updateMachine(id: Int64, knobNote: String?, deviceUID: String?, channelMode: String?) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE machine SET knob_note = ?, device_uid = ?, channel_mode = ? WHERE id = ?",
                arguments: [knobNote, deviceUID, channelMode, id]
            )
        }
    }

    /// Creates the tape before any audio arrives, so a crash leaves a record that
    /// says a recording was underway and where to find it.
    public func beginCapture(
        machine: Machine?, title: String?, speed: String?, collectionID: Int64? = nil,
        excludingNumbers taken: Set<String> = [], now: Date = Date()
    ) async throws -> CaptureTarget {
        let uuid = UUID().uuidString
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try await database.writer.write { [paths] db in
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            var tape = Tape(
                uuid: uuid,
                title: name.isEmpty ? "Recording, \(formatter.string(from: now))" : name,
                medium: machine?.medium,
                machineId: machine?.id,
                speed: speed,
                titleIsProvisional: name.isEmpty,
                createdAt: now
            )
            // Its number is fixed now, so the box can be labelled while it's recording.
            tape.catalogNumber = try Self.nextCatalogNumber(db, excluding: taken)
            try tape.insert(db)
            // Filing it is a nicety. It never stops a recording from starting.
            if let collectionID, let id = tape.id {
                try? Self.setCollection(db, tapeID: id, collectionID: collectionID)
            }
            return try Self.addCaptureSource(db, paths: paths, tape: tape, side: "A", position: 0)
        }
    }

    /// Adds the next side to a tape being recorded.
    public func beginNextSide(tapeID: Int64) async throws -> CaptureTarget {
        try await database.writer.write { [paths] db in
            guard let tape = try Tape.fetchOne(db, key: tapeID) else { throw PipelineError.missingRecord }
            let sources = try Source.filter(Column("tape_id") == tapeID).fetchAll(db)
            let side = Self.nextSide(after: sources)
            let position = (sources.map(\.position).max() ?? -1) + 1
            return try Self.addCaptureSource(db, paths: paths, tape: tape, side: side, position: position)
        }
    }

    /// The side the next recording of a tape will be: the first letter none of its
    /// sides has, so deleted and renamed sides are filled in rather than repeated.
    public func nextSide(tapeID: Int64) async throws -> String {
        try await database.writer.read { db in
            Self.nextSide(after: try Source.filter(Column("tape_id") == tapeID).fetchAll(db))
        }
    }

    static func nextSide(after sources: [Source]) -> String {
        let used = Set(sources.compactMap { $0.side?.uppercased() })
        let letters = (65...90).map { String(UnicodeScalar(UInt8($0))) }
        return letters.first { !used.contains($0) } ?? "Z"
    }

    private static func addCaptureSource(_ db: Database, paths: LibraryPaths, tape: Tape, side: String, position: Int) throws -> CaptureTarget {
        // A side can be renamed, so its letter may already be some other file's name.
        // A recording always goes to a file that has never existed.
        let used = Set(try String.fetchAll(db, sql: "SELECT master_path FROM source"))
        var relative = "masters/\(tape.uuid)/side-\(side.lowercased()).caf"
        var take = 2
        while used.contains(relative) || FileManager.default.fileExists(atPath: paths.library.appending(path: relative).path) {
            relative = "masters/\(tape.uuid)/side-\(side.lowercased())-\(take).caf"
            take += 1
        }
        let url = paths.library.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var source = Source(tapeId: tape.id!, position: position, side: side, masterPath: relative, duration: 0)
        try source.insert(db)
        var track = Track(sourceId: source.id!, name: "Side \(side)")
        try track.insert(db)
        return CaptureTarget(tapeID: tape.id!, sourceID: source.id!, url: url, side: side)
    }

    /// Finishes a recording: protects the master, records its details, adds markers
    /// made during capture, and queues transcription. A summary waits until you ask,
    /// because the tracks aren't marked out yet.
    public func finishCapture(sourceID: Int64, markers: [Double] = []) async throws {
        guard let source = try await database.writer.read({ db in try Source.fetchOne(db, key: sourceID) }) else {
            throw PipelineError.missingRecord
        }
        try await finalize(source, markers: markers)
    }

    /// Recovers recordings cut off by a crash or power loss, which are still valid
    /// files. Returns the titles of any it found. Empty ones are cleared away.
    public func recoverInterruptedCaptures() async throws -> [String] {
        let interrupted = try await database.writer.read { db in
            try Source.filter(sql: "sha256 IS NULL").fetchAll(db)
        }
        var recovered: [String] = []
        for source in interrupted {
            // One unreadable file mustn't stop the others being recovered. It stays
            // as it is, and is tried again next launch.
            if let title = try? await finalize(source, markers: []) {
                recovered.append(title)
            }
        }
        return recovered
    }

    @discardableResult
    private func finalize(_ source: Source, markers: [Double]) async throws -> String? {
        guard let sourceID = source.id else { return nil }
        let url = try url(forLibraryPath: source.masterPath)
        let tapeID = source.tapeId

        // Anything beyond a header-only file has audio worth keeping.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let header = Int64(CaptureFile.header(sampleRate: 48000, channels: 1).data.count)
        guard size > header else {
            try? FileManager.default.removeItem(at: url)
            let folder = url.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sourceID])
                let remaining = try Source.filter(Column("tape_id") == tapeID).fetchCount(db)
                if remaining == 0 { try db.execute(sql: "DELETE FROM tape WHERE id = ?", arguments: [tapeID]) }
            }
            return nil
        }

        let details = try await probeAudio(url)
        let hash = try sha256(of: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        return try await database.writer.write { db in
            let tape = try Tape.fetchOne(db, key: tapeID)
            // The rule against importing the same audio twice must never block saving
            // a recording. Two blank sides can really be identical, so a repeat is
            // kept, with its hash marked so it stays unique.
            let exists = try Source.filter(Column("sha256") == hash).fetchCount(db) > 0
            let storedHash = exists ? "\(hash)#\(sourceID)" : hash
            try db.execute(
                sql: "UPDATE source SET sha256 = ?, duration = ?, sample_rate = ?, channels = ?, bit_depth = ? WHERE id = ?",
                arguments: [storedHash, details.duration, details.sampleRate, details.channels, details.bitDepth, sourceID]
            )
            for time in markers where time > 0 && time < details.duration {
                var marker = Marker(sourceId: sourceID, time: time)
                try marker.insert(db)
                var track = Track(sourceId: sourceID, startMarkerId: marker.id)
                try track.insert(db)
            }
            let model = WhisperModel.preferred(for: TapeFormat(medium: tape?.medium)) { [paths] name in
                FileManager.default.fileExists(atPath: paths.models.appending(path: "ggml-\(name).en.bin").path)
            }
            let now = Date()
            var prep = Job.make(.prep, sourceID: sourceID, now: now)
            var transcribe = Job.make(.transcribe, sourceID: sourceID, model: model, now: now)
            var peaks = Job.make(.peaks, sourceID: sourceID, now: now)
            try prep.insert(db)
            try transcribe.insert(db)
            try peaks.insert(db)
            return tape?.title
        }
    }
}
