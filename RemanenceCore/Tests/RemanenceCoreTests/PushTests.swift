import Foundation
import GRDB
import Testing
@testable import RemanenceCore

/// Stands in for the site, keeping what a real one would, so nothing leaves this Mac.
/// Updates follow the real site's rules: only what's sent changes, and a stale update
/// is refused.
actor FakeSite: SiteAPI {
    var files: [String: String] = [:]
    var uploads: [String] = []
    var entries: [String: SitePostState] = [:]
    var updates: [SiteUpdate] = []
    var failUploadsAfter: Int?
    var failCreate = false
    var temporaryFailures = 0
    private var clock = 0

    func setFailUploadsAfter(_ count: Int?) { failUploadsAfter = count }
    func setFailCreate(_ fail: Bool) { failCreate = fail }
    func setTemporaryFailures(_ count: Int) { temporaryFailures = count }
    func entry(for key: String) -> SitePostState? { entries[key.lowercased()] ?? entries[key] }

    private func tick() -> String {
        clock += 1
        return "2026-11-17T00:00:\(String(format: "%02d", clock)).000Z"
    }

    private func url(_ sha: String) -> String { "https://r2.invalid/\(files[sha] ?? "missing/\(sha)")" }

    /// As if someone edited the post in the site's admin.
    func editInAdmin(uuid: String, title: String? = nil, addPhoto: String? = nil, removePhotos: Bool = false) {
        let key = entries[uuid.lowercased()] != nil ? uuid.lowercased() : uuid
        guard let entry = entries[key] else { return }
        var images = removePhotos ? [] : entry.images
        if let addPhoto { images.append(.init(url: addPhoto, filename: "admin.jpg", caption: "From the admin")) }
        entries[key] = SitePostState(
            catalogNumber: entry.catalogNumber, title: title ?? entry.title, description: entry.description,
            medium: entry.medium, whereFound: entry.whereFound, dateFound: entry.dateFound,
            estimatedRecordingDate: entry.estimatedRecordingDate, published: entry.published,
            updatedAt: tick(), tracks: entry.tracks, images: images
        )
    }

    /// A post made in the admin before the app existed, with files known by hash.
    func addAdminPost(uuidForLookup: String?, catalogNumber: String, title: String, trackHashes: [String]) {
        for sha in trackHashes { files[sha] = "audio/\(catalogNumber.lowercased())-\(sha.prefix(6)).wav" }
        entries[catalogNumber] = SitePostState(
            catalogNumber: catalogNumber, title: title, description: "From the admin.", medium: "reel-to-reel-7",
            published: true, updatedAt: tick(),
            tracks: trackHashes.enumerated().map { index, sha in
                .init(title: "Part \(index + 1)", audioUrl: "https://r2.invalid/audio/\(index).mp3", downloadUrl: url(sha), downloadSha256: sha)
            }
        )
    }

    func existingFiles(_ hashes: [String]) async throws -> Set<String> {
        Set(files.keys).intersection(hashes)
    }

    var renumberings: [[SiteRenumber]] = []

    func renumber(_ changes: [SiteRenumber]) async throws -> [SitePostState] {
        renumberings.append(changes)
        for change in changes {
            guard let entry = entries[change.tapeUuid], entry.catalogNumber == change.catalogNumber,
                  entry.updatedAt == change.expectedUpdatedAt else { throw SiteError.changedOnSite }
        }
        let leaving = Set(changes.map(\.catalogNumber))
        let held = Set(entries.values.map(\.catalogNumber)).subtracting(leaving)
        if let taken = changes.first(where: { held.contains($0.newCatalogNumber) }) {
            throw SiteError.server(status: 409, message: "Already used by another post: \(taken.newCatalogNumber)")
        }
        return changes.map { change in
            let entry = entries[change.tapeUuid]!
            var moved = SitePostState(
                catalogNumber: change.newCatalogNumber, title: entry.title, description: entry.description,
                medium: entry.medium, whereFound: entry.whereFound, dateFound: entry.dateFound,
                estimatedRecordingDate: entry.estimatedRecordingDate, published: entry.published,
                updatedAt: tick(), tracks: entry.tracks, images: entry.images
            )
            moved.tapeUuid = change.tapeUuid
            entries[change.tapeUuid] = moved
            return moved
        }
    }

    // MARK: Collections, as the site's /api/sync/collection behaves

    var collections: [String: SiteCollectionState] = [:]
    var collectionPushes: [SiteCollectionPush] = []
    /// Tape UUIDs of posts the site has, for which reels can join a collection.
    func reelUUIDs() -> Set<String> { Set(entries.values.compactMap(\.tapeUuid)) }

    func touchCollection(_ uuid: String) {
        guard let current = collections[uuid] else { return }
        collections[uuid] = SiteCollectionState(uuid: current.uuid, slug: current.slug, name: current.name,
                                                published: current.published, updatedAt: tick(), reels: current.reels)
    }

    func fetchCollection(uuid: String) async throws -> SiteCollectionState {
        guard let found = collections[uuid.lowercased()] else { throw SiteError.server(status: 404, message: "No collection with that uuid") }
        return found
    }

    func saveCollection(_ push: SiteCollectionPush) async throws -> SiteCollectionState {
        collectionPushes.append(push)
        let uuid = push.content.uuid
        let existing = collections[uuid]
        if let existing, existing.updatedAt != push.expectedUpdatedAt { throw SiteError.changedOnSite }
        if existing == nil, push.expectedUpdatedAt != nil { throw SiteError.server(status: 404, message: "This collection isn't on the site anymore.") }
        if let existing, existing.published, existing.slug != push.content.slug {
            throw SiteError.server(status: 409, message: "its address can't change")
        }
        for image in push.content.images where files[image.sha256] == nil {
            throw SiteError.server(status: 409, message: "Some photos aren't uploaded")
        }
        let known = reelUUIDs()
        var state = SiteCollectionState(
            uuid: uuid, slug: push.content.slug, name: push.content.name,
            published: push.published ?? existing?.published ?? false, updatedAt: tick(),
            images: push.content.images.map { .init(url: url($0.sha256), filename: $0.filename, caption: $0.caption, sha256: $0.sha256) },
            reels: push.content.reels.filter(known.contains).map { .init(tapeUuid: $0, catalogNumber: entries[$0]?.catalogNumber ?? "", published: false) }
        )
        collections[uuid] = state
        state.missingReels = push.content.reels.filter { !known.contains($0) }
        return state
    }

    func deleteCollection(uuid: String, expectedUpdatedAt: String) async throws {
        guard let existing = collections[uuid.lowercased()] else { throw SiteError.server(status: 404, message: "No collection") }
        guard existing.updatedAt == expectedUpdatedAt else { throw SiteError.changedOnSite }
        collections[uuid.lowercased()] = nil
    }

    func requestUpload(_ file: PushFile) async throws -> SiteUpload {
        let folder = file.kind == .image ? "image" : "audio"
        return SiteUpload(url: URL(string: "https://storage.invalid/\(file.sha256)")!, key: "\(folder)/\(file.sha256).\(file.url.pathExtension)")
    }

    func upload(_ file: PushFile, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if temporaryFailures > 0 {
            temporaryFailures -= 1
            throw URLError(.networkConnectionLost)
        }
        if let limit = failUploadsAfter, uploads.count >= limit { throw SiteError.server(status: 400, message: "nope") }
        uploads.append(file.sha256)
        progress(1)
    }

    func recordFile(_ file: PushFile, key: String) async throws {
        files[file.sha256] = key
    }

    func createEntry(_ entry: SiteEntry) async throws -> SitePostState {
        if failCreate { throw URLError(.badServerResponse) }
        if let existing = entries[entry.tapeUuid.lowercased()] { return existing }
        if let requested = entry.catalogNumber, entries.values.contains(where: { $0.catalogNumber == requested }) {
            throw SiteError.server(status: 409, message: "\(requested) is already used on the site")
        }
        var state = SitePostState(
            catalogNumber: entry.catalogNumber ?? "RA-\(String(format: "%03d", 8 + entries.count))",
            title: entry.title, description: entry.description, medium: entry.medium,
            whereFound: entry.whereFound, dateFound: entry.dateFound,
            estimatedRecordingDate: entry.estimatedRecordingDate, updatedAt: tick(),
            tracks: entry.tracks.map {
                .init(title: $0.title, description: $0.description, duration: $0.duration,
                      audioUrl: url($0.audioSha256), downloadUrl: url($0.downloadSha256),
                      audioSha256: $0.audioSha256, downloadSha256: $0.downloadSha256)
            },
            images: entry.images.map { .init(url: url($0.sha256), filename: $0.filename, caption: $0.caption, sha256: $0.sha256) }
        )
        state.tapeUuid = entry.tapeUuid.lowercased()
        entries[entry.tapeUuid.lowercased()] = state
        return state
    }

    func fetchEntry(tapeUUID: String, catalogNumber: String?) async throws -> SitePostState {
        if let entry = entries[tapeUUID.lowercased()] ?? catalogNumber.flatMap({ entries[$0] }) { return entry }
        throw SiteError.server(status: 404, message: "No post for that tape")
    }

    func updateEntry(_ update: SiteUpdate) async throws -> SitePostState {
        updates.append(update)
        let key = entries[update.tapeUuid.lowercased()] != nil ? update.tapeUuid.lowercased() : (update.catalogNumber ?? "")
        guard let entry = entries[key] else { throw SiteError.server(status: 404, message: "No post") }
        guard entry.updatedAt == update.expectedUpdatedAt else { throw SiteError.changedOnSite }

        let fields = update.fields
        var tracks = entry.tracks
        for change in update.tracks ?? [] {
            guard let index = tracks.firstIndex(where: { $0.audioSha256 == change.sha256 || $0.downloadSha256 == change.sha256 }) else {
                throw SiteError.server(status: 409, message: "Some tracks weren't found on the post")
            }
            let old = tracks[index]
            tracks[index] = .init(
                title: change.title ?? old.title,
                description: change.description.map { $0 } ?? old.description,
                duration: old.duration, audioUrl: old.audioUrl, downloadUrl: old.downloadUrl,
                audioSha256: old.audioSha256, downloadSha256: old.downloadSha256
            )
        }
        var images = entry.images
        if let requested = update.images {
            images = try requested.map { image in
                if let url = image.url {
                    guard let existing = entry.images.first(where: { $0.url == url }) else {
                        throw SiteError.server(status: 409, message: "not on this post")
                    }
                    return .init(url: url, filename: existing.filename, caption: image.caption, sha256: existing.sha256)
                }
                guard let sha = image.sha256, files[sha] != nil else { throw SiteError.server(status: 409, message: "not uploaded") }
                return .init(url: url(sha), filename: image.filename, caption: image.caption, sha256: sha)
            }
        }
        var state = SitePostState(
            catalogNumber: entry.catalogNumber,
            title: fields?.title ?? entry.title,
            description: fields?.description.map { $0 } ?? entry.description,
            medium: fields?.medium ?? entry.medium,
            whereFound: fields?.whereFound.map { $0 } ?? entry.whereFound,
            dateFound: fields?.dateFound.map { $0 } ?? entry.dateFound,
            estimatedRecordingDate: fields?.estimatedRecordingDate.map { $0 } ?? entry.estimatedRecordingDate,
            published: update.published ?? entry.published, updatedAt: tick(), tracks: tracks, images: images
        )
        state.tapeUuid = entry.tapeUuid
        entries[key] = state
        return state
    }

    func listEntries() async throws -> [SiteEntrySummary] {
        entries.values.map {
            SiteEntrySummary(catalogNumber: $0.catalogNumber, title: $0.title, published: $0.published,
                             updatedAt: $0.updatedAt, tapeUuid: $0.tapeUuid, trackCount: $0.tracks.count)
        }.sorted { $0.catalogNumber < $1.catalogNumber }
    }

    var deleted: [String] = []

    func deleteEntry(tapeUUID: String, catalogNumber: String?, expectedUpdatedAt: String) async throws {
        let key = entries[tapeUUID.lowercased()] != nil ? tapeUUID.lowercased() : (catalogNumber ?? "")
        guard let entry = entries[key] else { throw SiteError.server(status: 404, message: "No post") }
        guard entry.updatedAt == expectedUpdatedAt else { throw SiteError.changedOnSite }
        entries[key] = nil
        deleted.append(entry.catalogNumber)
    }
}

