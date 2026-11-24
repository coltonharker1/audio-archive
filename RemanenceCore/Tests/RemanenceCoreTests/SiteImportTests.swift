import Foundation
import GRDB
import Testing
@testable import RemanenceCore

private let hasTools = FileManager.default.fileExists(atPath: KnownTools.ffmpeg.path)

@Suite struct SiteImportTests {
    let library: Library
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "remanence-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(
            library: root.appending(path: "library", directoryHint: .isDirectory),
            support: root.appending(path: "support", directoryHint: .isDirectory)
        )
        try paths.createDirectories()
        library = Library(database: try AppDatabase.open(at: paths.database), paths: paths)
    }

    private func pusher(_ site: FakeSite) -> Pusher {
        var pusher = Pusher(library: library, site: site)
        pusher.retryDelays = [.zero, .zero]
        return pusher
    }

    /// Makes a short tone, standing in for a file in the site's storage.
    private func makeAudio(frequency: Int) async throws -> (url: URL, sha: String) {
        let url = root.appending(path: "site-\(frequency).wav")
        let (status, _) = try await runToolCapturingOutput(KnownTools.ffmpeg, arguments: [
            "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000:duration=1",
            "-c:a", "pcm_s24le", url.path,
        ], timeout: .seconds(60))
        #expect(status == 0)
        return (url, try sha256(of: url))
    }

    /// Serves files by the last part of their URL, as storage would.
    private func downloader(_ files: [String: URL]) -> Pusher.FileDownload {
        { url, destination in
            guard let file = files.first(where: { url.absoluteString.hasSuffix($0.key) })?.value else {
                throw URLError(.fileDoesNotExist)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }

    private func adminPost(_ site: FakeSite) async throws -> [String: URL] {
        let first = try await makeAudio(frequency: 300)
        let second = try await makeAudio(frequency: 500)
        await site.addAdminPost(uuidForLookup: nil, catalogNumber: "RA-004", title: "From the Admin", trackHashes: [first.sha, second.sha])
        return ["ra-004-\(first.sha.prefix(6)).wav": first.url, "ra-004-\(second.sha.prefix(6)).wav": second.url]
    }

    @Test func postsAreMatchedToTapesByOwnerOrNumber() async throws {
        let ownedUUID = UUID().uuidString
        try await library.database.writer.write { db in
            var owned = Tape(uuid: ownedUUID, title: "Mine", createdAt: Date())
            try owned.insert(db)
            var numbered = Tape(uuid: UUID().uuidString, catalogNumber: "RA-002", title: "Old", pushedAt: Date(), createdAt: Date())
            try numbered.insert(db)
            // Numbered when it was recorded, but not pushed: the site's RA-003 is someone else's.
            var recorded = Tape(uuid: UUID().uuidString, catalogNumber: "RA-003", title: "New", createdAt: Date())
            try recorded.insert(db)
        }
        let entries = [
            SiteEntrySummary(catalogNumber: "RA-001", title: "Mine", published: true, updatedAt: "t", tapeUuid: ownedUUID.lowercased(), trackCount: 1),
            SiteEntrySummary(catalogNumber: "RA-002", title: "Old", published: true, updatedAt: "t", trackCount: 1),
            SiteEntrySummary(catalogNumber: "RA-003", title: "Elsewhere", published: false, updatedAt: "t", trackCount: 2),
        ]
        let listing = try await library.siteListing(entries)
        #expect(listing.map(\.isInLibrary) == [true, true, false])
    }

    @Test(.enabled(if: hasTools)) func aSiteOnlyPostComesInWholeAndCanBeUpdated() async throws {
        let site = FakeSite()
        let files = try await adminPost(site)

        let tapeID = try await pusher(site).importEntry(catalogNumber: "RA-004", downloadFile: downloader(files))

        let post = try await library.database.writer.read { try Library.fetchPost($0, tapeID: tapeID) }!
        #expect(post.tape.catalogNumber == "RA-004")
        #expect(post.tape.title == "From the Admin")
        #expect(post.tape.description == "From the admin.")
        #expect(post.tape.medium == SiteMedium.reel7.label)
        #expect(post.tape.pushedAt != nil)
        #expect(post.tape.siteSnapshot != nil)
        #expect(post.tracks.map(\.name) == ["Part 1", "Part 2"])

        // The masters are the site's files, byte for byte, and read-only.
        let sources = try await library.sources(tapeID: tapeID)
        for source in sources {
            let master = try library.url(forLibraryPath: source.masterPath)
            #expect(try sha256(of: master) == source.sha256)
            #expect(!FileManager.default.isWritableFile(atPath: master.path))
        }
        #expect(Set(sources.compactMap(\.sha256)) == Set(try files.values.map { try sha256(of: $0) }))

        // Its text can be changed like any other post's.
        try await library.saveTrack(sourceID: sources[0].id!, startMarkerID: nil, description: "Written in the app")
        let changes = try await pusher(site).update(tapeID: tapeID)
        #expect(changes.tracks.count == 1)
        #expect(await site.entry(for: "RA-004")?.tracks[0].description == "Written in the app")
    }

    @Test(.enabled(if: hasTools)) func aDamagedDownloadAddsNothing() async throws {
        let site = FakeSite()
        var files = try await adminPost(site)
        let wrong = try await makeAudio(frequency: 900)
        files[files.keys.sorted()[1]] = wrong.url

        await #expect(throws: SiteImportError.self) {
            try await pusher(site).importEntry(catalogNumber: "RA-004", downloadFile: downloader(files))
        }
        let count = try await library.database.writer.read { try Tape.fetchCount($0) }
        #expect(count == 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: library.paths.masters.path)
        #expect(left.isEmpty)
    }

    @Test(.enabled(if: hasTools)) func aPostAlreadyHereIsntImportedTwice() async throws {
        let site = FakeSite()
        let files = try await adminPost(site)
        try await pusher(site).importEntry(catalogNumber: "RA-004", downloadFile: downloader(files))
        await #expect(throws: SiteImportError.alreadyInLibrary("RA-004")) {
            try await pusher(site).importEntry(catalogNumber: "RA-004", downloadFile: downloader(files))
        }
    }

    @Test(.enabled(if: hasTools)) func postsArePublishedAndUnpublished() async throws {
        let site = FakeSite()
        let files = try await adminPost(site)
        let tapeID = try await pusher(site).importEntry(catalogNumber: "RA-004", downloadFile: downloader(files))

        try await pusher(site).setPublished(tapeID: tapeID, false)
        #expect(await site.entry(for: "RA-004")?.published == false)
        let tape = try await library.database.writer.read { try Tape.fetchOne($0, key: tapeID) }!
        #expect(SiteSnapshot.decode(tape.siteSnapshot)?.published == false)

        try await pusher(site).setPublished(tapeID: tapeID, true)
        #expect(await site.entry(for: "RA-004")?.published == true)

        // A post changed elsewhere since it was read isn't touched.
        await site.editInAdmin(uuid: "RA-004", title: "Changed")
        await #expect(throws: SiteError.changedOnSite) {
            try await pusher(site).setPublished(tapeID: tapeID, false)
        }
    }

    @Test(.enabled(if: hasTools)) func deletingAPostKeepsTheTapeReadyToPushAgain() async throws {
        let site = FakeSite()
        let files = try await adminPost(site)
        let tapeID = try await pusher(site).importEntry(catalogNumber: "RA-004", downloadFile: downloader(files))

        try await pusher(site).deleteFromSite(tapeID: tapeID)

        #expect(await site.deleted == ["RA-004"])
        let tape = try await library.database.writer.read { try Tape.fetchOne($0, key: tapeID) }!
        #expect(tape.pushedAt == nil)
        #expect(tape.catalogNumber == nil)
        #expect(tape.siteSnapshot == nil)
        let sources = try await library.sources(tapeID: tapeID)
        #expect(sources.count == 2)
        for source in sources {
            #expect(FileManager.default.fileExists(atPath: try library.url(forLibraryPath: source.masterPath).path))
        }
    }
}
