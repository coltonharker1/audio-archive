import Foundation
import GRDB

public enum AppendError: LocalizedError, Equatable {
    case notFound
    case alreadyOnSite
    case differentTapes
    case ontoItself

    public var errorDescription: String? {
        switch self {
        case .notFound: "That track isn’t in the library anymore."
        case .alreadyOnSite: "This tape is on the site, so its tracks can’t be joined here."
        case .differentTapes: "Tracks can only be appended to tracks on the same tape."
        case .ontoItself: "A track can’t be appended to itself, or to a track already appended to it."
        }
    }
}

extension Library {
    /// Appends a track, and anything already appended to it, to the end of another
    /// track, so they play as one track on the site. Nothing is cut or copied: each
    /// piece stays where it is on its recording, with its own settings.
    public func appendTrack(
        sourceID: Int64, startMarkerID: Int64?,
        to targetSourceID: Int64, targetMarkerID: Int64?
    ) async throws {
        try await database.writer.write { db in
            let moving = try Self.trackRow(db, sourceID: sourceID, startMarkerID: startMarkerID)
            let target = try Self.trackRow(db, sourceID: targetSourceID, startMarkerID: targetMarkerID)
            let tapes = try Int64.fetchAll(db, sql: "SELECT DISTINCT tape_id FROM source WHERE id IN (?, ?)", arguments: [sourceID, targetSourceID])
            guard tapes.count == 1, let tapeID = tapes.first else { throw AppendError.differentTapes }
            guard try Tape.fetchOne(db, key: tapeID)?.pushedAt == nil else { throw AppendError.alreadyOnSite }

            guard moving.id != target.id else { throw AppendError.ontoItself }
            let parents = try Self.appendParents(db, tapeID: tapeID)
            // The target's whole track: climb to its head, then follow to the end.
            var head = target.id!
            var seen: Set<Int64> = [head]
            while let parent = parents[head], seen.insert(parent).inserted { head = parent }
            guard head != moving.id!, !Self.isBelow(target.id!, moving.id!, parents: parents) else { throw AppendError.ontoItself }

            var children: [Int64: [Int64]] = [:]
            for (child, parent) in parents { children[parent, default: []].append(child) }
            // A piece that's moving takes what follows it along, so it isn't the end.
            var last = head
            while let next = children[last]?.filter({ $0 != moving.id! }).min() { last = next }
            guard last != moving.id! else { throw AppendError.ontoItself }

            try db.execute(sql: "UPDATE track SET appended_to_track_id = ? WHERE id = ?", arguments: [last, moving.id!])
        }
    }

    /// Makes an appended piece a track of its own again. Anything appended after it
    /// stays with the track it was part of.
    public func detachTrack(sourceID: Int64, startMarkerID: Int64?) async throws {
        try await database.writer.write { db in
            let track = try Self.trackRow(db, sourceID: sourceID, startMarkerID: startMarkerID)
            _ = try Self.editableTape(db, sourceID: sourceID)
            try Self.detach(db, track)
        }
    }

    /// Moves a track to a new place on the site, counted among the tape's tracks
    /// without it. A piece appended to another track becomes a track of its own there,
    /// as Detach makes it. A track's own appended pieces come with it.
    public func moveTrack(sourceID: Int64, startMarkerID: Int64?, to place: Int) async throws {
        try await database.writer.write { db in
            let tapeID = try Self.editableTape(db, sourceID: sourceID)
            let moving = try Self.trackRow(db, sourceID: sourceID, startMarkerID: startMarkerID)
            if moving.appendedToTrackId != nil { try Self.detach(db, moving) }
            guard let post = try Self.fetchPost(db, tapeID: tapeID) else { throw AppendError.notFound }
            var heads = post.tracks.map { (sourceID: $0.sourceID, markerID: $0.startMarkerID) }
            heads.removeAll { $0.sourceID == sourceID && $0.markerID == startMarkerID }
            heads.insert((sourceID, startMarkerID), at: max(0, min(heads.count, place)))
            for (index, head) in heads.enumerated() {
                let row = try Self.trackRow(db, sourceID: head.sourceID, startMarkerID: head.markerID)
                try db.execute(sql: "UPDATE track SET sort_index = ? WHERE id = ?", arguments: [Double(index), row.id!])
            }
        }
    }

    /// The tape a recording is on, if it can still be changed.
    static func editableTape(_ db: Database, sourceID: Int64) throws -> Int64 {
        guard let tapeID = try Int64.fetchOne(db, sql: "SELECT tape_id FROM source WHERE id = ?", arguments: [sourceID]) else {
            throw AppendError.notFound
        }
        guard try Tape.fetchOne(db, key: tapeID)?.pushedAt == nil else { throw AppendError.alreadyOnSite }
        return tapeID
    }

    private static func detach(_ db: Database, _ track: Track) throws {
        try db.execute(
            sql: "UPDATE track SET appended_to_track_id = ? WHERE appended_to_track_id = ?",
            arguments: [track.appendedToTrackId, track.id!]
        )
        try db.execute(sql: "UPDATE track SET appended_to_track_id = NULL WHERE id = ?", arguments: [track.id!])
    }

    /// The track row for a span, made if it doesn't have one yet.
    static func trackRow(_ db: Database, sourceID: Int64, startMarkerID: Int64?) throws -> Track {
        guard try Source.fetchOne(db, key: sourceID) != nil else { throw AppendError.notFound }
        if let row = try Track
            .filter(Column("source_id") == sourceID)
            .filter(startMarkerID == nil ? Column("start_marker_id") == nil : Column("start_marker_id") == startMarkerID)
            .fetchOne(db) {
            return row
        }
        var row = Track(sourceId: sourceID, startMarkerId: startMarkerID)
        try row.insert(db)
        return row
    }

    static func appendParents(_ db: Database, tapeID: Int64) throws -> [Int64: Int64] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id, t.appended_to_track_id FROM track t JOIN source s ON s.id = t.source_id
            WHERE s.tape_id = ? AND t.appended_to_track_id IS NOT NULL
            """, arguments: [tapeID])
        return Dictionary(rows.map { ($0["id"] as Int64, $0["appended_to_track_id"] as Int64) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether `id` is somewhere after `ancestor` in its track.
    private static func isBelow(_ id: Int64, _ ancestor: Int64, parents: [Int64: Int64]) -> Bool {
        var seen: Set<Int64> = [id]
        var current = id
        while let parent = parents[current], seen.insert(parent).inserted {
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }
}
