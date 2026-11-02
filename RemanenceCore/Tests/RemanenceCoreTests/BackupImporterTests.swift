import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct BackupImporterTests {
    let fixture: BackupFixture

    init() throws {
        fixture = try BackupFixture()
    }

    private typealias T = BackupFixture.FixtureTrack

    private func addPhoneCall() throws {
        try fixture.addEntry(
            "RA-004",
            title: "Phone Call",
            medium: "Microcassette",
            tracks: [T(title: "Phone Call", audio: "prep.wav", download: "master.wav")]
        )
    }

    private func shelf(_ library: Library) async throws -> [ShelfTape] {
        try await library.database.writer.read { db in try Library.fetchShelf(db) }
    }

    @Test func readsTheCatalogPage() throws {
        try addPhoneCall()
        let html = try String(contentsOf: fixture.folder.appending(path: "catalog-pages/RA-004.html"), encoding: .utf8)
        let page = try CatalogPage(html: html)

        #expect(page.catalogNumber == "RA-004")
        #expect(page.title == "Phone Call")
        #expect(page.medium == "Microcassette")
        #expect(page.era == "1968")
        #expect(page.description == [
            "First paragraph.",
            "Second \"quoted\" paragraph.",
            BackupFixture.longParagraph,
            BackupFixture.shortRef,
        ].joined(separator: "\n\n"))
        #expect(page.tracks.first?.downloadFile == "master.wav")
    }

    @Test func aPageWithoutDataIsRejected() {
        #expect(throws: CatalogPage.ParseError.self) { try CatalogPage(html: "<html>Not found</html>") }
    }

    @Test func importsAMasterWithItsProcessedCopy() async throws {
        try addPhoneCall()
        let (_, importer, library) = try fixture.open()

        let summary = try await importer.run(from: fixture.folder)
        #expect(summary.imported == ["RA-004"])

        let tape = try #require(try await shelf(library).first)
        #expect(tape.tape.catalogNumber == "RA-004")
        #expect(tape.tape.medium == "Microcassette")
        #expect(tape.tape.pushedAt != nil)

        let source = try #require(tape.items.first?.source)
        #expect(source.masterPath == "masters/RA-004/master.wav")
        #expect(source.prepPath == "processed/RA-004/prep.wav")
        #expect(abs(source.duration - 1) < 0.01)
        #expect(source.sampleRate == 8000)
        #expect(source.channels == 1)
        #expect(source.bitDepth == 16)

        let master = fixture.library.library.appending(path: source.masterPath)
        let prep = fixture.library.library.appending(path: source.prepPath!)
        #expect(FileManager.default.fileExists(atPath: master.path))
        #expect(FileManager.default.fileExists(atPath: prep.path))
    }

    @Test func aFileWithNoSeparateDownloadBecomesTheMaster() async throws {
        try fixture.addEntry("RA-006", title: "Voicemail", medium: "Microcassette", tracks: [T(title: "Voicemail", audio: "only.wav")])
        let (_, importer, library) = try fixture.open()

        _ = try await importer.run(from: fixture.folder)

        let source = try #require(try await shelf(library).first?.items.first?.source)
        #expect(source.masterPath == "masters/RA-006/only.wav")
        #expect(source.prepPath == nil)
    }

    @Test func aFileListedForBothStreamingAndDownloadIsOnlyAMaster() async throws {
        try fixture.addAudio("same.wav", to: "RA-006")
        try fixture.writePage(
            "RA-006", title: "Voicemail", medium: "Microcassette",
            tracks: [T(title: "Voicemail", audio: "same.wav", download: "same.wav")]
        )
        let (_, importer, library) = try fixture.open()

        _ = try await importer.run(from: fixture.folder)

        let source = try #require(try await shelf(library).first?.items.first?.source)
        #expect(source.masterPath == "masters/RA-006/same.wav")
        #expect(source.prepPath == nil)
    }

    @Test func eachTrackBecomesASourceInOrder() async throws {
        try fixture.addEntry(
            "RA-001", title: "Accordion", medium: "7\" Reel-to-Reel",
            tracks: [T(title: "One", audio: "a.wav"), T(title: "Two", audio: "b.wav"), T(title: "Three", audio: "c.wav")]
        )
        let (_, importer, library) = try fixture.open()

        _ = try await importer.run(from: fixture.folder)

        let tape = try #require(try await shelf(library).first)
        #expect(tape.items.map(\.name) == ["One", "Two", "Three"])
        #expect(tape.items.map(\.source.position) == [0, 1, 2])
        #expect(abs(tape.duration - 3) < 0.01)
    }

    @Test func mastersAreProtectedFromEdits() async throws {
        try addPhoneCall()
        let (_, importer, library) = try fixture.open()
        _ = try await importer.run(from: fixture.folder)

        let source = try #require(try await shelf(library).first?.items.first?.source)
        let path = fixture.library.library.appending(path: source.masterPath).path
        #expect(!FileManager.default.isWritableFile(atPath: path))
    }

    @Test func importingAgainChangesNothing() async throws {
        try addPhoneCall()
        let (_, importer, library) = try fixture.open()

        _ = try await importer.run(from: fixture.folder)
        let again = try await importer.run(from: fixture.folder)

        #expect(again.imported.isEmpty)
        #expect(again.alreadyInLibrary == ["RA-004"])
        #expect(try await shelf(library).count == 1)
    }

    @Test func theBackupIsLeftUntouched() async throws {
        try addPhoneCall()
        let (_, importer, _) = try fixture.open()
        let file = fixture.folder.appending(path: "RA-004/master.wav")
        let before = try Data(contentsOf: file)

        _ = try await importer.run(from: fixture.folder)

        #expect(try Data(contentsOf: file) == before)
        #expect(FileManager.default.isWritableFile(atPath: file.path))
    }

    @Test func aCorruptFileStopsTheImportAndLeavesNothingBehind() async throws {
        try addPhoneCall()
        try Data("corrupted".utf8).write(to: fixture.folder.appending(path: "RA-004/master.wav"))
        let (_, importer, library) = try fixture.open()

        await #expect(throws: ImportError.hashMismatch("RA-004/master.wav")) {
            _ = try await importer.run(from: fixture.folder)
        }
        #expect(try await shelf(library).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.library.masters.appending(path: "RA-004").path))
    }

    @Test func aMissingFileStopsTheImport() async throws {
        try addPhoneCall()
        try FileManager.default.removeItem(at: fixture.folder.appending(path: "RA-004/prep.wav"))
        let (_, importer, library) = try fixture.open()

        await #expect(throws: ImportError.missingFile("RA-004/prep.wav")) {
            _ = try await importer.run(from: fixture.folder)
        }
        #expect(try await shelf(library).isEmpty)
    }

    @Test func aFileNotOnItsPageIsNeverSilentlyDropped() async throws {
        try addPhoneCall()
        try fixture.addAudio("stray.wav", to: "RA-004")
        let (_, importer, library) = try fixture.open()

        await #expect(throws: ImportError.unaccountedFile(entry: "RA-004", file: "stray.wav")) {
            _ = try await importer.run(from: fixture.folder)
        }
        #expect(try await shelf(library).isEmpty)
    }

    @Test func aPageForAnotherEntryIsRejected() async throws {
        try addPhoneCall()
        let pages = fixture.folder.appending(path: "catalog-pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try fixture.writePage("RA-999", title: "Wrong", medium: "Cassette", tracks: [T(title: "x", audio: "master.wav")])
        try FileManager.default.removeItem(at: pages.appending(path: "RA-004.html"))
        try FileManager.default.moveItem(at: pages.appending(path: "RA-999.html"), to: pages.appending(path: "RA-004.html"))
        let (_, importer, _) = try fixture.open()

        await #expect(throws: ImportError.catalogMismatch("RA-004")) {
            _ = try await importer.run(from: fixture.folder)
        }
    }

    @Test func aFolderThatIsNotABackupIsRejected() async throws {
        let (_, importer, _) = try fixture.open()
        let empty = fixture.library.peaks

        await #expect(throws: ImportError.noManifest) {
            _ = try await importer.run(from: empty)
        }
    }

    @Test func progressReachesEveryFile() async throws {
        try addPhoneCall()
        try fixture.addEntry("RA-006", title: "Voicemail", medium: "Microcassette", tracks: [T(title: "Voicemail", audio: "only.wav")])
        let (_, importer, _) = try fixture.open()

        let seen = Locked<[Int]>([])
        _ = try await importer.run(from: fixture.folder) { update in
            seen.mutate { $0.append(update.completedFiles) }
            #expect(update.totalFiles == 3)
        }
        #expect(seen.value == [1, 2, 3])
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
