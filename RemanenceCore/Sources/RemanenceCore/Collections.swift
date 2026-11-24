import Foundation
import GRDB

/// Reels that came in the same box, which together say something about whoever kept
/// them. Named and written up however the owner likes; it never names a real person.
public struct TapeCollection: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "collection"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var uuid: String
    public var name: String
    /// Its address on the site, like `the-cable-man`. Follows the name.
    public var slug: String
    /// The write-up.
    public var description: String?
    public var whereFound: String?
    public var dateFound: String?
    public var createdAt: Date
    /// The site's clock for it, from the last time the app read or wrote it. Nil
    /// until it's been pushed.
    public var siteUpdatedAt: String?
    /// Whether it's public on the site. Its address is fixed while it is.
    public var sitePublished: Bool = false
    /// What was last sent, as JSON, to tell whether there's anything new to send.
    public var siteSent: String?
    /// Tapes the site didn't have when it was last sent, as a JSON list of UUIDs.
    public var siteMissingReels: String?

    public var isOnSite: Bool { siteUpdatedAt != nil }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A photo of a collection's box, its labels or anything that came with it.
public struct CollectionImage: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "collection_image"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var collectionId: Int64
    public var position: Int
    public var path: String
    public var sha256: String
    public var filename: String
    public var caption: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A collection with its reels in the owner's order, and its photos.
public struct ShelfCollection: Identifiable, Hashable, Sendable {
    public let collection: TapeCollection
    public let tapeIDs: [Int64]
    public let images: [CollectionImage]
    /// What a push would send now.
    public var content: SiteCollectionContent? = nil

    public var id: Int64 { collection.id ?? 0 }

    /// On the site, with something here it doesn't have yet.
    public var hasUnsentChanges: Bool {
        guard collection.isOnSite, let content else { return false }
        return content.encoded != collection.siteSent
    }

    /// Reels the site didn't have when the collection was last sent.
    public var missingReelCount: Int {
        guard let data = collection.siteMissingReels?.data(using: .utf8),
              let uuids = try? JSONDecoder().decode([String].self, from: data) else { return 0 }
        return uuids.count
    }
}

/// The parts of a collection written in the app.
public struct CollectionFields: Equatable, Sendable {
    public var name: String
    public var description: String
    public var whereFound: String
    public var dateFound: String

    public init(_ collection: TapeCollection) {
        name = collection.name
        description = collection.description ?? ""
        whereFound = collection.whereFound ?? ""
        dateFound = collection.dateFound ?? ""
    }
}

public enum CollectionError: LocalizedError, Equatable {
    case notFound
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .notFound: "That collection isn’t in the library anymore."
        case .emptyName: "A collection needs a name."
        }
    }
}

