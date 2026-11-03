import Foundation
import GRDB

public struct Marker: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var sourceId: Int64
    public var time: Double
    public var origin: String = "manual"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum MarkerError: LocalizedError, Equatable {
    case outsideRecording
    case tooCloseToAnother
    case invalidTrim

    public var errorDescription: String? {
        switch self {
        case .outsideRecording: "That’s outside the recording."
        case .tooCloseToAnother: "There’s already a marker right there."
        case .invalidTrim: "The start has to come before the end."
        }
    }
}

/// One track as the review screen shows it.
public struct ReviewTrack: Identifiable, Equatable, Sendable {
    public let trackID: Int64?
    public let markerID: Int64?
    public let name: String?
    public let start: Double
    public let end: Double

    public var id: Double { start }
    public var duration: Double { end - start }
}

/// Everything the review screen shows for one source.
public struct Review: Equatable, Sendable {
    public let source: Source
    public let markers: [Marker]
    public let tracks: [ReviewTrack]

    public var trimStart: Double { source.trimStart }
    public var trimEnd: Double { source.trimEnd ?? source.duration }
}

extension Library {
    /// Markers closer than this would make a track too short to be meaningful.
    public static let minimumMarkerSpacing = 0.05

    public static func fetchReview(_ db: Database, sourceID: Int64) throws -> Review? {
        guard let source = try Source.fetchOne(db, key: sourceID) else { return nil }
        let markers = try Marker.filter(Column("source_id") == sourceID).order(Column("time")).fetchAll(db)
        let tracks = try Track.filter(Column("source_id") == sourceID).fetchAll(db)

        let timeByMarker = Dictionary(uniqueKeysWithValues: markers.compactMap { marker in
            marker.id.map { ($0, marker.time) }
        })
        var trackByStart: [Double?: Track] = [:]
        for track in tracks {
            trackByStart[track.startMarkerId.flatMap { timeByMarker[$0] }] = track
        }
        let markerByTime = Dictionary(markers.map { ($0.time, $0.id) }, uniquingKeysWith: { first, _ in first })

        let spans = trackSpans(
            duration: source.duration,
            trimStart: source.trimStart,
            trimEnd: source.trimEnd,
            markers: markers.map(\.time)
        )
        let review = spans.map { span in
            let track = trackByStart[span.startMarker]
            return ReviewTrack(
                trackID: track?.id,
                markerID: span.startMarker.flatMap { markerByTime[$0] } ?? nil,
                name: track?.name,
                start: span.start,
                end: span.end
            )
        }
        return Review(source: source, markers: markers, tracks: review)
    }

    public func reviewUpdates(sourceID: Int64) -> AsyncValueObservation<Review?> {
        ValueObservation.tracking { db in try Self.fetchReview(db, sourceID: sourceID) }
            .values(in: database.writer)
    }

    /// Adds a marker and the track it begins. Nothing is cut; the master stays whole.
    @discardableResult
    public func addMarker(sourceID: Int64, time: Double, trackName: String? = nil) async throws -> Int64 {
        try await database.writer.write { db in
            try Self.validate(db, sourceID: sourceID, time: time, ignoring: nil)
            var marker = Marker(sourceId: sourceID, time: time)
            try marker.insert(db)
            var track = Track(sourceId: sourceID, startMarkerId: marker.id, name: trackName)
            try track.insert(db)
            return marker.id!
        }
    }

    public func moveMarker(id: Int64, to time: Double) async throws {
        try await database.writer.write { db in
            guard let source = try Int64.fetchOne(db, sql: "SELECT source_id FROM marker WHERE id = ?", arguments: [id]) else { return }
            try Self.validate(db, sourceID: source, time: time, ignoring: id)
            try db.execute(sql: "UPDATE marker SET time = ? WHERE id = ?", arguments: [time, id])
        }
    }

    /// Removes a marker. Its track's audio goes back to the track before it.
    public func deleteMarker(id: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM marker WHERE id = ?", arguments: [id])
        }
    }

    public func renameTrack(id: Int64, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE track SET name = ? WHERE id = ?",
                arguments: [trimmed.isEmpty ? nil : trimmed, id]
            )
        }
    }

    /// Sets what to keep from a recording. Trimmed audio stays in the master.
    public func setTrim(sourceID: Int64, start: Double, end: Double?) async throws {
        try await database.writer.write { db in
            guard let duration = try Double.fetchOne(db, sql: "SELECT duration FROM source WHERE id = ?", arguments: [sourceID]) else { return }
            let upper = end ?? duration
            guard start >= 0, upper <= duration + 0.001, start < upper else { throw MarkerError.invalidTrim }
            try db.execute(
                sql: "UPDATE source SET trim_start = ?, trim_end = ? WHERE id = ?",
                arguments: [start, upper >= duration ? nil : upper, sourceID]
            )
        }
    }

    public func loadWaveform(path: String) async throws -> Waveform {
        let url = try url(forLibraryPath: path)
        return try await Task.detached(priority: .userInitiated) {
            try Waveform(encoded: Data(contentsOf: url, options: .mappedIfSafe))
        }.value
    }

    private static func validate(_ db: Database, sourceID: Int64, time: Double, ignoring: Int64?) throws {
        guard let duration = try Double.fetchOne(db, sql: "SELECT duration FROM source WHERE id = ?", arguments: [sourceID]),
              time > 0, time < duration else {
            throw MarkerError.outsideRecording
        }
        let nearby = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM marker WHERE source_id = ? AND abs(time - ?) < ? AND id IS NOT ?",
            arguments: [sourceID, time, minimumMarkerSpacing, ignoring]
        ) ?? 0
        guard nearby == 0 else { throw MarkerError.tooCloseToAnother }
    }
}
