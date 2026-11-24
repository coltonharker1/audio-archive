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
    public var adjustments: TrackAdjustments = .none
    /// Master seconds left out of the track at each end. `start` and `end` are the
    /// whole stretch between markers.
    public var cutStart: Double = 0
    public var cutEnd: Double = 0

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
                end: span.end,
                adjustments: track?.adjustments ?? .none,
                cutStart: track?.cutStart ?? 0,
                cutEnd: track?.cutEnd ?? 0
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
            // A cut stays on the same audio: the end's goes to the new track, and
            // whatever of either cut lies past the marker goes with it.
            let split = try Self.fetchReview(db, sourceID: sourceID)?.tracks
                .first { $0.start < time && time < $0.end && ($0.cutStart > 0 || $0.cutEnd > 0) }
            var marker = Marker(sourceId: sourceID, time: time)
            try marker.insert(db)
            var track = Track(sourceId: sourceID, startMarkerId: marker.id, name: trackName)
            if let split {
                track.cutStart = max(0, split.start + split.cutStart - time)
                track.cutEnd = split.cutEnd
                let before = try Self.trackRow(db, sourceID: sourceID, startMarkerID: split.markerID)
                try db.execute(
                    sql: "UPDATE track SET cut_start = ?, cut_end = ? WHERE id = ?",
                    arguments: [min(split.cutStart, time - split.start), max(0, time - (split.end - split.cutEnd)), before.id!]
                )
            }
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
            // The track before takes over the end of this one, cut and all.
            if let sourceID = try Int64.fetchOne(db, sql: "SELECT source_id FROM marker WHERE id = ?", arguments: [id]),
               let review = try Self.fetchReview(db, sourceID: sourceID),
               let index = review.tracks.firstIndex(where: { $0.markerID == id }), index > 0 {
                let previous = review.tracks[index - 1]
                let row = try Self.trackRow(db, sourceID: sourceID, startMarkerID: previous.markerID)
                try db.execute(sql: "UPDATE track SET cut_end = ? WHERE id = ?", arguments: [review.tracks[index].cutEnd, row.id!])
            }
            try db.execute(sql: "DELETE FROM marker WHERE id = ?", arguments: [id])
        }
    }

    /// Leaves seconds of master out at a track's start and end, measured in recording
    /// order. Nothing is cut from the master.
    public func setCuts(sourceID: Int64, startMarkerID: Int64?, start: Double, end: Double) async throws {
        try await database.writer.write { db in
            _ = try Self.editableTape(db, sourceID: sourceID)
            guard let review = try Self.fetchReview(db, sourceID: sourceID),
                  let span = review.tracks.first(where: { $0.markerID == startMarkerID }) else { throw AppendError.notFound }
            guard start >= 0, end >= 0, span.end - span.start - start - end >= Self.minimumKeptLength else {
                throw MarkerError.invalidTrim
            }
            let row = try Self.trackRow(db, sourceID: sourceID, startMarkerID: startMarkerID)
            try db.execute(sql: "UPDATE track SET cut_start = ?, cut_end = ? WHERE id = ?", arguments: [start, end, row.id!])
        }
    }

    /// The least of a track a cut can leave.
    public static let minimumKeptLength = 0.5

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
