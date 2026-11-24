import Foundation
import GRDB

public enum SideError: LocalizedError, Equatable {
    case notFound
    case alreadyOnSite
    case lastSide
    case stillProcessing
    case emptyName
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "That recording isn’t in the library."
        case .alreadyOnSite: "This tape is on the site, so its recordings can’t be removed here."
        case .lastSide: "This is the tape’s only recording. Delete the tape instead."
        case .stillProcessing: "This recording is being processed right now. Try again when it finishes."
        case .emptyName: "A side needs a name, like A or B."
        case .nameTaken(let name): "This tape already has a side \(name)."
        }
    }
}

extension Library {
    /// Removes one recording from a tape: its audio goes to the Trash, so a mistake can
    /// be undone from Finder, and its transcript, markers and tracks go with it. The
    /// recordings after it move up.
    ///
    /// A tape's only recording stays unless `allowingLast`, which re-recording uses
    /// just before it records that side again.
    public func removeSide(
        sourceID: Int64,
        allowingLast: Bool = false,
        trash: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) async throws {
        try await database.writer.write { db in
            let (source, siblings) = try editableSide(db, sourceID)
            guard siblings.count > 1 || allowingLast else { throw SideError.lastSide }
            let running = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM job WHERE status = 'running'
                AND (source_id = ? OR track_id IN (SELECT id FROM track WHERE source_id = ?))
                """, arguments: [sourceID, sourceID]) ?? 0
            guard running == 0 else { throw SideError.stillProcessing }

            // Check every path before moving anything.
            let urls = try [source.masterPath, source.prepPath, source.peaksPath].compactMap(\.self).map { try url(forLibraryPath: $0) }

            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sourceID])
            for (position, sibling) in siblings.filter({ $0.id != sourceID }).enumerated() where sibling.position != position {
                try db.execute(sql: "UPDATE source SET position = ? WHERE id = ?", arguments: [position, sibling.id!])
            }

            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try trash(url)
            }
        }
    }

    /// Renames a side, like C to B. Its opening track follows when it still has the
    /// side's default name, such as "Side C".
    public func renameSide(sourceID: Int64, to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SideError.emptyName }
        try await database.writer.write { db in
            let (source, siblings) = try editableSide(db, sourceID)
            guard source.side != name else { return }
            guard !siblings.contains(where: { $0.id != sourceID && $0.side?.lowercased() == name.lowercased() }) else {
                throw SideError.nameTaken(name)
            }
            try db.execute(sql: "UPDATE source SET side = ? WHERE id = ?", arguments: [name, sourceID])
            if let old = source.side {
                try db.execute(
                    sql: "UPDATE track SET name = ? WHERE source_id = ? AND start_marker_id IS NULL AND name = ?",
                    arguments: ["Side \(name)", sourceID, "Side \(old)"]
                )
            }
        }
    }

    /// A side of a tape that isn't on the site yet, and every side of that tape.
    private func editableSide(_ db: Database, _ sourceID: Int64) throws -> (Source, [Source]) {
        guard let source = try Source.fetchOne(db, key: sourceID),
              let tape = try Tape.fetchOne(db, key: source.tapeId) else { throw SideError.notFound }
        guard tape.pushedAt == nil else { throw SideError.alreadyOnSite }
        let siblings = try Source.filter(Column("tape_id") == source.tapeId).order(Column("position")).fetchAll(db)
        return (source, siblings)
    }
}
