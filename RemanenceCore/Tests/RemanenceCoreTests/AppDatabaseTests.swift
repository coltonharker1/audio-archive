import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct AppDatabaseTests {
    let database: AppDatabase

    init() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "remanence-tests-\(UUID().uuidString)/library.sqlite")
        database = try AppDatabase.open(at: path)
    }

    @discardableResult
    private func addSource(_ db: Database, sha256: String? = "abc") throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO tape (uuid, title, created_at) VALUES (?, 'Tape', '2026-11-02')",
            arguments: [UUID().uuidString]
        )
        let tape = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO source (tape_id, master_path, sha256, duration) VALUES (?, 'a.wav', ?, 60)",
            arguments: [tape, sha256]
        )
        return db.lastInsertedRowID
    }

    private func addSegment(_ db: Database, source: Int64, text: String) throws {
        try db.execute(
            sql: "INSERT INTO segment (source_id, start_time, end_time, text) VALUES (?, 0, 5, ?)",
            arguments: [source, text]
        )
    }

    private func matches(_ phrase: String) throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT snippet(segment_fts, 0, '[', ']', '…', 8) FROM segment_fts
                    WHERE segment_fts MATCH ?
                    """,
                arguments: [phrase]
            )
        }
    }

    @Test func foreignKeysAreEnforced() throws {
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO source (tape_id, master_path, duration) VALUES (999, 'a.wav', 1)")
            }
        }
    }

    @Test func theSameAudioCannotBeImportedTwice() throws {
        _ = try database.writer.write { db in try addSource(db, sha256: "same") }
        #expect(throws: DatabaseError.self) {
            _ = try database.writer.write { db in try addSource(db, sha256: "same") }
        }
    }

    @Test func sourcesBeingRecordedCanShareAnEmptyHash() throws {
        try database.writer.write { db in
            try addSource(db, sha256: nil)
            try addSource(db, sha256: nil)
        }
    }

    @Test func deletingATapeRemovesEverythingBelowIt() throws {
        try database.writer.write { db in
            let source = try addSource(db)
            try db.execute(sql: "INSERT INTO marker (source_id, time) VALUES (?, 10)", arguments: [source])
            let marker = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO track (source_id, start_marker_id) VALUES (?, ?)",
                arguments: [source, marker]
            )
            try addSegment(db, source: source, text: "accordion recital")
            try db.execute(
                sql: "INSERT INTO job (source_id, type, created_at) VALUES (?, 'transcribe', '2026-11-02')",
                arguments: [source]
            )
            try db.execute(sql: "DELETE FROM tape")
        }

        for table in ["source", "marker", "track", "segment", "job"] {
            let count = try database.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")
            }
            #expect(count == 0, "\(table) not emptied")
        }
        #expect(try matches("accordion").isEmpty)
    }

    /// Stale index entries used to raise SQLITE_CORRUPT_VTAB from snippet() after
    /// a recording was re-transcribed.
    @Test func searchSurvivesEditsAndDeletes() throws {
        try database.writer.write { db in
            let source = try addSource(db)
            try addSegment(db, source: source, text: "Carl was in a bad wreck")
            try addSegment(db, source: source, text: "tornadoes in Tulsa")
        }
        #expect(try matches("wreck") == ["Carl was in a bad [wreck]"])

        try database.writer.write { db in
            try db.execute(sql: "UPDATE segment SET text = 'Carl was in a bad accident' WHERE text LIKE 'Carl%'")
        }
        #expect(try matches("wreck").isEmpty)
        #expect(try matches("accident") == ["Carl was in a bad [accident]"])

        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM segment WHERE text LIKE 'tornadoes%'")
        }
        #expect(try matches("tulsa").isEmpty)

        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO segment_fts(segment_fts, rank) VALUES('integrity-check', 1)")
        }
    }

    @Test func searchMatchesWordForms() throws {
        try database.writer.write { db in
            try addSegment(db, source: try addSource(db), text: "the tornadoes came through")
        }
        #expect(try matches("tornado").count == 1)
    }

    @Test func aJobBelongsToExactlyOneSubject() throws {
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO job (type, created_at) VALUES ('prep', '2026-11-02')")
            }
        }
    }

    @Test func aSourceHasOnlyOneOpeningTrack() throws {
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                let source = try addSource(db)
                try db.execute(sql: "INSERT INTO track (source_id) VALUES (?)", arguments: [source])
                try db.execute(sql: "INSERT INTO track (source_id) VALUES (?)", arguments: [source])
            }
        }
    }

    @Test func reopeningKeepsData() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "remanence-tests-\(UUID().uuidString)/library.sqlite")
        try AppDatabase.open(at: path).writer.write { db in
            try db.execute(sql: "INSERT INTO tape (uuid, title, created_at) VALUES ('u', 'Kept', '2026-11-02')")
        }
        let reopened = try AppDatabase.open(at: path)
        let title = try reopened.writer.read { db in try String.fetchOne(db, sql: "SELECT title FROM tape") }
        #expect(title == "Kept")
    }
}
