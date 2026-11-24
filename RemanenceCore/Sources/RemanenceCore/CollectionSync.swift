import Foundation
import GRDB

/// What's sent to the site for a collection, apart from its clock and whether it's
/// published. Kept as JSON after each push, so the app can tell when there's
/// something new to send.
public struct SiteCollectionContent: Codable, Equatable, Hashable, Sendable {
    public struct Image: Codable, Equatable, Hashable, Sendable {
        public let sha256: String
        public let filename: String
        public let caption: String?
    }

    public let uuid: String
    public let name: String
    public let slug: String
    public let description: String?
    public let whereFound: String?
    public let dateFound: String?
    public let images: [Image]
    /// Its reels by tape UUID, in order.
    public let reels: [String]

    public init(_ collection: TapeCollection, images: [CollectionImage], reels: [String]) {
        uuid = collection.uuid.lowercased()
        name = collection.name
        slug = collection.slug
        description = collection.description
        whereFound = collection.whereFound
        dateFound = collection.dateFound
        self.images = images.map { Image(sha256: $0.sha256, filename: $0.filename, caption: $0.caption) }
        self.reels = reels.map { $0.lowercased() }
    }

    /// The same content always gives the same text.
    public var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// A collection as sent to the site.
public struct SiteCollectionPush: Encodable, Equatable, Sendable {
    public let content: SiteCollectionContent
    /// The collection's clock from the last time the app read or wrote it, or nil
    /// for a collection the site doesn't have yet.
    public let expectedUpdatedAt: String?
    public let published: Bool?

    enum CodingKeys: String, CodingKey {
        case uuid, name, slug, description, whereFound, dateFound, images, reels, expectedUpdatedAt, published
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content.uuid, forKey: .uuid)
        try container.encode(content.name, forKey: .name)
        try container.encode(content.slug, forKey: .slug)
        try container.encode(content.description, forKey: .description)
        try container.encode(content.whereFound, forKey: .whereFound)
        try container.encode(content.dateFound, forKey: .dateFound)
        try container.encode(content.images, forKey: .images)
        try container.encode(content.reels, forKey: .reels)
        // The site tells a new collection from a stale one by this being null.
        try container.encode(expectedUpdatedAt, forKey: .expectedUpdatedAt)
        try container.encodeIfPresent(published, forKey: .published)
    }
}

/// A collection as the site has it.
public struct SiteCollectionState: Decodable, Equatable, Sendable {
    public struct Image: Decodable, Equatable, Sendable {
        public let url: String
        public let filename: String?
        public let caption: String?
        public let sha256: String?
    }

    public struct Reel: Decodable, Equatable, Sendable {
        public let tapeUuid: String?
        public let catalogNumber: String
        public let published: Bool
    }

    public let uuid: String
    public let slug: String
    public let name: String
    public let published: Bool
    public let updatedAt: String
    public let images: [Image]
    public let reels: [Reel]
    public var missingReels: [String] = []

    enum CodingKeys: String, CodingKey {
        case uuid, slug, name, published, updatedAt, images, reels, missingReels
    }

    public init(uuid: String, slug: String, name: String, published: Bool, updatedAt: String,
                images: [Image] = [], reels: [Reel] = [], missingReels: [String] = []) {
        self.uuid = uuid
        self.slug = slug
        self.name = name
        self.published = published
        self.updatedAt = updatedAt
        self.images = images
        self.reels = reels
        self.missingReels = missingReels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        published = try container.decode(Bool.self, forKey: .published)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        images = try container.decodeIfPresent([Image].self, forKey: .images) ?? []
        reels = try container.decodeIfPresent([Reel].self, forKey: .reels) ?? []
        missingReels = try container.decodeIfPresent([String].self, forKey: .missingReels) ?? []
    }
}

public enum CollectionSyncError: LocalizedError, Equatable {
    case notOnSite

    public var errorDescription: String? {
        switch self {
        case .notOnSite: "This collection isn’t on the site."
        }
    }
}

