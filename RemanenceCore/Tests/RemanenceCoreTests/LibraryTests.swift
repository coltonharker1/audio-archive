import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct LibraryTests {
    let fixture: BackupFixture

    init() throws {
        fixture = try BackupFixture()
    }

    private func importPhoneCall() async throws -> (Library, ShelfTape) {
        try fixture.addEntry(
            "RA-004", title: "Phone Call", medium: "Microcassette",
            tracks: [.init(title: "Phone Call", audio: "prep.wav", download: "master.wav")]
        )
        let (_, importer, library) = try fixture.open()
        _ = try await importer.run(from: fixture.folder)
        let shelf = try await library.database.writer.read { db in try Library.fetchShelf(db) }
        return (library, try #require(shelf.first))
    }

    @Test func deletingTrashesTheAudioAndRemovesTheTape() async throws {
        let (library, tape) = try await importPhoneCall()
        let trashed = Locked<[String]>([])

        try await library.delete(tapeID: tape.id) { url in
            trashed.mutate { $0.append(url.lastPathComponent) }
            try FileManager.default.removeItem(at: url)
        }

        #expect(Set(trashed.value) == ["master.wav", "prep.wav"])
        let remaining = try await library.database.writer.read { db in try Library.fetchShelf(db) }
        #expect(remaining.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.library.masters.appending(path: "RA-004").path))
    }

    @Test func aFailedTrashKeepsTheTape() async throws {
        let (library, tape) = try await importPhoneCall()
        struct TrashFailed: Error {}

        await #expect(throws: TrashFailed.self) {
            try await library.delete(tapeID: tape.id) { _ in throw TrashFailed() }
        }

        let remaining = try await library.database.writer.read { db in try Library.fetchShelf(db) }
        #expect(remaining.count == 1)
    }

    @Test func deleteNeverTouchesPathsOutsideTheLibrary() async throws {
        let (library, tape) = try await importPhoneCall()
        try await library.database.writer.write { db in
            try db.execute(sql: "UPDATE source SET prep_path = '../../outside.wav'")
        }
        let trashed = Locked<[String]>([])

        await #expect(throws: LibraryError.self) {
            try await library.delete(tapeID: tape.id) { url in
                trashed.mutate { $0.append(url.path) }
            }
        }
        #expect(trashed.value.isEmpty)
        let remaining = try await library.database.writer.read { db in try Library.fetchShelf(db) }
        #expect(remaining.count == 1)
    }

    @Test func theShelfUpdatesWhenTheLibraryChanges() async throws {
        let (_, importer, library) = try fixture.open()
        var updates = library.shelfUpdates().makeAsyncIterator()
        #expect(try await updates.next()?.isEmpty == true)

        try fixture.addEntry(
            "RA-006", title: "Voicemail", medium: "Microcassette",
            tracks: [.init(title: "Voicemail", audio: "only.wav")]
        )
        _ = try await importer.run(from: fixture.folder)

        #expect(try await updates.next()?.first?.tape.title == "Voicemail")
    }

    @Test func formatComesFromTheMedium() {
        #expect(TapeFormat(medium: "7\" Reel-to-Reel") == .sevenInchReel)
        #expect(TapeFormat(medium: "5\" Reel-to-Reel") == .fiveInchReel)
        #expect(TapeFormat(medium: "Cassette") == .cassette)
        #expect(TapeFormat(medium: "Microcassette") == .microcassette)
        #expect(TapeFormat(medium: nil) == .unknown)
    }
}

@MainActor
@Suite struct AudioPlayerTests {
    @Test func aMissingFileReportsAFailure() async {
        let player = AudioPlayer()
        let loaded = await player.load(URL(filePath: "/nonexistent/file.wav"), duration: 1)
        #expect(!loaded)
        #expect(player.failure != nil)
    }

    @Test func aFilePlaysAndSeeks() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "remanence-player-\(UUID().uuidString).wav")
        try BackupFixture.wav(seconds: 4, seed: "player").write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let player = AudioPlayer()
        #expect(await player.load(file, duration: 4))

        await player.seek(to: 1)
        #expect(abs(player.currentTime - 1) < 0.01)

        player.play()
        #expect(player.isPlaying)

        // Audio start-up time varies with what else is running, so wait for
        // progress rather than expecting it by a fixed moment.
        let deadline = ContinuousClock.now + .seconds(8)
        while player.currentTime <= 1.2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(player.currentTime > 1.2)

        player.pause()
        #expect(!player.isPlaying)
    }

    @Test func theEndOfAFileIsReported() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "remanence-player-\(UUID().uuidString).wav")
        try BackupFixture.wav(seconds: 1, seed: "ending").write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let player = AudioPlayer()
        let finished = Locked(false)
        player.onFinished = { finished.mutate { $0 = true } }
        #expect(await player.load(file, duration: 1))

        player.play()
        let deadline = ContinuousClock.now + .seconds(8)
        while !finished.value, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(finished.value)
        #expect(!player.isPlaying)
    }
}
