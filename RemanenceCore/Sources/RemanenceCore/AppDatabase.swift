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

        migrator.registerMigration("v2-tape-details") { db in
            try db.alter(table: "tape") { t in
                t.add(column: "era", .text)
                t.add(column: "description", .text)
            }
        }

        migrator.registerMigration("v3-pipeline") { db in
            try db.alter(table: "job") { t in
                t.add(column: "next_attempt_at", .datetime)
                t.add(column: "pid", .integer)
            }
            try db.alter(table: "source") { t in
                t.add(column: "transcript_model", .text)
            }
            try db.alter(table: "tape") { t in
                t.add(column: "title_is_provisional", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v4-candidates") { db in
            try db.alter(table: "job") { t in
                t.add(column: "candidate", .boolean).notNull().defaults(to: false)
            }
            // A second transcript waiting to be compared. It stays apart from the
            // real one, so nothing changes until a choice is made.
            try db.create(table: "transcript_candidate") { t in
                t.primaryKey("source_id", .integer).references("source", onDelete: .cascade)
                t.column("model", .text).notNull()
                t.column("segments", .jsonText).notNull()
            }
        }

        migrator.registerMigration("v5-machines") { db in
            try db.alter(table: "machine") { t in
                t.add(column: "device_uid", .text)
                t.add(column: "channel_mode", .text)
            }
            let machines: [(String, String, String)] = [
                ("7\" Reel", "7\" Reel-to-Reel", #"["7½ ips","3¾ ips","1⅞ ips"]"#),
                ("5\" Reel", "5\" Reel-to-Reel", #"["3¾ ips","1⅞ ips","7½ ips"]"#),
                ("Cassette", "Cassette", #"["1⅞ ips"]"#),
                ("Microcassette", "Microcassette", #"["2.4 cm/s","1.2 cm/s"]"#),
            ]
            for (name, medium, speeds) in machines {
                try db.execute(
                    sql: "INSERT INTO machine (name, medium, speeds) VALUES (?, ?, ?)",
                    arguments: [name, medium, speeds]
                )
            }
        }


        migrator.registerMigration("v6-site-post") { db in
            // Everything a post on the site has, so it can all be written here.
            try db.alter(table: "tape") { t in
                t.add(column: "where_found", .text)
                t.add(column: "date_found", .text)
            }
            // Written by hand. The AI summary stays separate, as reference.
            try db.alter(table: "track") { t in
                t.add(column: "description", .text)
            }
            try db.create(table: "tape_image") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tape_id", .integer).notNull().indexed().references("tape", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("path", .text).notNull()
                t.column("sha256", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("caption", .text)
                t.uniqueKey(["tape_id", "sha256"])
            }
        }

        migrator.registerMigration("v7-site-sync") { db in
            // What the site had when the app last read or wrote the post. Updates are
            // worked out against it, and refused by the site if it has moved on since.
            try db.alter(table: "tape") { t in
                t.add(column: "site_updated_at", .text)
                t.add(column: "site_snapshot", .jsonText)
            }
            try db.alter(table: "tape_image") { t in
                t.add(column: "site_url", .text)
            }
        }

        return migrator
    }
}
