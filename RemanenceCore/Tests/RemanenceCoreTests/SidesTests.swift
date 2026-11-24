import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct SidesTests {
    let library: Library
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "remanence-sides-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(
            library: root.appending(path: "library", directoryHint: .isDirectory),
            support: root.appending(path: "support", directoryHint: .isDirectory)
        )
        try paths.createDirectories()
        library = Library(database: try AppDatabase.open(at: paths.database), paths: paths)
    }

    /// A tape with sides A, B and C, each with a master and an opening track.
    private func threeSides(pushed: Bool = false) async throws -> (tape: Int64, sides: [Int64]) {
        let folder = library.paths.masters.appending(path: "T", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await library.database.writer.write { db in
            var tape = Tape(uuid: UUID().uuidString, title: "Aircheck", createdAt: Date())
            if pushed { tape.pushedAt = Date() }
            try tape.insert(db)
            var ids: [Int64] = []
            for (position, side) in ["A", "B", "C"].enumerated() {
                let name = "side-\(side.lowercased()).caf"
                try Data([UInt8(position)]).write(to: folder.appending(path: name))
                var source = Source(tapeId: tape.id!, position: position, side: side, masterPath: "masters/T/\(name)", duration: 60)
                try source.insert(db)
                var track = Track(sourceId: source.id!, name: "Side \(side)")
                try track.insert(db)
                try db.execute(sql: "INSERT INTO segment (source_id, start_time, end_time, text) VALUES (?, 0, 1, 'hello')", arguments: [source.id!])
                ids.append(source.id!)
            }
            return (tape.id!, ids)
        }
    }

    private func sides(_ tape: Int64) async throws -> [(side: String?, master: String, name: String?)] {
        try await library.database.writer.read { db in
            try Source.filter(Column("tape_id") == tape).order(Column("position")).fetchAll(db).map { source in
                let name = try String.fetchOne(db, sql: "SELECT name FROM track WHERE source_id = ? AND start_marker_id IS NULL", arguments: [source.id!])
                return (source.side, source.masterPath, name)
            }
        }
    }

    @Test func aReRecordingReplacesABadSide() async throws {
        let (tape, ids) = try await threeSides()
        let trashed = Locked<[String]>([])

        try await library.removeSide(sourceID: ids[1]) { url in
            trashed.mutate { $0.append(url.lastPathComponent) }
            try FileManager.default.removeItem(at: url)
        }
        try await library.renameSide(sourceID: ids[2], to: " B ")

        let result = try await sides(tape)
        #expect(result.map(\.side) == ["A", "B"])
        #expect(result.map(\.master) == ["masters/T/side-a.caf", "masters/T/side-c.caf"])
        #expect(result.map(\.name) == ["Side A", "Side B"])
        #expect(trashed.value == ["side-b.caf"])
        let segments = try await library.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM segment WHERE source_id = ?", arguments: [ids[1]])
        }
        #expect(segments == 0)
        let positions = try await library.database.writer.read { db in
            try Int.fetchAll(db, sql: "SELECT position FROM source WHERE tape_id = ? ORDER BY position", arguments: [tape])
        }
        #expect(positions == [0, 1])
    }

    @Test func aTrackNameTheUserGaveIsKept() async throws {
        let (tape, ids) = try await threeSides()
        try await library.database.writer.write { db in
            try db.execute(sql: "UPDATE track SET name = 'Second Hour' WHERE source_id = ?", arguments: [ids[2]])
        }
        try await library.removeSide(sourceID: ids[1]) { try FileManager.default.removeItem(at: $0) }
        try await library.renameSide(sourceID: ids[2], to: "B")
        #expect(try await sides(tape).map(\.name) == ["Side A", "Second Hour"])
    }

    @Test func aSideCantTakeAnotherSidesName() async throws {
        let (_, ids) = try await threeSides()
        await #expect(throws: SideError.nameTaken("b")) {
            try await library.renameSide(sourceID: ids[2], to: "b")
        }
        await #expect(throws: SideError.emptyName) {
            try await library.renameSide(sourceID: ids[2], to: "  ")
        }
    }

    @Test func removingASideMovesTheRestUp() async throws {
        let (tape, ids) = try await threeSides()
        try await library.removeSide(sourceID: ids[0]) { try FileManager.default.removeItem(at: $0) }
        #expect(try await sides(tape).map(\.side) == ["B", "C"])
    }

    @Test func aFailedTrashKeepsTheSide() async throws {
        let (tape, ids) = try await threeSides()
        struct TrashFailed: Error {}
        await #expect(throws: TrashFailed.self) {
            try await library.removeSide(sourceID: ids[1]) { _ in throw TrashFailed() }
        }
        #expect(try await sides(tape).map(\.side) == ["A", "B", "C"])
    }

    @Test func sidesOfAPushedTapeStay() async throws {
        let (_, ids) = try await threeSides(pushed: true)
        await #expect(throws: SideError.alreadyOnSite) {
            try await library.removeSide(sourceID: ids[1])
        }
        await #expect(throws: SideError.alreadyOnSite) {
            try await library.renameSide(sourceID: ids[2], to: "B")
        }
    }

    @Test func aSideBeingProcessedStays() async throws {
        let (_, ids) = try await threeSides()
        try await library.database.writer.write { db in
            try db.execute(sql: "INSERT INTO job (source_id, type, status, created_at) VALUES (?, 'prep', 'running', ?)", arguments: [ids[1], Date()])
        }
        await #expect(throws: SideError.stillProcessing) {
            try await library.removeSide(sourceID: ids[1])
        }
    }
}
