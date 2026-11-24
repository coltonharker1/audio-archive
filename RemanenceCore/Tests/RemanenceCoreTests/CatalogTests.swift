import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct CatalogTests {
    let library: Library

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "remanence-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(
            library: root.appending(path: "library", directoryHint: .isDirectory),
            support: root.appending(path: "support", directoryHint: .isDirectory)
        )
        try paths.createDirectories()
        library = Library(database: try AppDatabase.open(at: paths.database), paths: paths)
    }

    @discardableResult
    private func addTape(_ number: String?, title: String = "Reel", onSite site: FakeSite? = nil) async throws -> Int64 {
        let uuid = UUID().uuidString
        let id = try await library.database.writer.write { db in
            var tape = Tape(uuid: uuid, catalogNumber: number, title: title, createdAt: Date())
            try tape.insert(db)
            return tape.id!
        }
        if let site {
            let state = try await site.createEntry(SiteEntry(
                tapeUuid: uuid, title: title, medium: "reel-to-reel-7", description: nil, estimatedRecordingDate: nil,
                tracks: [], images: [], transcriptSha256: nil, metadata: [:], catalogNumber: number
            ))
            try await library.database.writer.write { db in
                try db.execute(sql: "UPDATE tape SET pushed_at = ?, site_updated_at = ? WHERE id = ?",
                               arguments: [Date(), state.updatedAt, id])
            }
        }
        return id
    }

    private func numbers() async throws -> [String: String] {
        try await library.database.writer.read { db in
            Dictionary(uniqueKeysWithValues: try Tape.fetchAll(db).map { ($0.title, $0.catalogNumber ?? "") })
        }
    }

    @Test func numbersAreWrittenTheSameWayWhateverIsTyped() {
        #expect(CatalogNumber.format(12) == "RA-012")
        #expect(CatalogNumber.format(1000) == "RA-1000")
        #expect(CatalogNumber.normalized("12") == "RA-012")
        #expect(CatalogNumber.normalized(" ra-12 ") == "RA-012")
        #expect(CatalogNumber.normalized("RA-012") == "RA-012")
        #expect(CatalogNumber.normalized("RA-0") == nil)
        #expect(CatalogNumber.normalized("twelve") == nil)
        #expect(CatalogNumber.normalized("") == nil)
    }

    @Test func theNextNumberFillsTheFirstGapAndSkipsTheSites() async throws {
        #expect(try await library.nextCatalogNumber() == "RA-001")
        try await addTape("RA-001")
        try await addTape("RA-002")
        try await addTape("RA-004")
        try await addTape(nil)
        #expect(try await library.nextCatalogNumber() == "RA-003")
        // A post on the site that isn't here keeps its number.
        #expect(try await library.nextCatalogNumber(excluding: ["RA-003"]) == "RA-005")
    }

    @Test func aRecordingIsNumberedWhenItStarts() async throws {
        try await addTape("RA-001")
        let first = try await library.beginCapture(machine: nil, title: "One", speed: nil)
        let second = try await library.beginCapture(machine: nil, title: "Two", speed: nil, excludingNumbers: ["RA-003"])
        let tapes = try await library.database.writer.read { db in
            try [first.tapeID, second.tapeID].map { try Tape.fetchOne(db, key: $0)!.catalogNumber }
        }
        #expect(tapes == ["RA-002", "RA-004"])

        // Deleted before it reached the site, its number is free again.
        try await library.delete(tapeID: first.tapeID) { try FileManager.default.removeItem(at: $0) }
        #expect(try await library.nextCatalogNumber() == "RA-002")
    }

    @Test func tapesOnlyHereSwapNumbers() async throws {
        let a = try await addTape("RA-011", title: "Choir")
        let b = try await addTape("RA-012", title: "Storm")
        let site = FakeSite()
        try await Pusher(library: library, site: site).renumber([
            Renumbering(tapeID: a, catalogNumber: "RA-012"),
            Renumbering(tapeID: b, catalogNumber: "RA-011"),
        ])
        #expect(try await numbers() == ["Choir": "RA-012", "Storm": "RA-011"])
        #expect(await site.renumberings.isEmpty)
    }

    @Test func postsOnTheSiteSwapThereFirst() async throws {
        let site = FakeSite()
        let a = try await addTape("RA-011", title: "Choir", onSite: site)
        let b = try await addTape("RA-012", title: "Storm", onSite: site)
        let c = try await addTape("RA-013", title: "Not pushed")
        try await Pusher(library: library, site: site).renumber([
            Renumbering(tapeID: a, catalogNumber: "RA-012"),
            Renumbering(tapeID: b, catalogNumber: "RA-011"),
            Renumbering(tapeID: c, catalogNumber: "RA-014"),
        ])
        #expect(try await numbers() == ["Choir": "RA-012", "Storm": "RA-011", "Not pushed": "RA-014"])
        let sent = try #require(await site.renumberings.first)
        #expect(sent.map(\.newCatalogNumber) == ["RA-012", "RA-011"])
        // The site's new clocks are kept, so the next update isn't refused.
        let clocks = try await library.database.writer.read { db in
            try [a, b].map { try Tape.fetchOne(db, key: $0)!.siteUpdatedAt }
        }
        let uuids = try await library.database.writer.read { db in try [a, b].map { try Tape.fetchOne(db, key: $0)!.uuid.lowercased() } }
        #expect(clocks[0] == (await site.entry(for: uuids[0]))?.updatedAt)
        #expect(clocks[1] == (await site.entry(for: uuids[1]))?.updatedAt)
    }

    @Test func nothingChangesHereIfTheSiteRefuses() async throws {
        let site = FakeSite()
        let a = try await addTape("RA-011", title: "Choir", onSite: site)
        // Taken on the site by a post that isn't in this library.
        _ = try await site.createEntry(SiteEntry(
            tapeUuid: UUID().uuidString, title: "Elsewhere", medium: "other", description: nil, estimatedRecordingDate: nil,
            tracks: [], images: [], transcriptSha256: nil, metadata: [:], catalogNumber: "RA-020"
        ))
        await #expect(throws: SiteError.self) {
            try await Pusher(library: library, site: site).renumber([Renumbering(tapeID: a, catalogNumber: "RA-020")])
        }
        #expect(try await numbers() == ["Choir": "RA-011"])
    }

    @Test func badRenumberingsAreRefusedBeforeAnythingIsSent() async throws {
        let site = FakeSite()
        let a = try await addTape("RA-011", title: "Choir", onSite: site)
        let b = try await addTape("RA-012", title: "Storm")
        let pusher = Pusher(library: library, site: site)
        await #expect(throws: CatalogError.invalid("12")) {
            try await pusher.renumber([Renumbering(tapeID: a, catalogNumber: "12")])
        }
        await #expect(throws: CatalogError.duplicate("RA-015")) {
            try await pusher.renumber([Renumbering(tapeID: a, catalogNumber: "RA-015"), Renumbering(tapeID: b, catalogNumber: "RA-015")])
        }
        await #expect(throws: CatalogError.taken("RA-012", by: "Storm")) {
            try await pusher.renumber([Renumbering(tapeID: a, catalogNumber: "RA-012")])
        }
        #expect(await site.renumberings.isEmpty)
    }
}
