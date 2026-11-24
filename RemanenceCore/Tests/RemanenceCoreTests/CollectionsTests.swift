import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RemanenceCore

@Suite struct CollectionsTests {
    let library: Library
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "remanence-collections-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(
            library: root.appending(path: "library", directoryHint: .isDirectory),
            support: root.appending(path: "support", directoryHint: .isDirectory)
        )
        try paths.createDirectories()
        library = Library(database: try AppDatabase.open(at: paths.database), paths: paths)
    }

    private func addTape(_ title: String, whereFound: String? = nil, pushed: Bool = false) async throws -> Int64 {
        try await library.database.writer.write { db in
            var tape = Tape(uuid: UUID().uuidString, title: title, medium: "7\" Reel", whereFound: whereFound,
                            approvedAt: Date(), createdAt: Date())
            if pushed { tape.pushedAt = Date() }
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, side: "A", masterPath: "masters/\(tape.uuid)/side-a.wav", duration: 60)
            try source.insert(db)
            return tape.id!
        }
    }

    private func collections() async throws -> [ShelfCollection] {
        try await library.database.writer.read { try Library.fetchCollections($0) }
    }

    private func titles(in collectionID: Int64) async throws -> [String] {
        let ids = try await collections().first { $0.id == collectionID }?.tapeIDs ?? []
        return try await library.database.writer.read { db in
            try ids.map { try Tape.fetchOne(db, key: $0)!.title }
        }
    }

    @Test func namesBecomeAddressesThatNeverRepeat() async throws {
        #expect(Library.slug(for: "The Cable Man") == "the-cable-man")
        #expect(Library.slug(for: "  Bob’s Box: Jingles & Spots!  ") == "bobs-box-jingles-and-spots")
        #expect(Library.slug(for: "Café Zoë") == "cafe-zoe")
        #expect(Library.slug(for: "???") == "collection")

        let first = try await library.createCollection(name: "The Cable Man")
        let second = try await library.createCollection(name: "the cable man")
        let all = try await collections()
        #expect(Set(all.map(\.collection.slug)) == ["the-cable-man", "the-cable-man-2"])

        // Renaming moves the address, and a collection keeps its own when unchanged.
        var fields = CollectionFields(all.first { $0.id == second }!.collection)
        fields.name = "Accordion Lessons"
        try await library.saveCollection(id: second, fields: fields)
        fields = CollectionFields(try await collections().first { $0.id == first }!.collection)
        fields.description = "A box from a garage sale."
        try await library.saveCollection(id: first, fields: fields)
        let saved = try await collections()
        #expect(saved.first { $0.id == second }?.collection.slug == "accordion-lessons")
        #expect(saved.first { $0.id == first }?.collection.slug == "the-cable-man")
        #expect(saved.first { $0.id == first }?.collection.description == "A box from a garage sale.")

        await #expect(throws: CollectionError.emptyName) { try await library.createCollection(name: "  ") }
    }

    @Test func reelsJoinAtTheEndAndTakeTheOrderTheyAreGiven() async throws {
        let box = try await library.createCollection(name: "The Cable Man")
        let a = try await addTape("Line check")
        let b = try await addTape("Station break")
        let c = try await addTape("Rain")
        for tape in [a, b, c] { try await library.setCollection(tapeID: tape, collectionID: box) }
        #expect(try await titles(in: box) == ["Line check", "Station break", "Rain"])

        try await library.moveInCollection(tapeID: c, to: 0)
        #expect(try await titles(in: box) == ["Rain", "Line check", "Station break"])
        try await library.moveInCollection(tapeID: c, to: 9)
        #expect(try await titles(in: box) == ["Line check", "Station break", "Rain"])

        // Taking one out and putting it back puts it at the end.
        try await library.setCollection(tapeID: a, collectionID: nil)
        #expect(try await titles(in: box) == ["Station break", "Rain"])
        try await library.setCollection(tapeID: a, collectionID: box)
        #expect(try await titles(in: box) == ["Station break", "Rain", "Line check"])

        // Moving to another collection leaves the first.
        let other = try await library.createCollection(name: "Kitchen Window")
        try await library.setCollection(tapeID: b, collectionID: other)
        #expect(try await titles(in: box) == ["Rain", "Line check"])
        #expect(try await titles(in: other) == ["Station break"])
    }

    @Test func deletingACollectionKeepsItsReels() async throws {
        let box = try await library.createCollection(name: "The Cable Man")
        let tape = try await addTape("Line check")
        try await library.setCollection(tapeID: tape, collectionID: box)
        let image = try await library.addImage(collectionID: box, from: try photo())
        let stored = try library.url(forLibraryPath: image.path)
        #expect(FileManager.default.fileExists(atPath: stored.path))

        let trashed = Locked<[String]>([])
        try await library.deleteCollection(id: box) { url in
            trashed.mutate { $0.append(url.lastPathComponent) }
            try FileManager.default.removeItem(at: url)
        }
        #expect(try await collections().isEmpty)
        #expect(trashed.value == [stored.lastPathComponent])
        let kept = try await library.database.writer.read { try Tape.fetchOne($0, key: tape) }
        #expect(kept?.collectionId == nil && kept?.collectionPosition == nil)
        #expect(kept?.title == "Line check")
    }

    @Test func aReelUsesItsCollectionsFindingUnlessItHasItsOwn() async throws {
        let box = try await library.createCollection(name: "The Cable Man")
        var fields = CollectionFields(try await collections()[0].collection)
        fields.whereFound = "Garage sale, Joliet IL"
        fields.dateFound = "October 2023"
        try await library.saveCollection(id: box, fields: fields)

        let plain = try await addTape("Line check")
        let own = try await addTape("Rain", whereFound: "Left on the porch")
        try await library.setCollection(tapeID: plain, collectionID: box)
        try await library.setCollection(tapeID: own, collectionID: box)

        let post = try await library.database.writer.read { try Library.fetchPost($0, tapeID: plain)! }
        #expect(post.collection?.name == "The Cable Man")
        #expect(post.whereFound == "Garage sale, Joliet IL")
        #expect(post.dateFound == "October 2023")
        let ownPost = try await library.database.writer.read { try Library.fetchPost($0, tapeID: own)! }
        #expect(ownPost.whereFound == "Left on the porch")
        #expect(ownPost.dateFound == "October 2023")
        // The tape itself is untouched, so changing the collection changes the reel.
        #expect(post.tape.whereFound == nil)

        // A site that already has the collection's words isn't told to change them.
        let snapshot = SiteSnapshot(
            published: false,
            fields: .init(title: "Line check", medium: "reel", whereFound: "Garage sale, Joliet IL", dateFound: "October 2023"),
            tracks: [],
            images: []
        )
        let changes = SiteChanges.between(post, and: snapshot)
        #expect(changes.fields.whereFound == nil)
        #expect(changes.fields.dateFound == nil)
    }

    @Test func aRecordingCanStartInACollection() async throws {
        let box = try await library.createCollection(name: "Accordion Lessons")
        let first = try await library.beginCapture(machine: nil, title: "Lesson 1", speed: nil, collectionID: box)
        let second = try await library.beginCapture(machine: nil, title: "Lesson 2", speed: nil, collectionID: box)
        #expect(try await titles(in: box) == ["Lesson 1", "Lesson 2"])

        // A collection that's gone never stops a recording.
        let orphan = try await library.beginCapture(machine: nil, title: "Lesson 3", speed: nil, collectionID: 999)
        let tape = try await library.database.writer.read { try Tape.fetchOne($0, key: orphan.tapeID) }
        #expect(tape != nil && tape?.collectionId == nil)
        _ = (first, second)
    }

    @Test func collectionPhotosKeepTheirOrderAndCaptions() async throws {
        let box = try await library.createCollection(name: "The Cable Man")
        let lid = try await library.addImage(collectionID: box, from: try photo())
        let sheet = try await library.addImage(collectionID: box, from: try photo(shade: 0.2))
        await #expect(throws: ImageImportError.self) {
            try await library.addImage(collectionID: box, from: try photo())
        }
        try await library.setCollectionCaption(imageID: lid.id!, caption: "  The lid  ")
        try await library.moveCollectionImage(id: sheet.id!, by: -1)
        var images = try await collections()[0].images
        #expect(images.map(\.id) == [sheet.id, lid.id])
        #expect(images.last?.caption == "The lid")

        try await library.removeCollectionImage(id: sheet.id!)
        images = try await collections()[0].images
        #expect(images.map(\.id) == [lid.id])
        #expect(images.first?.position == 0)
        #expect(!FileManager.default.fileExists(atPath: try library.url(forLibraryPath: sheet.path).path))
    }

    private func photo(shade: CGFloat = 0.6) throws -> URL {
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: shade, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let url = root.appending(path: "photo-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

// MARK: Pushing collections

extension CollectionsTests {
    private func onSite(_ site: FakeSite, tapeID: Int64) async throws {
        let uuid = try await library.database.writer.read { try Tape.fetchOne($0, key: tapeID)!.uuid }
        _ = try await site.createEntry(SiteEntry(tapeUuid: uuid, title: "Reel", medium: "reel-to-reel-7",
                                                 description: nil, estimatedRecordingDate: nil, tracks: [], images: [],
                                                 transcriptSha256: nil, metadata: [:]))
    }

    private func shelf(_ id: Int64) async throws -> ShelfCollection {
        try await collections().first { $0.id == id }!
    }

    private func pusher(_ site: FakeSite) -> Pusher {
        var pusher = Pusher(library: library, site: site)
        pusher.retryDelays = [.zero, .zero]
        return pusher
    }

    @Test func aCollectionGoesUpWithItsPhotosAndReelsInOrder() async throws {
        let site = FakeSite()
        let box = try await library.createCollection(name: "The Cable Man")
        var fields = CollectionFields(try await shelf(box).collection)
        fields.description = "A box from a garage sale."
        try await library.saveCollection(id: box, fields: fields)
        let lid = try await library.addImage(collectionID: box, from: try photo())
        try await library.setCollectionCaption(imageID: lid.id!, caption: "The lid")
        let rain = try await addTape("Rain")
        let line = try await addTape("Line check")
        let later = try await addTape("Not pushed yet")
        for tape in [rain, line, later] { try await library.setCollection(tapeID: tape, collectionID: box) }
        try await onSite(site, tapeID: rain)
        try await onSite(site, tapeID: line)

        let state = try await pusher(site).pushCollection(id: box)
        #expect(state.published == false)
        #expect(await site.uploads == [lid.sha256])
        let sent = await site.collectionPushes.last!
        #expect(sent.expectedUpdatedAt == nil)
        #expect(sent.content.images.map(\.caption) == ["The lid"])
        let uuids = try await library.database.writer.read { db in
            try [rain, line, later].map { try Tape.fetchOne(db, key: $0)!.uuid.lowercased() }
        }
        #expect(sent.content.reels == uuids)
        #expect(state.reels.map(\.tapeUuid) == [uuids[0], uuids[1]])

        let after = try await shelf(box)
        #expect(after.collection.isOnSite)
        #expect(after.collection.siteUpdatedAt == state.updatedAt)
        #expect(!after.hasUnsentChanges)
        #expect(after.missingReelCount == 1)

        // A change here is something to send; sending it again uploads nothing new.
        fields.description = "A box from a garage sale, under a card table."
        try await library.saveCollection(id: box, fields: fields)
        #expect(try await shelf(box).hasUnsentChanges)
        try await library.moveInCollection(tapeID: line, to: 0)
        let second = try await pusher(site).pushCollection(id: box)
        #expect(await site.uploads.count == 1)
        #expect(await site.collectionPushes.last?.expectedUpdatedAt == state.updatedAt)
        #expect(second.reels.first?.tapeUuid == uuids[1])
        #expect(!(try await shelf(box).hasUnsentChanges))
    }

    @Test func aPublishedCollectionKeepsItsAddress() async throws {
        let site = FakeSite()
        let box = try await library.createCollection(name: "The Cable Man")
        try await pusher(site).pushCollection(id: box, publish: true)
        #expect(try await shelf(box).collection.sitePublished)

        var fields = CollectionFields(try await shelf(box).collection)
        fields.name = "The Cable Guy"
        try await library.saveCollection(id: box, fields: fields)
        let renamed = try await shelf(box).collection
        #expect(renamed.name == "The Cable Guy")
        #expect(renamed.slug == "the-cable-man")
        try await pusher(site).pushCollection(id: box)
        #expect(await site.collections[renamed.uuid.lowercased()]?.name == "The Cable Guy")

        // Unpublished, its address follows its name again.
        try await pusher(site).pushCollection(id: box, publish: false)
        try await library.saveCollection(id: box, fields: fields)
        fields.name = "The Cable Guy's Box"
        try await library.saveCollection(id: box, fields: fields)
        #expect(try await shelf(box).collection.slug == "the-cable-guys-box")
    }

    @Test func aLostAnswerDoesntStopTheNextPush() async throws {
        let site = FakeSite()
        let box = try await library.createCollection(name: "The Cable Man")
        let first = try await pusher(site).pushCollection(id: box)
        // The site moved on without the app hearing about it.
        await site.touchCollection(first.uuid)
        let second = try await pusher(site).pushCollection(id: box)
        #expect(second.updatedAt != first.updatedAt)
        #expect(try await shelf(box).collection.siteUpdatedAt == second.updatedAt)
    }

    @Test func aCollectionCanBeTakenOffTheSite() async throws {
        let site = FakeSite()
        let box = try await library.createCollection(name: "The Cable Man")
        let state = try await pusher(site).pushCollection(id: box)
        try await pusher(site).deleteCollectionFromSite(id: box)
        #expect(await site.collections[state.uuid] == nil)
        let after = try await shelf(box)
        #expect(!after.collection.isOnSite && !after.collection.sitePublished)
        await #expect(throws: CollectionSyncError.notOnSite) { try await pusher(site).deleteCollectionFromSite(id: box) }

        // Pushed again, it starts over as new.
        try await pusher(site).pushCollection(id: box)
        #expect(await site.collectionPushes.last?.expectedUpdatedAt == nil)
    }
}

extension CollectionsTests {
    /// The site tells a new collection by `expectedUpdatedAt` being null, not missing.
    @Test func aNewCollectionIsSentWithANullClock() async throws {
        let box = try await library.createCollection(name: "The Cable Man")
        let content = try #require(try await collections().first { $0.id == box }?.content)
        let data = try JSONEncoder().encode(SiteCollectionPush(content: content, expectedUpdatedAt: nil, published: nil))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json.keys.contains("expectedUpdatedAt"))
        #expect(json["expectedUpdatedAt"] is NSNull)
        #expect(json["published"] == nil)
        #expect(json["slug"] as? String == "the-cable-man")
        #expect(json["reels"] as? [String] == [])
        if let path = ProcessInfo.processInfo.environment["COLLECTION_JSON_OUT"] {
            try data.write(to: URL(filePath: path))
        }
    }
}