private let hasTools = FileManager.default.fileExists(atPath: KnownTools.ffmpeg.path)

@Suite struct PushTests {
    let library: Library
    let root: URL

    init() throws {
        root = try TestFolders.make("push")
        let paths = LibraryPaths(
            library: root.appending(path: "library", directoryHint: .isDirectory),
            support: root.appending(path: "support", directoryHint: .isDirectory)
        )
        try paths.createDirectories()
        library = Library(database: try AppDatabase.open(at: paths.database), paths: paths)
    }

    private func addTape(
        title: String = "Test Tape",
        medium: String? = "Cassette",
        approved: Bool = true,
        pushed: Bool = false,
        seconds: Int = 6
    ) async throws -> (tapeID: Int64, sourceID: Int64, master: URL) {
        let uuid = UUID().uuidString
        let folder = library.paths.masters.appending(path: uuid, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let master = folder.appending(path: "side-a.wav")
        if hasTools {
            let (status, _) = try await runToolCapturingOutput(KnownTools.ffmpeg, arguments: [
                "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=96000:duration=\(seconds)",
                "-c:a", "pcm_s24le", master.path,
            ], timeout: .seconds(60))
            #expect(status == 0)
        } else {
            try Data().write(to: master)
        }
        return try await library.database.writer.write { db in
            var tape = Tape(
                uuid: uuid, title: title, medium: medium,
                approvedAt: approved ? Date() : nil, pushedAt: pushed ? Date() : nil, createdAt: Date()
            )
            try tape.insert(db)
            var source = Source(
                tapeId: tape.id!, position: 0, side: "A",
                masterPath: "masters/\(uuid)/side-a.wav", duration: Double(seconds)
            )
            try source.insert(db)
            return (tape.id!, source.id!, master)
        }
    }

    private func pusher(_ site: FakeSite) -> Pusher {
        var pusher = Pusher(library: library, site: site)
        pusher.retryDelays = [.zero, .zero]
        return pusher
    }

    private func fetchTape(_ id: Int64) async throws -> Tape? {
        try await library.database.writer.read { try Tape.fetchOne($0, key: id) }
    }

    // MARK: The plan

    @Test func mediaMapToTheSitesNames() {
        #expect(siteMedium(for: "7\" Reel-to-Reel") == "reel-to-reel-7")
        #expect(siteMedium(for: "5\" Reel-to-Reel") == "reel-to-reel-5")
        #expect(siteMedium(for: "10\" Reel-to-Reel") == "reel-to-reel-10")
        #expect(siteMedium(for: "Reel") == "reel-to-reel")
        #expect(siteMedium(for: "Cassette") == "cassette")
        #expect(siteMedium(for: "Microcassette") == "microcassette")
        #expect(siteMedium(for: "Wax cylinder") == nil)
        #expect(siteMedium(for: nil) == nil)
    }

    @Test func tapesThatArentReadyAreRefused() async throws {
        let unapproved = try await addTape(approved: false)
        await #expect(throws: PushError.notApproved) { try await library.pushPlan(tapeID: unapproved.tapeID) }

        let pushed = try await addTape(pushed: true)
        await #expect(throws: PushError.alreadyOnSite) { try await library.pushPlan(tapeID: pushed.tapeID) }

        let odd = try await addTape(medium: "Wax cylinder")
        await #expect(throws: PushError.unknownMedium("Wax cylinder")) { try await library.pushPlan(tapeID: odd.tapeID) }
    }

    @Test func oneTrackTakesTheTapesTitle() async throws {
        let tape = try await addTape(title: "Sunday Service")
        let plan = try await library.pushPlan(tapeID: tape.tapeID)
        #expect(plan.tracks.map(\.title) == ["Sunday Service"])
        #expect(plan.medium == "cassette")
    }

    @Test func markersTrimsAndNamesMakeTheTracks() async throws {
        let tape = try await addTape()
        try await library.addMarker(sourceID: tape.sourceID, time: 2, trackName: "Second")
        try await library.setTrim(sourceID: tape.sourceID, start: 1, end: 5)

        let plan = try await library.pushPlan(tapeID: tape.tapeID)
        #expect(plan.tracks.map(\.title) == ["Track 1", "Second"])
        #expect(plan.tracks.map(\.start) == [1, 2])
        #expect(plan.tracks.map(\.end) == [2, 5])
        #expect(plan.duration == 4)
    }

    // MARK: Pushing

    @Test(.enabled(if: hasTools)) func aPushCreatesAnEntryAndMarksTheTape() async throws {
        let tape = try await addTape()
        let site = FakeSite()

        let result = try await pusher(site).push(tapeID: tape.tapeID)

        #expect(result.catalogNumber == "RA-008")
        #expect(result.uploaded == 2)
        let stored = try await fetchTape(tape.tapeID)
        #expect(stored?.catalogNumber == "RA-008")
        #expect(stored?.pushedAt != nil)
        let entry = await site.entry(for: stored!.uuid)
        #expect(entry?.medium == "cassette")
        #expect(entry?.tracks.count == 1)
        #expect(stored?.siteUpdatedAt == entry?.updatedAt)
        #expect(FileManager.default.fileExists(atPath: library.pushFolder(tapeUUID: stored!.uuid).path) == false)
    }

    @Test(.enabled(if: hasTools)) func aFirstPushArrivesUnpublished() async throws {
        let tape = try await addTape()
        let site = FakeSite()

        try await pusher(site).push(tapeID: tape.tapeID)

        let stored = try #require(try await fetchTape(tape.tapeID))
        let entry = try #require(await site.entry(for: stored.uuid))
        #expect(entry.published == false)
        #expect(await site.updates.isEmpty, "nothing followed the push to publish it")
        #expect(SiteSnapshot.decode(stored.siteSnapshot)?.published == false)
    }

    @Test(.enabled(if: hasTools)) func pushingTheSameTapeTwiceUploadsNothingNew() async throws {
        let tape = try await addTape()
        let site = FakeSite()
        try await pusher(site).push(tapeID: tape.tapeID)
        let firstUploads = await site.uploads.count

        // As if the local record were lost, so the app tries again from scratch.
        try await library.database.writer.write { db in
            try db.execute(sql: "UPDATE tape SET pushed_at = NULL, catalog_number = NULL WHERE id = ?", arguments: [tape.tapeID])
        }
        let second = try await pusher(site).push(tapeID: tape.tapeID)

        #expect(second.uploaded == 0)
        #expect(second.alreadyThere == firstUploads)
        #expect(second.catalogNumber == "RA-008")
        let uploads = await site.uploads.count
        let entries = await site.entries.count
        #expect(uploads == firstUploads)
        #expect(entries == 1)
    }

    @Test(.enabled(if: hasTools)) func aFailedPushResumesWithOnlyWhatsLeft() async throws {
        let tape = try await addTape()
        try await library.addMarker(sourceID: tape.sourceID, time: 2)
        let site = FakeSite()
        await site.setFailUploadsAfter(1)

        await #expect(throws: SiteError.self) { try await pusher(site).push(tapeID: tape.tapeID) }
        #expect(try await fetchTape(tape.tapeID)?.pushedAt == nil)
        #expect(await site.uploads.count == 1)

        await site.setFailUploadsAfter(nil)
        let result = try await pusher(site).push(tapeID: tape.tapeID)

        #expect(result.alreadyThere == 1)
        #expect(result.uploaded == 3)
        #expect(await Set(site.uploads).count == 4)
    }

    @Test(.enabled(if: hasTools)) func aLostConnectionIsRetried() async throws {
        let tape = try await addTape()
        let site = FakeSite()
        await site.setTemporaryFailures(2)

        let result = try await pusher(site).push(tapeID: tape.tapeID)

        #expect(result.uploaded == 2)
    }

    @Test(.enabled(if: hasTools)) func whenTheEntryCantBeCreatedTheTapeStaysUnpushed() async throws {
        let tape = try await addTape()
        let site = FakeSite()
        await site.setFailCreate(true)

        await #expect(throws: URLError.self) { try await pusher(site).push(tapeID: tape.tapeID) }

        let stored = try await fetchTape(tape.tapeID)
        #expect(stored?.pushedAt == nil)
        #expect(stored?.catalogNumber == nil)
    }

    @Test(.enabled(if: hasTools)) func onlyHandWrittenTextIsSent() async throws {
        let tape = try await addTape()
        let marker = try await library.addMarker(sourceID: tape.sourceID, time: 2, trackName: "Second")
        try await library.database.writer.write { db in
            try db.execute(sql: "UPDATE track SET summary = ?, summary_short = 'Short.'", arguments: [
                #"{"summary_short":"Short.","summary_long":"Claude wrote this."}"#,
            ])
        }
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: marker, description: "I wrote this.")
        var fields = PostFields(tape: try await fetchTape(tape.tapeID)!)
        fields.description = "About the tape."
        fields.recordedDate = "c. 1975"
        fields.whereFound = "Estate sale"
        fields.dateFound = "2024-03-15"
        try await library.savePost(tapeID: tape.tapeID, fields: fields)
        let site = FakeSite()

        try await pusher(site).push(tapeID: tape.tapeID)

        let uuid = try await fetchTape(tape.tapeID)!.uuid
        let entry = try #require(await site.entry(for: uuid))
        #expect(entry.tracks.map(\.description) == [nil, "I wrote this."])
        #expect(entry.description == "About the tape.")
        #expect(entry.estimatedRecordingDate == "c. 1975")
        #expect(entry.whereFound == "Estate sale")
        #expect(entry.dateFound == "2024-03-15")
        let sent = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!sent.contains("Claude wrote this"))
        #expect(!sent.contains("summary_short"))
    }

    @Test(.enabled(if: hasTools)) func photosGoUpInOrderWithCaptions() async throws {
        let tape = try await addTape()
        let first = root.appending(path: "box.png")
        let second = root.appending(path: "label.png")
        for (url, color) in [(first, "red"), (second, "blue")] {
            let (status, _) = try await runToolCapturingOutput(KnownTools.ffmpeg, arguments: [
                "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=\(color):s=32x24", "-frames:v", "1", url.path,
            ], timeout: .seconds(30))
            #expect(status == 0)
        }
        let box = try await library.addImage(tapeID: tape.tapeID, from: first)
        try await library.addImage(tapeID: tape.tapeID, from: second)
        try await library.setCaption(imageID: box.id!, caption: "The box")
        let site = FakeSite()

        let result = try await pusher(site).push(tapeID: tape.tapeID)

        #expect(result.uploaded == 4)
        let uuid = try await fetchTape(tape.tapeID)!.uuid
        let entry = try #require(await site.entry(for: uuid))
        #expect(entry.images.map(\.filename) == ["box.png", "label.png"])
        #expect(entry.images.map(\.caption) == ["The box", nil])
        #expect(entry.images.first?.sha256 == box.sha256)
        let linked = try await library.database.writer.read { try TapeImage.order(Column("position")).fetchAll($0).map(\.siteUrl) }
        #expect(linked == entry.images.map(\.url), "each photo knows its URL on the site")
    }

    @Test(.enabled(if: hasTools)) func theMasterIsNeverChanged() async throws {
        let tape = try await addTape()
        try await library.addMarker(sourceID: tape.sourceID, time: 3)
        let before = try sha256(of: tape.master)

        try await pusher(FakeSite()).push(tapeID: tape.tapeID)

        #expect(try sha256(of: tape.master) == before)
    }

    @Test(.enabled(if: hasTools)) func theTranscriptGoesWithTheTape() async throws {
        let tape = try await addTape()
        try await library.database.writer.write { db in
            var line = Segment(sourceId: tape.sourceID, startTime: 1, endTime: 2, text: "Hello there")
            try line.insert(db)
        }
        let site = FakeSite()

        let result = try await pusher(site).push(tapeID: tape.tapeID)

        #expect(result.uploaded == 3)
        let stored = try await fetchTape(tape.tapeID)
        #expect(await site.files.count == 3)
    }

    @Test(.enabled(if: hasTools)) func deletingATapeRemovesAnUnfinishedPush() async throws {
        let tape = try await addTape()
        let site = FakeSite()
        await site.setFailCreate(true)
        _ = try? await pusher(site).push(tapeID: tape.tapeID)
        let uuid = try await fetchTape(tape.tapeID)!.uuid
        #expect(FileManager.default.fileExists(atPath: library.pushFolder(tapeUUID: uuid).path))

        try await library.delete(tapeID: tape.tapeID, trash: { try FileManager.default.removeItem(at: $0) })

        #expect(!FileManager.default.fileExists(atPath: library.pushFolder(tapeUUID: uuid).path))
    }

    // MARK: The audio files

    private func probe(_ url: URL) async throws -> AudioDetails { try await probeAudio(url) }

    /// Leaves the made files behind by failing at the last step, then returns them.
    private func madeFiles(tapeID: Int64) async throws -> [URL] {
        let site = FakeSite()
        await site.setFailCreate(true)
        _ = try? await pusher(site).push(tapeID: tapeID)
        let uuid = try await fetchTape(tapeID)!.uuid
        return try FileManager.default
            .contentsOfDirectory(at: library.pushFolder(tapeUUID: uuid), includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test(.enabled(if: hasTools)) func tracksAreCutAtTheRightPlaces() async throws {
        let tape = try await addTape()
        try await library.addMarker(sourceID: tape.sourceID, time: 2)
        let flacs = try await madeFiles(tapeID: tape.tapeID).filter { $0.pathExtension == "flac" }

        #expect(flacs.count == 2)
        let durations = try await flacs.asyncMap { try await probe($0).duration }.sorted()
        #expect(abs(durations[0] - 2) < 0.001)
        #expect(abs(durations[1] - 4) < 0.001)
    }

    @Test(.enabled(if: hasTools)) func downloadsKeepTheMastersQuality() async throws {
        let tape = try await addTape()
        let flac = try await madeFiles(tapeID: tape.tapeID).first { $0.pathExtension == "flac" }!
        let details = try await probe(flac)
        #expect(details.sampleRate == 96000)
        #expect(details.bitDepth == 24)
        #expect(details.channels == 1)

        // Lossless means the decoded samples are identical to the master's.
        #expect(try await pcmHash(flac) == pcmHash(tape.master))
    }

    @Test(.enabled(if: hasTools)) func streamingCopiesMatchTheSitesSettings() async throws {
        let tape = try await addTape()
        let mp3 = try await madeFiles(tapeID: tape.tapeID).first { $0.pathExtension == "mp3" }!
        let details = try await probe(mp3)
        #expect(details.sampleRate == 44100)
        #expect(details.channels == 2)
    }

    @Test(.enabled(if: hasTools)) func theSameAudioAlwaysMakesTheSameFiles() async throws {
        let tape = try await addTape()
        let first = try await madeFiles(tapeID: tape.tapeID).map { try sha256(of: $0) }
        let uuid = try await fetchTape(tape.tapeID)!.uuid
        try FileManager.default.removeItem(at: library.pushFolder(tapeUUID: uuid))

        let second = try await madeFiles(tapeID: tape.tapeID).map { try sha256(of: $0) }

        #expect(first == second)
    }

    private func pcmHash(_ url: URL) async throws -> String {
        let (status, output) = try await runToolCapturingOutput(KnownTools.ffmpeg, arguments: [
            "-v", "error", "-i", url.path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "md5", "-",
        ], timeout: .seconds(60))
        #expect(status == 0)
        return String(decoding: output, as: UTF8.self)
    }

    @Test func filenamesAreSafe() {
        #expect(Pusher.filename(for: "Side A", number: 1) == "01 Side A")
        #expect(Pusher.filename(for: "a/b:c", number: 12) == "12 a b c")
        #expect(Pusher.filename(for: "///", number: 3).hasPrefix("03 "))
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}

/// Answers requests without any network, and remembers what was sent.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var seen = request
        if seen.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            seen.httpBody = data
        }
        Self.lock.withLock { Self.requests.append(seen) }
        let (status, data) = Self.handler?(seen) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct SiteClientTests {
    private func client() -> SiteClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.requests = []
        return SiteClient(
            baseURL: URL(string: "https://site.invalid")!,
            apiKey: "secret",
            session: URLSession(configuration: configuration)
        )
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
    }

    private var file: PushFile {
        PushFile(
            url: TestFolders.file("stub.flac"),
            sha256: String(repeating: "a", count: 64), bytes: 3,
            filename: "01 One.flac", contentType: "audio/flac", kind: .audio
        )
    }

    @Test func checkSendsTheKeyAndReadsTheAnswer() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(#"{"files":{"abc":{"key":"k","url":"u","bytes":1}}}"#.utf8)) }

        let existing = try await site.existingFiles(["abc", "def"])

        #expect(existing == ["abc"])
        let request = try #require(StubProtocol.requests.first)
        #expect(request.url?.path == "/api/sync/check")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(try body(request)["hashes"] as? [String] == ["abc", "def"])
    }

    @Test func uploadRequestsMatchTheSitesRoute() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(#"{"files":[{"uploadUrl":"https://r2.invalid/x","key":"audio/a.flac"}]}"#.utf8)) }

        let upload = try await site.requestUpload(file)

        #expect(upload == SiteUpload(url: URL(string: "https://r2.invalid/x")!, key: "audio/a.flac"))
        let sent = try body(try #require(StubProtocol.requests.first))
        let item = try #require((sent["files"] as? [[String: Any]])?.first)
        #expect(item["sha256"] as? String == file.sha256)
        #expect(item["type"] as? String == "audio")
        #expect(item["contentType"] as? String == "audio/flac")
    }

    @Test func audioGoesToStorageWithoutTheKey() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data()) }
        let file = file
        try Data("abc".utf8).write(to: file.url)
        defer { try? FileManager.default.removeItem(at: file.url) }

        try await site.upload(file, to: URL(string: "https://r2.invalid/x?sig=1")!) { _ in }

        let request = try #require(StubProtocol.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/flac")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func entriesMatchTheSitesRouteAndLeaveOutEmptyFields() async throws {
        let site = client()
        StubProtocol.handler = { _ in (201, Data(Self.entryJSON.utf8)) }
        let entry = SiteEntry(
            tapeUuid: "7D2B34B9-7ADD-4ACF-A048-656302E614FA", title: "T", medium: "cassette",
            description: nil, estimatedRecordingDate: nil,
            tracks: [.init(title: "One", audioSha256: "a", audioFilename: "a.mp3", downloadSha256: "b", downloadFilename: "b.flac", duration: 2, description: nil)],
            transcriptSha256: nil, metadata: ["speed": "1⅞ ips"]
        )

        #expect(try await site.createEntry(entry).catalogNumber == "RA-008")

        let sent = try body(try #require(StubProtocol.requests.first))
        #expect(sent["tapeUuid"] as? String == entry.tapeUuid)
        #expect(sent["description"] == nil)
        #expect(sent["transcriptSha256"] == nil)
        #expect((sent["tracks"] as? [[String: Any]])?.first?["downloadSha256"] as? String == "b")
    }

    @Test func aRepeatPushReadsTheExistingNumber() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(Self.entryJSON.utf8)) }
        let entry = SiteEntry(tapeUuid: "u", title: "T", medium: "cassette", description: nil, estimatedRecordingDate: nil, tracks: [], transcriptSha256: nil, metadata: [:])
        let state = try await site.createEntry(entry)
        #expect(state.catalogNumber == "RA-008")
        #expect(state.updatedAt == "2026-11-17T10:00:00.000Z")
        #expect(state.tracks.first?.downloadSha256 == nil)
        #expect(state.images.first?.caption == "Lid")
    }

    static let entryJSON = #"""
        {"id":9,"catalogNumber":"RA-008","title":"T","description":null,"medium":"cassette","whereFound":null,
         "dateFound":null,"estimatedRecordingDate":null,"published":false,"updatedAt":"2026-11-17T10:00:00.000Z",
         "tracks":[{"title":"One","description":null,"duration":2,"audioUrl":"https://r/a.mp3","downloadUrl":null,
                    "audioSha256":"aa","downloadSha256":null}],
         "images":[{"url":"https://r/i.jpg","filename":"i.jpg","caption":"Lid","sha256":null}]}
        """#

    @Test func entriesAreReadByTapeAndNumber() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(Self.entryJSON.utf8)) }

        let state = try await site.fetchEntry(tapeUUID: "7D2B34B9-7ADD-4ACF-A048-656302E614FA", catalogNumber: "RA-008")

        #expect(state.title == "T")
        let request = try #require(StubProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/sync/entry")
        #expect(request.url?.query?.contains("catalogNumber=RA-008") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func everyPostIsListedWithItsOwner() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(#"""
            {"entries":[{"catalogNumber":"RA-001","title":"A","published":true,"updatedAt":"t","tapeUuid":null,
                         "trackCount":2,"imageCount":1,"duration":61.5},
                        {"catalogNumber":"RA-009","title":"B","published":false,"updatedAt":"u",
                         "tapeUuid":"7d2b34b9-7add-4acf-a048-656302e614fa","trackCount":1,"imageCount":0,"duration":3}]}
            """#.utf8)) }

        let entries = try await site.listEntries()

        #expect(entries.map(\.catalogNumber) == ["RA-001", "RA-009"])
        #expect(entries[0].tapeUuid == nil)
        #expect(entries[1].tapeUuid == "7d2b34b9-7add-4acf-a048-656302e614fa")
        #expect(entries[0].duration == 61.5)
        let request = try #require(StubProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/sync/entries")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func deletingSendsTheTapeAndWhenItWasRead() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(#"{"deleted":"RA-009","removedFiles":2}"#.utf8)) }

        try await site.deleteEntry(tapeUUID: "u", catalogNumber: "RA-009", expectedUpdatedAt: "t")

        let request = try #require(StubProtocol.requests.first)
        #expect(request.url?.path == "/api/sync/delete")
        let sent = try body(request)
        #expect(sent["catalogNumber"] as? String == "RA-009")
        #expect(sent["expectedUpdatedAt"] as? String == "t")

        StubProtocol.handler = { _ in (409, Data(#"{"error":"This post changed on the site since it was last read. Refresh it first."}"#.utf8)) }
        await #expect(throws: SiteError.changedOnSite) {
            try await site.deleteEntry(tapeUUID: "u", catalogNumber: "RA-009", expectedUpdatedAt: "t")
        }
    }

    @Test func publishingIsSentOnlyWhenAsked() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(Self.entryJSON.utf8)) }
        var update = SiteUpdate(tapeUuid: "u", catalogNumber: "RA-008", expectedUpdatedAt: "t", fields: nil, tracks: nil, images: nil)
        _ = try await site.updateEntry(update)
        #expect(try body(try #require(StubProtocol.requests.last))["published"] == nil)

        update.published = true
        _ = try await site.updateEntry(update)
        #expect(try body(try #require(StubProtocol.requests.last))["published"] as? Bool == true)
    }

    @Test func updatesSendOnlyWhatChangedAndNullForCleared() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(Self.entryJSON.utf8)) }
        var fields = SiteChanges.Fields()
        fields.title = "New"
        fields.whereFound = .some(nil)
        var track = SiteChanges.TrackText(sha256: "aa", label: "Track 1")
        track.description = .some(nil)

        _ = try await site.updateEntry(SiteUpdate(
            tapeUuid: "u", catalogNumber: "RA-008", expectedUpdatedAt: "t",
            fields: fields, tracks: [track], images: nil
        ))

        let sent = try body(try #require(StubProtocol.requests.first))
        let sentFields = try #require(sent["fields"] as? [String: Any])
        #expect(sentFields["title"] as? String == "New")
        #expect(sentFields["whereFound"] is NSNull, "a cleared field is sent as null")
        #expect(sentFields.keys.contains("description") == false, "an unchanged field is left out")
        let sentTrack = try #require((sent["tracks"] as? [[String: Any]])?.first)
        #expect(sentTrack["description"] is NSNull)
        #expect(sentTrack.keys.contains("title") == false)
        #expect(sentTrack.keys.contains("label") == false)
        #expect(sent.keys.contains("images") == false)
        #expect(sent["expectedUpdatedAt"] as? String == "t")
    }

    @Test func aStaleUpdateIsReportedAsChangedOnTheSite() async throws {
        let site = client()
        StubProtocol.handler = { _ in (409, Data(#"{"error":"This post changed on the site since it was last read. Refresh it first."}"#.utf8)) }
        await #expect(throws: SiteError.changedOnSite) {
            try await site.updateEntry(SiteUpdate(tapeUuid: "u", catalogNumber: nil, expectedUpdatedAt: "t", fields: nil, tracks: nil, images: nil))
        }
    }

    @Test func failuresSayWhatWentWrong() async throws {
        let site = client()
        StubProtocol.handler = { _ in (401, Data()) }
        await #expect(throws: SiteError.rejectedKey) { try await site.existingFiles([]) }
        StubProtocol.handler = { _ in (501, Data()) }
        await #expect(throws: SiteError.notConfigured) { try await site.existingFiles([]) }
        StubProtocol.handler = { _ in (409, Data(#"{"error":"Files not uploaded yet"}"#.utf8)) }
        await #expect(throws: SiteError.server(status: 409, message: "Files not uploaded yet")) { try await site.existingFiles([]) }
    }

    @Test func onlyServerFaultsAreWorthRetrying() {
        #expect(Pusher.isTemporary(SiteError.server(status: 503, message: "")))
        #expect(!Pusher.isTemporary(SiteError.server(status: 409, message: "")))
        #expect(!Pusher.isTemporary(SiteError.rejectedKey))
        #expect(!Pusher.isTemporary(SiteError.notConfigured))
        #expect(Pusher.isTemporary(URLError(.networkConnectionLost)))
        #expect(!Pusher.isTemporary(URLError(.cancelled)))
    }
}

// MARK: Adjusted tracks

extension PushTests {
    private func setAdjustments(_ tape: (tapeID: Int64, sourceID: Int64, master: URL), _ adjustments: TrackAdjustments) async throws {
        try await library.setAdjustments(sourceID: tape.sourceID, startMarkerID: nil, adjustments)
    }

    /// Decodes a file to 32-bit samples of its first channel.
    private func samples(_ url: URL) async throws -> [Int32] {
        let output = root.appending(path: "\(UUID().uuidString).raw")
        let (status, _) = try await runToolCapturingOutput(KnownTools.ffmpeg, arguments: [
            "-v", "error", "-i", url.path, "-map", "0:a:0", "-ac", "1", "-f", "s32le", "-c:a", "pcm_s32le", output.path,
        ], timeout: .seconds(60))
        #expect(status == 0)
        let data = try Data(contentsOf: output)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    }

    /// A rising tone, so playing it backwards is easy to tell apart.
    private func addRisingTape(seconds: Int = 2) async throws -> (tapeID: Int64, sourceID: Int64, master: URL) {
        let tape = try await addTape(seconds: seconds)
        let (status, _) = try await runToolCapturingOutput(KnownTools.ffmpeg, arguments: [
            "-v", "error", "-y", "-f", "lavfi", "-i", "aevalsrc=0.5*t/\(seconds)*sin(2*PI*300*t):s=96000:d=\(seconds)",
            "-c:a", "pcm_s24le", tape.master.path,
        ], timeout: .seconds(60))
        #expect(status == 0)
        return tape
    }

    @Test func adjustmentsAreRoundedAndKeptInRange() {
        let adjusted = TrackAdjustments(gainDB: 40, speed: 0.50049, reversed: true)
        #expect(adjusted.gainDB == 24)
        #expect(adjusted.speed == 0.5)
        #expect(TrackAdjustments(gainDB: 3.04).gainDB == 3)
        #expect(TrackAdjustments(speed: 10).speed == 4)
        #expect(TrackAdjustments.none.isNeutral)
        #expect(!TrackAdjustments(reversed: true).isNeutral)
        #expect(adjusted.duration(of: 60) == 120)
    }

    @Test func filtersChangeLevelAndSpeedAtTheMastersRate() {
        #expect(TrackAdjustments.none.filters(sampleRate: 96000) == nil)
        #expect(TrackAdjustments(reversed: true).filters(sampleRate: 96000) == nil)
        #expect(TrackAdjustments(gainDB: 6).filters(sampleRate: 96000) == "volume=6.0dB")
        #expect(TrackAdjustments(gainDB: -1.5, speed: 0.5).filters(sampleRate: 96000)
            == "volume=-1.5dB,asetrate=48000,aresample=96000")
        #expect(TrackAdjustments(speed: 1.01).filters(sampleRate: 44100) == "asetrate=44541,aresample=44100")
    }

    @Test func adjustmentsAreSavedPerTrackAndShownEverywhere() async throws {
        let tape = try await addTape()
        let marker = try await library.addMarker(sourceID: tape.sourceID, time: 2)
        try await setAdjustments(tape, TrackAdjustments(gainDB: 3))
        try await library.setAdjustments(sourceID: tape.sourceID, startMarkerID: marker, TrackAdjustments(speed: 2, reversed: true))

        let post = try await library.database.writer.read { try Library.fetchPost($0, tapeID: tape.tapeID) }!
        #expect(post.tracks.map(\.adjustments) == [TrackAdjustments(gainDB: 3), TrackAdjustments(speed: 2, reversed: true)])
        #expect(post.tracks.map(\.duration) == [2, 2])

        let plan = try await library.pushPlan(tapeID: tape.tapeID)
        #expect(plan.tracks.map(\.duration) == [2, 2])
        #expect(plan.duration == 4)
    }

    @Test func tapesOnTheSiteCantBeAdjusted() async throws {
        let tape = try await addTape(pushed: true)
        await #expect(throws: AdjustmentError.alreadyOnSite) {
            try await setAdjustments(tape, TrackAdjustments(gainDB: 3))
        }
    }

    @Test(.enabled(if: hasTools)) func slowedTracksPlayLongerAtTheMastersRateAndDepth() async throws {
        let tape = try await addTape(seconds: 2)
        try await setAdjustments(tape, TrackAdjustments(speed: 0.5))
        let files = try await madeFiles(tapeID: tape.tapeID)
        let flac = try await probe(files.first { $0.pathExtension == "flac" }!)
        #expect(abs(flac.duration - 4) < 0.01)
        #expect(flac.sampleRate == 96000)
        #expect(flac.bitDepth == 24)
        let mp3 = try await probe(files.first { $0.pathExtension == "mp3" }!)
        #expect(abs(mp3.duration - 4) < 0.1)
        #expect(mp3.sampleRate == 44100)
    }

    @Test(.enabled(if: hasTools)) func levelChangesMakeItLouder() async throws {
        let tape = try await addTape(seconds: 1)
        let plain = try await samples(tape.master)
        try await setAdjustments(tape, TrackAdjustments(gainDB: 6))
        let flac = try await madeFiles(tapeID: tape.tapeID).first { $0.pathExtension == "flac" }!
        let louder = try await samples(flac)
        let ratio = Double(louder.map { abs(Int64($0)) }.max()!) / Double(plain.map { abs(Int64($0)) }.max()!)
        #expect(abs(ratio - 1.995) < 0.01)
    }

    @Test(.enabled(if: hasTools)) func reversedTracksAreTheMasterBackwards() async throws {
        let tape = try await addRisingTape()
        let marker = try await library.addMarker(sourceID: tape.sourceID, time: 1)
        try await library.setAdjustments(sourceID: tape.sourceID, startMarkerID: marker, TrackAdjustments(reversed: true))
        let master = try await samples(tape.master)
        let flacs = try await madeFiles(tapeID: tape.tapeID).filter { $0.pathExtension == "flac" }
        #expect(flacs.count == 2)

        // The second second of the master, sample for sample, in reverse.
        let expected = Array(master[96000..<192000].reversed())
        var matched = false
        for flac in flacs where try await samples(flac) == expected { matched = true }
        #expect(matched)

        // The working copy goes once the files are made, and the master is untouched.
        let uuid = try await fetchTape(tape.tapeID)!.uuid
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.pushFolder(tapeUUID: uuid).path)
        #expect(!leftovers.contains { $0.hasSuffix(".caf") })
        #expect(try await samples(tape.master) == master)
    }

    @Test(.enabled(if: hasTools)) func changingAdjustmentsMakesNewFiles() async throws {
        let tape = try await addTape(seconds: 1)
        let before = try await madeFiles(tapeID: tape.tapeID).filter { $0.pathExtension == "flac" }
        let plainHash = try sha256(of: before[0])
        try await setAdjustments(tape, TrackAdjustments(gainDB: -3))
        let after = try await madeFiles(tapeID: tape.tapeID).filter { $0.pathExtension == "flac" }
        let adjusted = after.first { $0.lastPathComponent != before[0].lastPathComponent }
        #expect(adjusted != nil)
        #expect(try adjusted.map { try sha256(of: $0) } != plainHash)
    }
}

// MARK: Appended tracks

extension PushTests {
    /// A six-second tape in three two-second tracks, with the markers that start the
    /// second and third.
    private func threeTracks() async throws -> (tape: (tapeID: Int64, sourceID: Int64, master: URL), second: Int64, third: Int64) {
        let tape = try await addRisingTape(seconds: 6)
        let second = try await library.addMarker(sourceID: tape.sourceID, time: 2, trackName: "Two")
        let third = try await library.addMarker(sourceID: tape.sourceID, time: 4, trackName: "Three")
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: nil, name: "One")
        return (tape, second, third)
    }

    private func post(_ tapeID: Int64) async throws -> SitePost {
        try await library.database.writer.read { try Library.fetchPost($0, tapeID: tapeID) }!
    }

    @Test(.enabled(if: hasTools)) func anAppendedTrackPlaysAfterTheOneItWasDroppedOn() async throws {
        let (tape, _, third) = try await threeTracks()
        try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: nil, to: tape.sourceID, targetMarkerID: third)

        let tracks = try await post(tape.tapeID).tracks
        #expect(tracks.map(\.name) == ["Two", "Three"])
        #expect(tracks[1].continuations.map(\.name) == ["One"])
        #expect(tracks[1].duration == 4)
        #expect(tracks[1].pieces.map(\.start) == [4, 0])

        let plan = try await library.pushPlan(tapeID: tape.tapeID)
        #expect(plan.tracks.count == 2)
        #expect(plan.duration == 6)
    }

    @Test(.enabled(if: hasTools)) func aJoinedTrackIsItsPiecesEndToEnd() async throws {
        let (tape, _, third) = try await threeTracks()
        try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: nil, to: tape.sourceID, targetMarkerID: third)
        let master = try await samples(tape.master)

        let flacs = try await madeFiles(tapeID: tape.tapeID).filter { $0.pathExtension == "flac" }
        #expect(flacs.count == 2)
        let joined = try #require(flacs.first { $0.lastPathComponent.hasPrefix("joined-") })
        let details = try await probe(joined)
        #expect(abs(details.duration - 4) < 0.001)
        #expect(details.sampleRate == 96000)
        #expect(details.bitDepth == 24)
        // Seconds 4–6 of the master, then seconds 0–2, sample for sample.
        #expect(try await samples(joined) == Array(master[384000..<576000]) + Array(master[0..<192000]))
        #expect(try await samples(tape.master) == master)
    }

    @Test(.enabled(if: hasTools)) func eachPieceKeepsItsOwnSettings() async throws {
        let (tape, _, third) = try await threeTracks()
        try await library.setAdjustments(sourceID: tape.sourceID, startMarkerID: nil, TrackAdjustments(speed: 0.5))
        try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: nil, to: tape.sourceID, targetMarkerID: third)
        #expect(try await library.pushPlan(tapeID: tape.tapeID).tracks[1].duration == 6)
        let joined = try await madeFiles(tapeID: tape.tapeID).first { $0.lastPathComponent.hasPrefix("joined-") && $0.pathExtension == "flac" }!
        let duration = try await probe(joined).duration
        #expect(abs(duration - 6) < 0.01)
    }

    @Test(.enabled(if: hasTools)) func appendingGoesOnTheEndAndBringsWhatFollows() async throws {
        let (tape, second, third) = try await threeTracks()
        // Two onto One, then Three onto One: One, Two, Three as one track.
        try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: second, to: tape.sourceID, targetMarkerID: nil)
        try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: third, to: tape.sourceID, targetMarkerID: nil)
        var tracks = try await post(tape.tapeID).tracks
        #expect(tracks.count == 1)
        #expect(tracks[0].pieces.map(\.name) == ["One", "Two", "Three"])

        // Two can't go onto Three, which already plays after it, nor onto itself.
        await #expect(throws: AppendError.ontoItself) {
            try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: nil, to: tape.sourceID, targetMarkerID: third)
        }
        await #expect(throws: AppendError.ontoItself) {
            try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: second, to: tape.sourceID, targetMarkerID: second)
        }

        // Detaching Two leaves Three with One.
        try await library.detachTrack(sourceID: tape.sourceID, startMarkerID: second)
        tracks = try await post(tape.tapeID).tracks
        #expect(tracks.map { $0.pieces.map(\.name) } == [["One", "Three"], ["Two"]])
    }

    @Test(.enabled(if: hasTools)) func removingTheTrackItFollowedFreesAPiece() async throws {
        let (tape, second, third) = try await threeTracks()
        try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: nil, to: tape.sourceID, targetMarkerID: third)
        // Joining Three onto Two removes Three's row, so One stands alone again.
        try await library.deleteMarker(id: third)
        let tracks = try await post(tape.tapeID).tracks
        #expect(tracks.map { $0.pieces.map(\.name) } == [["One"], ["Two"]])
        _ = second
    }

    @Test func tracksOfAPushedTapeCantBeAppended() async throws {
        let tape = try await addTape(pushed: true)
        let marker = try await library.addMarker(sourceID: tape.sourceID, time: 2)
        await #expect(throws: AppendError.alreadyOnSite) {
            try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: nil, to: tape.sourceID, targetMarkerID: marker)
        }
    }

    @Test func appendedTracksThatLoopStayApart() {
        func track(_ id: Int64) -> PostTrack {
            var track = PostTrack(sourceID: 1, startMarkerID: id, name: "\(id)", description: nil, start: 0, end: 1, summaryShort: nil, summaryLong: nil)
            track.trackID = id
            return track
        }
        let joined = Library.joinAppended([track(1), track(2), track(3)], parents: [1: 2, 2: 1, 3: 99])
        #expect(joined.map(\.trackID) == [1, 2, 3])
        let anyJoined = joined.contains { !$0.continuations.isEmpty }
        #expect(!anyJoined)
    }
}

// MARK: Track order

extension PushTests {
    private func names(_ tapeID: Int64) async throws -> [[String?]] {
        try await library.database.writer.read { try Library.fetchPost($0, tapeID: tapeID) }!.tracks.map { $0.pieces.map(\.name) }
    }

    @Test(.enabled(if: hasTools)) func tracksCanBeMovedAndThePushFollows() async throws {
        let tape = try await addRisingTape(seconds: 6)
        let second = try await library.addMarker(sourceID: tape.sourceID, time: 2, trackName: "Two")
        let third = try await library.addMarker(sourceID: tape.sourceID, time: 4, trackName: "Three")
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: nil, name: "One")

        try await library.moveTrack(sourceID: tape.sourceID, startMarkerID: third, to: 0)
        #expect(try await names(tape.tapeID) == [["Three"], ["One"], ["Two"]])
        try await library.moveTrack(sourceID: tape.sourceID, startMarkerID: nil, to: 2)
        #expect(try await names(tape.tapeID) == [["Three"], ["Two"], ["One"]])

        let plan = try await library.pushPlan(tapeID: tape.tapeID)
        #expect(plan.tracks.map(\.title) == ["Three", "Two", "One"])
        #expect(plan.tracks.map(\.start) == [4, 2, 0])
        _ = second
    }

    @Test(.enabled(if: hasTools)) func aSplitStaysNextToWhereItCameFrom() async throws {
        let tape = try await addRisingTape(seconds: 6)
        let second = try await library.addMarker(sourceID: tape.sourceID, time: 3, trackName: "Two")
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: nil, name: "One")
        try await library.moveTrack(sourceID: tape.sourceID, startMarkerID: second, to: 0)

        // Splitting One makes a new track, which plays straight after One.
        try await library.addMarker(sourceID: tape.sourceID, time: 1, trackName: "One, later")
        #expect(try await names(tape.tapeID) == [["Two"], ["One"], ["One, later"]])
    }

    @Test(.enabled(if: hasTools)) func movingAnAppendedPieceMakesItATrackAgain() async throws {
        let tape = try await addRisingTape(seconds: 6)
        let second = try await library.addMarker(sourceID: tape.sourceID, time: 2, trackName: "Two")
        let third = try await library.addMarker(sourceID: tape.sourceID, time: 4, trackName: "Three")
        try await library.saveTrack(sourceID: tape.sourceID, startMarkerID: nil, name: "One")
        try await library.appendTrack(sourceID: tape.sourceID, startMarkerID: nil, to: tape.sourceID, targetMarkerID: third)
        #expect(try await names(tape.tapeID) == [["Two"], ["Three", "One"]])

        try await library.moveTrack(sourceID: tape.sourceID, startMarkerID: nil, to: 0)
        #expect(try await names(tape.tapeID) == [["One"], ["Two"], ["Three"]])
        _ = second
    }

    @Test func pushedTapesKeepTheirOrder() async throws {
        let tape = try await addTape(pushed: true)
        await #expect(throws: AppendError.alreadyOnSite) {
            try await library.moveTrack(sourceID: tape.sourceID, startMarkerID: nil, to: 1)
        }
    }
}

// MARK: Cuts

extension PushTests {
    private func pieces(_ tapeID: Int64) async throws -> [PostTrack] {
        try await library.database.writer.read { try Library.fetchPost($0, tapeID: tapeID) }!.tracks.flatMap(\.pieces)
    }

    @Test(.enabled(if: hasTools)) func aCutTrackPushesOnlyWhatsKept() async throws {
        let tape = try await addRisingTape(seconds: 6)
        let second = try await library.addMarker(sourceID: tape.sourceID, time: 3, trackName: "Two")
        try await library.setCuts(sourceID: tape.sourceID, startMarkerID: second, start: 0.5, end: 1)
        let master = try await samples(tape.master)

        let tracks = try await pieces(tape.tapeID)
        #expect(tracks.map(\.start) == [0, 3.5])
        #expect(tracks.map(\.end) == [3, 5])
        #expect(tracks[1].spanStart == 3 && tracks[1].spanEnd == 6)
        let plan = try await library.pushPlan(tapeID: tape.tapeID)
        #expect(plan.duration == 4.5)

        let flacs = try await madeFiles(tapeID: tape.tapeID).filter { $0.pathExtension == "flac" }
        var matched = false
        for flac in flacs where try await samples(flac) == Array(master[336000..<480000]) { matched = true }
        #expect(matched)
        #expect(try await samples(tape.master) == master)
    }

    @Test func cutsFollowTheirAudioThroughSplitsAndJoins() async throws {
        let tape = try await addTape(seconds: 10)
        try await library.setCuts(sourceID: tape.sourceID, startMarkerID: nil, start: 1, end: 2)

        // Splitting keeps the end's cut on the new track's end.
        let marker = try await library.addMarker(sourceID: tape.sourceID, time: 5)
        var tracks = try await pieces(tape.tapeID)
        #expect(tracks.map(\.start) == [1, 5])
        #expect(tracks.map(\.end) == [5, 8])

        // Joining gives it back to the track before.
        try await library.deleteMarker(id: marker)
        tracks = try await pieces(tape.tapeID)
        #expect(tracks.map(\.start) == [1])
        #expect(tracks.map(\.end) == [8])
    }

    @Test func aCutMustLeaveSomethingAndNotOnAPushedTape() async throws {
        let tape = try await addTape(seconds: 4)
        await #expect(throws: MarkerError.invalidTrim) {
            try await library.setCuts(sourceID: tape.sourceID, startMarkerID: nil, start: 2, end: 1.8)
        }
        await #expect(throws: MarkerError.invalidTrim) {
            try await library.setCuts(sourceID: tape.sourceID, startMarkerID: nil, start: -1, end: 0)
        }
        try await library.database.writer.write { db in
            try db.execute(sql: "UPDATE tape SET pushed_at = ? WHERE id = ?", arguments: [Date(), tape.tapeID])
        }
        await #expect(throws: AppendError.alreadyOnSite) {
            try await library.setCuts(sourceID: tape.sourceID, startMarkerID: nil, start: 1, end: 0)
        }
    }
}
