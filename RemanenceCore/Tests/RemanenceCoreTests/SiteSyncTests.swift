import Foundation
import GRDB
import Testing
@testable import RemanenceCore

private let hasFFmpeg = FileManager.default.fileExists(atPath: KnownTools.ffmpeg.path)

@Suite(.enabled(if: hasFFmpeg)) struct SiteSyncTests {
    let library: Library
    let root: URL
    let site = FakeSite()

    init() throws {
        root = try TestFolders.make("sync")
        let paths = LibraryPaths(
            library: root.appending(path: "library", directoryHint: .isDirectory),
            support: root.appending(path: "support", directoryHint: .isDirectory)
        )
        try paths.createDirectories()
        library = Library(database: try AppDatabase.open(at: paths.database), paths: paths)
    }

    private var pusher: Pusher {
        var pusher = Pusher(library: library, site: site)
        pusher.retryDelays = [.zero]
        return pusher
    }

    private func tone(_ seconds: Int, frequency: Int = 440) async throws -> URL {
        let uuid = UUID().uuidString
        let folder = library.paths.masters.appending(path: uuid, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "side-a.wav")
        let (status, _) = try await runToolCapturingOutput(KnownTools.ffmpeg, arguments: [
            "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000:duration=\(seconds)",
            "-c:a", "pcm_s16le", url.path,
        ], timeout: .seconds(60))
        #expect(status == 0)
        return url
    }

    /// A tape made in the app and pushed, with two tracks.
    private func pushedTape() async throws -> (tapeID: Int64, sourceID: Int64, marker: Int64, uuid: String) {
        let master = try await tone(6)
        let uuid = master.deletingLastPathComponent().lastPathComponent
        let ids = try await library.database.writer.write { db in
            var tape = Tape(uuid: uuid, title: "Sermon", medium: "Cassette", approvedAt: Date(), createdAt: Date())
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, side: "A", masterPath: "masters/\(uuid)/side-a.wav", duration: 6)
            try source.insert(db)
            return (tape.id!, source.id!)
        }
        let marker = try await library.addMarker(sourceID: ids.1, time: 2, trackName: "Hymn")
        try await pusher.push(tapeID: ids.0)
        return (ids.0, ids.1, marker, uuid)
    }

    private func post(_ tapeID: Int64) async throws -> SitePost {
        try await library.database.writer.read { try Library.fetchPost($0, tapeID: tapeID)! }
    }

    private func edit(_ tapeID: Int64, _ change: (inout PostFields) -> Void) async throws {
        var fields = PostFields(tape: try await post(tapeID).tape)
        change(&fields)
        try await library.savePost(tapeID: tapeID, fields: fields)
    }

    private func photo(_ name: String, color: String) async throws -> URL {
        let url = root.appending(path: name)
        let (status, _) = try await runToolCapturingOutput(KnownTools.ffmpeg, arguments: [
            "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=\(color):s=32x24", "-frames:v", "1", url.path,
        ], timeout: .seconds(30))
        #expect(status == 0)
        return url
    }

    // MARK: Updating

    @Test func aFreshPushHasNothingToUpdate() async throws {
        let tape = try await pushedTape()
        let changes = try #require(Pusher.changes(for: try await post(tape.tapeID)))
        #expect(changes.isEmpty)
        #expect(changes.notSent.isEmpty)
    }

    @Test func onlyWhatChangedIsSent() async throws {
        let tape = try await pushedTape()
        try await edit(tape.tapeID) {
            $0.title = "Sunday Sermon"
            $0.description = "Recorded at a small church."
            $0.whereFound = "Thrift store"
        }
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: tape.marker, name: "Closing Hymn", description: "Sung slowly.")

        let changes = try await pusher.update(tapeID: tape.tapeID)

        #expect(changes.summary == ["Title", "Where found", "Description", "Track 2"])
        let sent = try #require(await site.updates.last)
        #expect(sent.fields?.medium == nil, "unchanged fields are left out")
        #expect(sent.images == nil, "photos weren't touched")
        #expect(sent.tracks?.count == 1)
        let entry = try #require(await site.entry(for: tape.uuid))
        #expect(entry.title == "Sunday Sermon")
        #expect(entry.whereFound == "Thrift store")
        #expect(entry.tracks.map(\.title) == ["Track 1", "Closing Hymn"])
        #expect(entry.tracks[1].description == "Sung slowly.")
        #expect(Pusher.changes(for: try await post(tape.tapeID))?.isEmpty == true, "afterward, the app and site agree")
    }

    @Test func clearingAFieldClearsItOnTheSite() async throws {
        let tape = try await pushedTape()
        try await edit(tape.tapeID) { $0.description = "Something." }
        try await pusher.update(tapeID: tape.tapeID)
        try await edit(tape.tapeID) { $0.description = "" }

        try await pusher.update(tapeID: tape.tapeID)

        #expect(await site.entry(for: tape.uuid)?.description == nil)
    }

    @Test func anEditInTheAdminIsNeverOverwritten() async throws {
        let tape = try await pushedTape()
        await site.editInAdmin(uuid: tape.uuid, title: "Admin's Title", addPhoto: "https://r2.invalid/image/admin.jpg")
        try await edit(tape.tapeID) { $0.description = "Mine." }

        await #expect(throws: SiteError.changedOnSite) { try await pusher.update(tapeID: tape.tapeID) }
        #expect(await site.entry(for: tape.uuid)?.title == "Admin's Title")
        #expect(await site.entry(for: tape.uuid)?.description == nil)

        let adminPhoto = try Data(contentsOf: try await photo("admin.png", color: "green"))
        try await pusher.refresh(tapeID: tape.tapeID) { _ in adminPhoto }
        let refreshed = try await post(tape.tapeID)
        #expect(refreshed.tape.title == "Admin's Title")
        #expect(refreshed.images.map(\.siteUrl) == ["https://r2.invalid/image/admin.jpg"])
        #expect(refreshed.images.first?.caption == "From the admin")

        try await edit(tape.tapeID) { $0.description = "Mine." }
        try await pusher.update(tapeID: tape.tapeID)
        let entry = try #require(await site.entry(for: tape.uuid))
        #expect(entry.title == "Admin's Title")
        #expect(entry.description == "Mine.")
        #expect(entry.images.map(\.url) == ["https://r2.invalid/image/admin.jpg"])
    }

    @Test func newPhotosAreUploadedAndJoinTheOnesThere() async throws {
        let tape = try await pushedTape()
        await site.editInAdmin(uuid: tape.uuid, addPhoto: "https://r2.invalid/image/admin.jpg")
        let adminPhoto = try Data(contentsOf: try await photo("admin.png", color: "green"))
        try await pusher.refresh(tapeID: tape.tapeID) { _ in adminPhoto }

        let added = try await library.addImage(tapeID: tape.tapeID, from: try await photo("label.png", color: "blue"))
        try await library.setCaption(imageID: added.id!, caption: "The label")
        try await library.moveImage(id: added.id!, by: -1)
        let uploadsBefore = await site.uploads.count

        let changes = try await pusher.update(tapeID: tape.tapeID)

        #expect(changes.summary == ["Photos"])
        #expect(await site.uploads.count == uploadsBefore + 1)
        let entry = try #require(await site.entry(for: tape.uuid))
        #expect(entry.images.map(\.caption) == ["The label", "From the admin"])
        #expect(entry.images.last?.url == "https://r2.invalid/image/admin.jpg")
        let linked = try await post(tape.tapeID).images
        #expect(linked.allSatisfy { $0.siteUrl != nil })
        #expect(Pusher.changes(for: try await post(tape.tapeID))?.isEmpty == true)
    }

    @Test func reorderingAndCaptioningSendsNoFiles() async throws {
        let tape = try await pushedTape()
        let first = try await library.addImage(tapeID: tape.tapeID, from: try await photo("a.png", color: "red"))
        try await library.addImage(tapeID: tape.tapeID, from: try await photo("b.png", color: "blue"))
        try await pusher.update(tapeID: tape.tapeID)
        let uploads = await site.uploads.count

        try await library.moveImage(id: first.id!, by: 1)
        try await library.setCaption(imageID: first.id!, caption: "Now second")
        try await pusher.update(tapeID: tape.tapeID)

        #expect(await site.uploads.count == uploads)
        #expect(await site.entry(for: tape.uuid)?.images.map(\.caption) == [nil, "Now second"])
    }

    @Test func movedAudioIsExplainedNotSent() async throws {
        let tape = try await pushedTape()
        try await library.moveMarker(id: tape.marker, to: 3)
        try await edit(tape.tapeID) { $0.title = "Renamed" }

        let changes = try #require(Pusher.changes(for: try await post(tape.tapeID)))

        #expect(changes.summary == ["Title"])
        #expect(changes.notSent.count == 2, "both tracks around the moved marker changed")
        #expect(changes.notSent.allSatisfy { $0.contains("audio has changed") })
    }

    @Test func removingAPhotoRemovesItFromThePost() async throws {
        let tape = try await pushedTape()
        let image = try await library.addImage(tapeID: tape.tapeID, from: try await photo("a.png", color: "red"))
        try await pusher.update(tapeID: tape.tapeID)
        #expect(await site.entry(for: tape.uuid)?.images.count == 1)

        try await library.removeImage(id: image.id!)
        try await pusher.update(tapeID: tape.tapeID)

        #expect(await site.entry(for: tape.uuid)?.images.isEmpty == true)
    }

    // MARK: Tapes that came from the site

    private func importedTape() async throws -> (tapeID: Int64, sourceIDs: [Int64]) {
        let first = try await tone(2, frequency: 300)
        let second = try await tone(2, frequency: 500)
        let hashes = [try sha256(of: first), try sha256(of: second)]
        await site.addAdminPost(uuidForLookup: nil, catalogNumber: "RA-003", title: "From the Admin", trackHashes: hashes)
        return try await library.database.writer.write { db in
            var tape = Tape(uuid: UUID().uuidString, catalogNumber: "RA-003", title: "From the Admin", medium: "7\" Reel-to-Reel",
                            description: "From the admin.", pushedAt: Date(), createdAt: Date())
            try tape.insert(db)
            var ids: [Int64] = []
            for (index, url) in [first, second].enumerated() {
                let folder = url.deletingLastPathComponent().lastPathComponent
                var source = Source(tapeId: tape.id!, position: index, masterPath: "masters/\(folder)/side-a.wav",
                                    sha256: hashes[index], duration: 2)
                try source.insert(db)
                var track = Track(sourceId: source.id!, name: "Part \(index + 1)")
                try track.insert(db)
                ids.append(source.id!)
            }
            return (tape.id!, ids)
        }
    }

    @Test func importedTapesStartByRefreshing() async throws {
        let tape = try await importedTape()
        await #expect(throws: SiteSyncError.needsRefresh) { try await pusher.update(tapeID: tape.tapeID) }
        #expect(Pusher.changes(for: try await post(tape.tapeID)) == nil)

        let result = try await pusher.refresh(tapeID: tape.tapeID)
        #expect(result.unmatchedTracks == 0)

        try await library.saveTrack(sourceID: tape.sourceIDs[1], startMarkerID: nil, description: "The second reel.")
        try await edit(tape.tapeID) { $0.dateFound = "2023" }
        let changes = try await pusher.update(tapeID: tape.tapeID)

        #expect(changes.summary == ["Date acquired", "Track 2"])
        let entry = try #require(await site.entry(for: "RA-003"))
        #expect(entry.dateFound == "2023")
        #expect(entry.tracks[1].description == "The second reel.")
        #expect(entry.tracks[0].description == nil)
        #expect(entry.published, "publishing is never changed by the app")
    }

    @Test func refreshKeepsPhotosNotSentYet() async throws {
        let tape = try await pushedTape()
        let local = try await library.addImage(tapeID: tape.tapeID, from: try await photo("mine.png", color: "red"))
        await site.editInAdmin(uuid: tape.uuid, addPhoto: "https://r2.invalid/image/admin.jpg")
        let adminPhoto = try Data(contentsOf: try await photo("admin.png", color: "green"))

        try await pusher.refresh(tapeID: tape.tapeID) { _ in adminPhoto }

        let images = try await post(tape.tapeID).images
        #expect(images.count == 2)
        #expect(images.first?.siteUrl == "https://r2.invalid/image/admin.jpg")
        #expect(images.last?.id == local.id, "the photo added here stays, after the site's")
    }

    @Test func refreshDropsPhotosRemovedOnTheSite() async throws {
        let tape = try await pushedTape()
        let image = try await library.addImage(tapeID: tape.tapeID, from: try await photo("a.png", color: "red"))
        try await pusher.update(tapeID: tape.tapeID)
        await site.editInAdmin(uuid: tape.uuid, removePhotos: true)

        try await pusher.refresh(tapeID: tape.tapeID)

        #expect(try await post(tape.tapeID).images.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try library.url(forLibraryPath: image.path).path))
    }

    @Test func aPhotoThatWontDownloadIsSkippedAndReported() async throws {
        let tape = try await pushedTape()
        await site.editInAdmin(uuid: tape.uuid, addPhoto: "https://r2.invalid/image/gone.jpg")

        let result = try await pusher.refresh(tapeID: tape.tapeID) { _ in throw URLError(.fileDoesNotExist) }

        #expect(result.photosSkipped == ["https://r2.invalid/image/gone.jpg"])
        #expect(try await post(tape.tapeID).tape.siteUpdatedAt == (await site.entry(for: tape.uuid)?.updatedAt))
    }

    @Test func tapesNotOnTheSiteCantBeUpdated() async throws {
        let master = try await tone(2)
        let uuid = master.deletingLastPathComponent().lastPathComponent
        let tapeID = try await library.database.writer.write { db in
            var tape = Tape(uuid: uuid, title: "New", medium: "Cassette", createdAt: Date())
            try tape.insert(db)
            return tape.id!
        }
        await #expect(throws: SiteSyncError.notOnSite) { try await pusher.update(tapeID: tapeID) }
        await #expect(throws: SiteSyncError.notOnSite) { try await pusher.refresh(tapeID: tapeID) }
    }
}
