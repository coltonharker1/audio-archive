import Foundation
import GRDB

public enum LibraryError: LocalizedError, Equatable {
    case pathOutsideLibrary(String)

    public var errorDescription: String? {
        switch self {
        case .pathOutsideLibrary(let path): "\(path) is outside the library, so it wasn’t touched."
        }
    }
}

/// Reads the shelf and removes tapes.
public struct Library: Sendable {
    public let database: AppDatabase
    public let paths: LibraryPaths

    public init(database: AppDatabase, paths: LibraryPaths) {
        self.database = database
        self.paths = paths
    }

    /// The whole shelf, in catalog order, with new tapes after catalogued ones.
    public static func fetchShelf(_ db: Database) throws -> [ShelfTape] {
        let tapes = try Tape
            .order(sql: "catalog_number IS NULL, catalog_number, created_at")
            .fetchAll(db)
        let sources = try Source.order(Column("position")).fetchAll(db)
        let openingTracks = try Track.filter(sql: "start_marker_id IS NULL").fetchAll(db)

        let sourcesByTape = Dictionary(grouping: sources, by: \.tapeId)
        let nameBySource = Dictionary(
            openingTracks.map { ($0.sourceId, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        let statuses = try JobStore.statuses(db)
        let markerRows = try Row.fetchAll(db, sql: """
            SELECT s.tape_id, count(*) AS n FROM marker m
            JOIN source s ON s.id = m.source_id
            GROUP BY s.tape_id
            """)
        let markerCounts = Dictionary(uniqueKeysWithValues: markerRows.map { (row: Row) -> (Int64, Int) in (row["tape_id"], row["n"]) })

        return tapes.map { tape in
            let items = (sourcesByTape[tape.id ?? -1] ?? []).map { source in
                ShelfTape.Item(source: source, name: nameBySource[source.id ?? -1].flatMap(\.self) ?? tape.title)
            }
            return ShelfTape(
                tape: tape,
                items: items,
                status: statuses[tape.id ?? -1] ?? .idle,
                markerCount: markerCounts[tape.id ?? -1] ?? 0
            )
        }
    }

    /// A live stream of the shelf, updated whenever the library changes.
    public func shelfUpdates() -> AsyncValueObservation<[ShelfTape]> {
        ValueObservation.tracking(Self.fetchShelf).values(in: database.writer)
    }

    public func url(forLibraryPath path: String) throws -> URL {
        let root = paths.library.standardizedFileURL.path + "/"
        let url = paths.library.appending(path: path).standardizedFileURL
        guard url.path.hasPrefix(root) else { throw LibraryError.pathOutsideLibrary(path) }
        return url
    }

    /// Moves a tape's audio to the Trash and removes its rows.
    ///
    /// The Trash means a mistake can be undone from Finder. If any move fails, the
    /// rows are kept, so the library never forgets audio that still exists.
    public func delete(
        tapeID: Int64,
        trash: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) async throws {
        try await database.writer.write { db in
            let sources = try Source.filter(Column("tape_id") == tapeID).fetchAll(db)
            let stored = sources.flatMap { [$0.masterPath, $0.prepPath, $0.peaksPath].compactMap(\.self) }

            // Check every path before moving anything.
            let urls = try stored.map { try url(forLibraryPath: $0) }

            try db.execute(sql: "DELETE FROM tape WHERE id = ?", arguments: [tapeID])

            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try trash(url)
            }
            for directory in Set(urls.map { $0.deletingLastPathComponent() }) {
                let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
                if contents?.isEmpty == true { try? FileManager.default.removeItem(at: directory) }
            }
        }
    }
}