extension Library {
    /// What a push of a collection would send now.
    func collectionContent(id: Int64) async throws -> (content: SiteCollectionContent, collection: TapeCollection, images: [CollectionImage]) {
        try await database.writer.read { db in
            guard let shelf = try Self.fetchCollections(db).first(where: { $0.id == id }), let content = shelf.content else {
                throw CollectionError.notFound
            }
            return (content, shelf.collection, shelf.images)
        }
    }

    /// Remembers what the site has after a push.
    func recordCollectionSent(id: Int64, state: SiteCollectionState, content: SiteCollectionContent) async throws {
        let missing = String(decoding: try JSONEncoder().encode(state.missingReels), as: UTF8.self)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE collection SET site_updated_at = ?, site_published = ?, site_sent = ?, site_missing_reels = ?, slug = ?
                    WHERE id = ?
                    """,
                arguments: [state.updatedAt, state.published, content.encoded, missing, state.slug, id]
            )
        }
    }

    /// Forgets that a collection is on the site, after it's removed there.
    func forgetCollectionOnSite(id: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE collection SET site_updated_at = NULL, site_published = 0, site_sent = NULL, site_missing_reels = NULL WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// The collection a tape is in, if that collection is on the site.
    public func collectionOnSite(tapeID: Int64) async throws -> Int64? {
        try await database.writer.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT c.id FROM collection c JOIN tape t ON t.collection_id = c.id
                WHERE t.id = ? AND c.site_updated_at IS NOT NULL
                """, arguments: [tapeID])
        }
    }
}

extension Pusher {
    /// Sends a collection to the site, whole: what's written, its photos and its reels
    /// in order. New photos are uploaded first. `publish` changes whether it's public;
    /// nil leaves that as it is, and a new collection starts unpublished.
    ///
    /// The app is the only place collections are written, so if the site's clock has
    /// moved on (a push whose answer was lost, say), it's read again and the push is
    /// made once more rather than refused.
    @discardableResult
    public func pushCollection(
        id: Int64, publish: Bool? = nil,
        progress: @escaping @Sendable (PushProgress) -> Void = { _ in }
    ) async throws -> SiteCollectionState {
        let (content, collection, images) = try await library.collectionContent(id: id)

        progress(.checking)
        let files = try images.map { image in
            let url = try library.url(forLibraryPath: image.path)
            return try describe(url, filename: image.filename, contentType: url.pathExtension == "png" ? "image/png" : "image/jpeg", kind: .image)
        }
        let existing = try await site.existingFiles(files.map(\.sha256))
        let missing = files.filter { !existing.contains($0.sha256) }
        for (index, file) in missing.enumerated() {
            let report: @Sendable (Double) -> Void = { fraction in
                progress(.uploading(file: index + 1, of: missing.count, fraction: fraction))
            }
            report(0)
            try await send(file, progress: report)
        }

        progress(.creating)
        var expected = collection.siteUpdatedAt
        var state: SiteCollectionState
        do {
            state = try await site.saveCollection(SiteCollectionPush(content: content, expectedUpdatedAt: expected, published: publish))
        } catch SiteError.changedOnSite {
            expected = try await site.fetchCollection(uuid: content.uuid).updatedAt
            state = try await site.saveCollection(SiteCollectionPush(content: content, expectedUpdatedAt: expected, published: publish))
        } catch SiteError.server(404, _) where expected != nil {
            // Removed on the site since: send it as new.
            state = try await site.saveCollection(SiteCollectionPush(content: content, expectedUpdatedAt: nil, published: publish))
        }
        try await library.recordCollectionSent(id: id, state: state, content: content)
        return state
    }

    /// Removes a collection from the site. Its reels stay there, outside any collection.
    public func deleteCollectionFromSite(id: Int64) async throws {
        let (content, collection, _) = try await library.collectionContent(id: id)
        guard collection.isOnSite else { throw CollectionSyncError.notOnSite }
        do {
            let current = try await site.fetchCollection(uuid: content.uuid)
            try await site.deleteCollection(uuid: content.uuid, expectedUpdatedAt: current.updatedAt)
        } catch SiteError.server(404, _) {
            // Already gone.
        }
        try await library.forgetCollectionOnSite(id: id)
    }
}
