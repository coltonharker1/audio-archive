import Foundation
import GRDB
import Testing
@testable import RemanenceCore

/// Stands in for the site, keeping what a real one would, so nothing leaves this Mac.
private actor FakeSite: SiteAPI {
    var files: Set<String> = []
    var uploads: [String] = []
    var entries: [String: (number: String, entry: SiteEntry)] = [:]
    var failUploadsAfter: Int?
    var failCreate = false
    var temporaryFailures = 0

    func setFailUploadsAfter(_ count: Int?) { failUploadsAfter = count }
    func setFailCreate(_ fail: Bool) { failCreate = fail }
    func setTemporaryFailures(_ count: Int) { temporaryFailures = count }
    func entry(for uuid: String) -> SiteEntry? { entries[uuid]?.entry }

    func existingFiles(_ hashes: [String]) async throws -> Set<String> {
        files.intersection(hashes)
    }

    func requestUpload(_ file: PushFile) async throws -> SiteUpload {
        SiteUpload(url: URL(string: "https://storage.invalid/\(file.sha256)")!, key: "audio/\(file.sha256).x")
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
        files.insert(file.sha256)
    }

    func createEntry(_ entry: SiteEntry) async throws -> String {
        if failCreate { throw URLError(.badServerResponse) }
        if let existing = entries[entry.tapeUuid] { return existing.number }
        let number = "RA-\(String(format: "%03d", 8 + entries.count))"
        entries[entry.tapeUuid] = (number, entry)
        return number
    }
}

private let hasTools = FileManager.default.fileExists(atPath: KnownTools.ffmpeg.path)

@Suite struct PushTests {
    let library: Library
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "remanence-push-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        #expect(entry?.tracks.first?.audioFilename == "01 Test Tape.mp3")
        #expect(entry?.tracks.first?.downloadFilename == "01 Test Tape.flac")
        #expect(FileManager.default.fileExists(atPath: library.pushFolder(tapeUUID: stored!.uuid).path) == false)
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
        #expect(await site.entry(for: stored!.uuid)?.transcriptSha256 != nil)
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
            url: FileManager.default.temporaryDirectory.appending(path: "stub-\(UUID().uuidString).flac"),
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
        StubProtocol.handler = { _ in (201, Data(#"{"id":9,"catalogNumber":"RA-008"}"#.utf8)) }
        let entry = SiteEntry(
            tapeUuid: "7D2B34B9-7ADD-4ACF-A048-656302E614FA", title: "T", medium: "cassette",
            description: nil, estimatedRecordingDate: nil,
            tracks: [.init(title: "One", audioSha256: "a", audioFilename: "a.mp3", downloadSha256: "b", downloadFilename: "b.flac", duration: 2, description: nil)],
            transcriptSha256: nil, metadata: ["speed": "1⅞ ips"]
        )

        #expect(try await site.createEntry(entry) == "RA-008")

        let sent = try body(try #require(StubProtocol.requests.first))
        #expect(sent["tapeUuid"] as? String == entry.tapeUuid)
        #expect(sent["description"] == nil)
        #expect(sent["transcriptSha256"] == nil)
        #expect((sent["tracks"] as? [[String: Any]])?.first?["downloadSha256"] as? String == "b")
    }

    @Test func aRepeatPushReadsTheExistingNumber() async throws {
        let site = client()
        StubProtocol.handler = { _ in (200, Data(#"{"id":9,"catalogNumber":"RA-008","published":false}"#.utf8)) }
        let entry = SiteEntry(tapeUuid: "u", title: "T", medium: "cassette", description: nil, estimatedRecordingDate: nil, tracks: [], transcriptSha256: nil, metadata: [:])
        #expect(try await site.createEntry(entry) == "RA-008")
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
