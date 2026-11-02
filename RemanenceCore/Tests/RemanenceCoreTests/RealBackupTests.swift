import AVFoundation
import Foundation
import Testing
@testable import RemanenceCore

/// Runs against an actual backup folder, so it's off unless asked for:
///
///     REMANENCE_BACKUP=~/Music/remanence-backup swift test --filter RealBackup
///
/// Set REMANENCE_LIBRARY to import into that folder instead of a temporary one.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REMANENCE_BACKUP"] != nil))
struct RealBackupTests {
    @Test func everyEntryImportsAndEveryMasterIsPlayable() async throws {
        let environment = ProcessInfo.processInfo.environment
        let backup = URL(filePath: try #require(environment["REMANENCE_BACKUP"]), directoryHint: .isDirectory)

        let paths: LibraryPaths
        if let library = environment["REMANENCE_LIBRARY"] {
            paths = LibraryPaths(library: URL(filePath: library, directoryHint: .isDirectory), support: LibraryPaths.standard.support)
        } else {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "remanence-real-\(UUID().uuidString)", directoryHint: .isDirectory)
            paths = LibraryPaths(library: root, support: root)
        }
        try paths.createDirectories()
        let database = try AppDatabase.open(at: paths.database)
        let importer = BackupImporter(database: database, paths: paths)

        let summary = try await importer.run(from: backup)
        print("Imported \(summary.imported), already there \(summary.alreadyInLibrary)")

        let shelf = try await database.writer.read { db in try Library.fetchShelf(db) }
        #expect(shelf.map(\.tape.catalogNumber) == (1...7).map { String(format: "RA-%03d", $0) })

        let library = Library(database: database, paths: paths)
        let manifest = try BackupImporter.readManifest(in: backup)
        var files = 0

        for tape in shelf {
            let entry = try #require(tape.tape.catalogNumber)
            print("\(entry) | \(tape.tape.medium ?? "?") | \(tape.tape.era ?? "-") | \(tape.items.count) track(s) | \(Int(tape.duration))s | \(tape.tape.title)")
            #expect(tape.tape.medium != nil, "\(entry) has no medium")
            #expect(tape.tape.description?.isEmpty == false, "\(entry) has no description")
            // Dollar amounts are fine; a whole paragraph like "$13" is not.
            let paragraphs = tape.tape.description?.components(separatedBy: "\n\n") ?? []
            #expect(!paragraphs.contains { $0.wholeMatch(of: /\$[0-9a-f]+/) != nil }, "\(entry) has an unresolved reference")

            let hashes = Set((manifest[entry] ?? []).map(\.sha256))
            for item in tape.items {
                let source = item.source
                let master = try library.url(forLibraryPath: source.masterPath)
                #expect(hashes.contains(try sha256(of: master)), "\(master.lastPathComponent) doesn't match")
                #expect(try await AVURLAsset(url: master).load(.isPlayable), "\(master.lastPathComponent) isn't playable")
                files += 1
                if let prepPath = source.prepPath {
                    #expect(hashes.contains(try sha256(of: try library.url(forLibraryPath: prepPath))))
                    files += 1
                }
                print("  \(item.name): \(source.sampleRate ?? 0) Hz, \(source.channels ?? 0) ch, \(source.bitDepth ?? 0)-bit")
            }
        }
        #expect(files == 16)
    }
}
