import Foundation
import GRDB

/// The library database. All schema changes go through versioned migrations.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens or creates the database on disk.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(writer: DatabasePool(path: url.path))
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "machine") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("medium", .text).notNull()
                t.column("speeds", .jsonText).notNull().defaults(to: "[]")
                t.column("input_name", .text)
                t.column("knob_note", .text)
            }

            try db.create(table: "tape") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("catalog_number", .text).unique()
                t.column("title", .text).notNull()
                t.column("medium", .text)
                t.column("machine_id", .integer).indexed().references("machine", onDelete: .setNull)
                t.column("speed", .text)
                t.column("context", .text)
                t.column("approved_at", .datetime)
                t.column("pushed_at", .datetime)
                t.column("created_at", .datetime).notNull()
            }

            // One continuous recording. A file's hash is its identity, so the
            // same audio can't be imported twice. It stays empty during capture.
            try db.create(table: "source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tape_id", .integer).notNull().indexed().references("tape", onDelete: .cascade)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("side", .text)
                t.column("master_path", .text).notNull()
                t.column("sha256", .text).unique()
                t.column("prep_path", .text)
                t.column("peaks_path", .text)
                t.column("duration", .double).notNull()
                t.column("sample_rate", .integer)
                t.column("channels", .integer)
                t.column("bit_depth", .integer)
                t.column("trim_start", .double).notNull().defaults(to: 0)
                t.column("trim_end", .double)
            }

            try db.create(table: "marker") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_id", .integer).notNull().indexed().references("source", onDelete: .cascade)
                t.column("time", .double).notNull().check { $0 >= 0 }
                t.column("origin", .text).notNull().defaults(to: "manual")
            }

            // A track runs from its marker to the next one. No marker means it
            // starts at the beginning of the source.
            try db.create(table: "track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_id", .integer).notNull().indexed().references("source", onDelete: .cascade)
                t.column("start_marker_id", .integer)
                    .references("marker", onDelete: .cascade)
                t.column("name", .text)
                t.column("recording_type", .text)
                t.column("summary_short", .text)
                t.column("summary", .jsonText)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX track_on_marker ON track(start_marker_id)
                    WHERE start_marker_id IS NOT NULL;
                CREATE UNIQUE INDEX track_on_source_start ON track(source_id)
                    WHERE start_marker_id IS NULL;
                """)

            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_id", .integer).notNull().indexed().references("source", onDelete: .cascade)
                t.column("start_time", .double).notNull()
                t.column("end_time", .double).notNull()
                t.column("text", .text).notNull()
                t.column("edited", .boolean).notNull().defaults(to: false)
            }

            // Synchronizing installs insert, update and delete triggers. Without
            // all three, re-transcribing corrupts the index that snippet() reads.
            try db.create(virtualTable: "segment_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }

            try db.create(table: "job") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_id", .integer).indexed().references("source", onDelete: .cascade)
                t.column("track_id", .integer).indexed().references("track", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending").indexed()
                t.column("attempt", .integer).notNull().defaults(to: 0)
                t.column("max_attempts", .integer).notNull().defaults(to: 3)
                t.column("model", .text)
                t.column("error", .text)
                t.column("created_at", .datetime).notNull()
                t.column("started_at", .datetime)
                t.column("finished_at", .datetime)
                t.check(sql: "(source_id IS NULL) != (track_id IS NULL)")
            }
        }

        return migrator
    }
}