extension Library {
    /// Every collection, by name, each with its reels in order.
    public static func fetchCollections(_ db: Database) throws -> [ShelfCollection] {
        let collections = try TapeCollection.order(sql: "name COLLATE NOCASE").fetchAll(db)
        let members = try Row.fetchAll(db, sql: """
            SELECT id, collection_id FROM tape WHERE collection_id IS NOT NULL
            ORDER BY collection_position, created_at
            """)
        var tapes: [Int64: [Int64]] = [:]
        for row in members { tapes[row["collection_id"], default: []].append(row["id"]) }
        let images = Dictionary(grouping: try CollectionImage.order(Column("position")).fetchAll(db), by: \.collectionId)
        let uuids = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, uuid FROM tape").map { row in
            (row["id"] as Int64, row["uuid"] as String)
        })
        return collections.map { collection in
            let ids = tapes[collection.id ?? -1] ?? []
            let photos = images[collection.id ?? -1] ?? []
            return ShelfCollection(
                collection: collection,
                tapeIDs: ids,
                images: photos,
                content: SiteCollectionContent(collection, images: photos, reels: ids.compactMap { uuids[$0] })
            )
        }
    }

    public func collectionUpdates() -> AsyncValueObservation<[ShelfCollection]> {
        ValueObservation.tracking(Self.fetchCollections).values(in: database.writer)
    }

    /// Makes a new, empty collection.
    @discardableResult
    public func createCollection(name: String, now: Date = Date()) async throws -> Int64 {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CollectionError.emptyName }
        return try await database.writer.write { db in
            var collection = TapeCollection(
                uuid: UUID().uuidString,
                name: name,
                slug: try Self.uniqueSlug(db, for: name, ignoring: nil),
                createdAt: now
            )
            try collection.insert(db)
            return collection.id!
        }
    }

    /// Saves what's written for a collection. A new name gives it a new address.
    public func saveCollection(id: Int64, fields: CollectionFields) async throws {
        try await database.writer.write { db in
            guard var collection = try TapeCollection.fetchOne(db, key: id) else { throw CollectionError.notFound }
            let name = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != collection.name {
                collection.name = name
                // A published collection keeps its address, so links to it still work.
                if !collection.sitePublished {
                    collection.slug = try Self.uniqueSlug(db, for: name, ignoring: id)
                }
            }
            collection.description = Self.blank(fields.description)
            collection.whereFound = Self.blank(fields.whereFound)
            collection.dateFound = Self.blank(fields.dateFound)
            try collection.update(db)
        }
    }

    /// Removes a collection. Its reels stay on the shelf, outside any collection, and
    /// its photos go to the Trash.
    public func deleteCollection(
        id: Int64,
        trash: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) async throws {
        try await database.writer.write { db in
            let paths = try String.fetchAll(db, sql: "SELECT path FROM collection_image WHERE collection_id = ?", arguments: [id])
            let urls = try paths.map { try url(forLibraryPath: $0) }
            try db.execute(sql: "UPDATE tape SET collection_position = NULL WHERE collection_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM collection WHERE id = ?", arguments: [id])
            for url in urls where FileManager.default.fileExists(atPath: url.path) { try trash(url) }
            for directory in Set(urls.map { $0.deletingLastPathComponent() }) {
                let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
                if contents?.isEmpty == true { try? FileManager.default.removeItem(at: directory) }
            }
        }
    }

    /// Puts a tape in a collection, at the end of it, or takes it out with `nil`.
    public func setCollection(tapeID: Int64, collectionID: Int64?) async throws {
        try await database.writer.write { db in
            try Self.setCollection(db, tapeID: tapeID, collectionID: collectionID)
        }
    }

    static func setCollection(_ db: Database, tapeID: Int64, collectionID: Int64?) throws {
        guard let current = try Tape.fetchOne(db, key: tapeID) else { throw CollectionError.notFound }
        guard current.collectionId != collectionID else { return }
        guard let collectionID else {
            try db.execute(sql: "UPDATE tape SET collection_id = NULL, collection_position = NULL WHERE id = ?", arguments: [tapeID])
            return
        }
        guard try TapeCollection.fetchOne(db, key: collectionID) != nil else { throw CollectionError.notFound }
        let last = try Double.fetchOne(db, sql: "SELECT max(collection_position) FROM tape WHERE collection_id = ?", arguments: [collectionID])
        try db.execute(
            sql: "UPDATE tape SET collection_id = ?, collection_position = ? WHERE id = ?",
            arguments: [collectionID, (last ?? -1) + 1, tapeID]
        )
    }

    /// Moves a tape to a new place in its collection, counted among the others.
    public func moveInCollection(tapeID: Int64, to place: Int) async throws {
        try await database.writer.write { db in
            guard let collectionID = try Int64.fetchOne(db, sql: "SELECT collection_id FROM tape WHERE id = ?", arguments: [tapeID]) else {
                throw CollectionError.notFound
            }
            var order = try Self.fetchCollections(db).first { $0.id == collectionID }?.tapeIDs ?? []
            order.removeAll { $0 == tapeID }
            order.insert(tapeID, at: max(0, min(order.count, place)))
            for (index, id) in order.enumerated() {
                try db.execute(sql: "UPDATE tape SET collection_position = ? WHERE id = ?", arguments: [Double(index), id])
            }
        }
    }

    /// A tape's collection, if it's in one.
    static func collection(_ db: Database, of tape: Tape) throws -> TapeCollection? {
        guard let id = tape.collectionId else { return nil }
        return try TapeCollection.fetchOne(db, key: id)
    }

    // MARK: Photos

    /// Copies a photo into the library, as for a tape's photos.
    @discardableResult
    public func addImage(collectionID: Int64, from source: URL) async throws -> CollectionImage {
        guard let uuid = try await database.writer.read({ db in
            try String.fetchOne(db, sql: "SELECT uuid FROM collection WHERE id = ?", arguments: [collectionID])
        }) else { throw CollectionError.notFound }

        let folder = paths.images.appending(path: "collections/\(uuid)", directoryHint: .isDirectory)
        let prepared = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try Self.prepareImage(source, in: folder)
        }.value

        do {
            return try await database.writer.write { db in
                if try CollectionImage.filter(Column("collection_id") == collectionID && Column("sha256") == prepared.sha256).fetchCount(db) > 0 {
                    throw ImageImportError.alreadyAdded(source.lastPathComponent)
                }
                let next = try Int.fetchOne(db, sql: "SELECT coalesce(max(position), -1) + 1 FROM collection_image WHERE collection_id = ?", arguments: [collectionID]) ?? 0
                var image = CollectionImage(
                    collectionId: collectionID,
                    position: next,
                    path: "images/collections/\(uuid)/\(prepared.url.lastPathComponent)",
                    sha256: prepared.sha256,
                    filename: source.deletingPathExtension().lastPathComponent + "." + prepared.url.pathExtension
                )
                try image.insert(db)
                return image
            }
        } catch ImageImportError.alreadyAdded(let name) {
            throw ImageImportError.alreadyAdded(name)
        } catch {
            try? FileManager.default.removeItem(at: prepared.url)
            throw error
        }
    }

    public func removeCollectionImage(id: Int64) async throws {
        let path: String? = try await database.writer.write { db in
            guard let image = try CollectionImage.fetchOne(db, key: id) else { return nil }
            try image.delete(db)
            try db.execute(sql: """
                UPDATE collection_image SET position = position - 1 WHERE collection_id = ? AND position > ?
                """, arguments: [image.collectionId, image.position])
            return image.path
        }
        if let path { try? FileManager.default.removeItem(at: try url(forLibraryPath: path)) }
    }

    public func setCollectionCaption(imageID: Int64, caption: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE collection_image SET caption = ? WHERE id = ?", arguments: [Self.blank(caption), imageID])
        }
    }

    /// Moves a photo earlier (-1) or later (+1).
    public func moveCollectionImage(id: Int64, by offset: Int) async throws {
        try await database.writer.write { db in
            guard let image = try CollectionImage.fetchOne(db, key: id) else { return }
            var images = try CollectionImage.filter(Column("collection_id") == image.collectionId).order(Column("position")).fetchAll(db)
            guard let index = images.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard images.indices.contains(target) else { return }
            images.swapAt(index, target)
            for (position, var item) in images.enumerated() where item.position != position {
                item.position = position
                try item.update(db)
            }
        }
    }

    // MARK: Helpers

    /// An address made from a name: lowercase words joined by hyphens, numbered if
    /// another collection already has it.
    static func uniqueSlug(_ db: Database, for name: String, ignoring id: Int64?) throws -> String {
        let base = slug(for: name)
        var candidate = base
        var number = 2
        while let other = try Int64.fetchOne(db, sql: "SELECT id FROM collection WHERE slug = ?", arguments: [candidate]), other != id {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    static func slug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        let words = folded.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let joined = words.joined(separator: "-")
        return joined.isEmpty ? "collection" : String(joined.prefix(80))
    }

    private static func blank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
