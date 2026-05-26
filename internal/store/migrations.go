package store

import (
	"database/sql"
	"log/slog"
)

// migrate runs schema migrations. For the MVP we use CREATE TABLE IF NOT
// EXISTS for initial creation and a simple per-version check for schema
// changes that need to drop and recreate tables.
func (db *DB) migrate() error {
	// ---- Base tables ----
	_, err := db.conn.Exec(`
		CREATE TABLE IF NOT EXISTS recordings (
			id          INTEGER PRIMARY KEY,
			slug        TEXT NOT NULL,
			date        TEXT,
			speaker     TEXT,
			title       TEXT,
			series      TEXT,
			master_path TEXT NOT NULL,
			prep_path   TEXT,
			duration_ms INTEGER,
			sample_rate INTEGER,
			channels    INTEGER,
			format      TEXT,
			created_at  TEXT DEFAULT (datetime('now')),
			updated_at  TEXT DEFAULT (datetime('now'))
		);

		CREATE TABLE IF NOT EXISTS jobs (
			id           INTEGER PRIMARY KEY,
			recording_id INTEGER NOT NULL REFERENCES recordings(id),
			type         TEXT NOT NULL,
			status       TEXT NOT NULL DEFAULT 'pending',
			attempt      INTEGER DEFAULT 0,
			max_retries  INTEGER DEFAULT 3,
			error        TEXT,
			created_at   TEXT DEFAULT (datetime('now')),
			started_at   TEXT,
			finished_at  TEXT
		);

		CREATE TABLE IF NOT EXISTS transcripts (
			id           INTEGER PRIMARY KEY,
			recording_id INTEGER NOT NULL REFERENCES recordings(id),
			full_text    TEXT,
			segments     TEXT,
			language     TEXT,
			model_used   TEXT,
			created_at   TEXT DEFAULT (datetime('now'))
		);

		CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
			full_text,
			content='transcripts',
			content_rowid='id'
		);
	`)
	if err != nil {
		return err
	}

	// ---- Sync tracking columns ----
	db.conn.Exec(`ALTER TABLE recordings ADD COLUMN synced_at TEXT`)
	db.conn.Exec(`ALTER TABLE recordings ADD COLUMN remanence_catalog_number TEXT`)

	// ---- Source path and context columns ----
	db.conn.Exec(`ALTER TABLE recordings ADD COLUMN source_path TEXT`)
	db.conn.Exec(`ALTER TABLE recordings ADD COLUMN context TEXT`)

	// ---- Grouping columns ----
	// Recordings with the same group_id are tracks on the same tape/reel.
	// group_id is a random string assigned at ingest time (folder-based) or
	// via `archive group`. group_title is the display name for the group.
	db.conn.Exec(`ALTER TABLE recordings ADD COLUMN group_id TEXT`)
	db.conn.Exec(`ALTER TABLE recordings ADD COLUMN group_title TEXT`)
	db.conn.Exec(`CREATE INDEX IF NOT EXISTS idx_recordings_group_id ON recordings(group_id)`)

	// ---- Per-job model override (transcribe) ----
	// NULL means use config default. Set when the user requests a specific
	// whisper model from the web UI (e.g. "transcribe this one with medium").
	db.conn.Exec(`ALTER TABLE jobs ADD COLUMN model TEXT`)

	// ---- Approval tracking ----
	// approved_at is set by the reviewer in the web UI before sync. Sync
	// commands can use this as a gate to require human review.
	db.conn.Exec(`ALTER TABLE recordings ADD COLUMN approved_at TEXT`)

	// ---- Summaries table: schema v2 migration ----
	// v1 had sermon-specific columns (summary_short, summary_long, main_topics,
	//      bible_references, etc.).
	// v2 uses a universal schema: (recording_type, summary_short, metadata JSON).
	//
	// Detection: v2 has a `metadata` column. If the summaries table exists
	// without it, it's v1 and needs to be dropped and recreated.
	if err := db.migrateSummariesV2(); err != nil {
		return err
	}

	// FTS sync triggers — CREATE TRIGGER IF NOT EXISTS isn't supported,
	// so we drop and recreate. AFTER UPDATE/DELETE triggers keep the FTS
	// index in sync when transcripts are re-processed (otherwise snippet()
	// raises SQLITE_CORRUPT_VTAB on stale docsize entries).
	db.conn.Exec("DROP TRIGGER IF EXISTS transcripts_ai")
	db.conn.Exec("DROP TRIGGER IF EXISTS transcripts_au")
	db.conn.Exec("DROP TRIGGER IF EXISTS transcripts_ad")
	if _, err := db.conn.Exec(`
		CREATE TRIGGER transcripts_ai AFTER INSERT ON transcripts BEGIN
			INSERT INTO transcripts_fts(rowid, full_text) VALUES (new.id, new.full_text);
		END;
		CREATE TRIGGER transcripts_au AFTER UPDATE ON transcripts BEGIN
			INSERT INTO transcripts_fts(transcripts_fts, rowid, full_text)
				VALUES('delete', old.id, old.full_text);
			INSERT INTO transcripts_fts(rowid, full_text) VALUES (new.id, new.full_text);
		END;
		CREATE TRIGGER transcripts_ad AFTER DELETE ON transcripts BEGIN
			INSERT INTO transcripts_fts(transcripts_fts, rowid, full_text)
				VALUES('delete', old.id, old.full_text);
		END;
	`); err != nil {
		return err
	}
	return nil
}

// migrateSummariesV2 ensures the summaries table is in v2 format (universal
// recording summary with a metadata JSON blob). If it detects v1 schema
// (sermon-specific columns), it drops the table so the CREATE TABLE below
// can recreate it in v2 format.
//
// Existing summary rows are lost on this migration — the user will need to
// rerun `archive summarize` to regenerate them with the new structure.
// This is a one-time cost and only affects the summaries table (transcripts,
// recordings, jobs are preserved).
func (db *DB) migrateSummariesV2() error {
	hasTable, hasMetadata, err := inspectSummariesColumns(db.conn)
	if err != nil {
		return err
	}

	if hasTable && !hasMetadata {
		slog.Warn("migrating summaries table from v1 (sermon-specific) to v2 (universal). " +
			"Existing summary rows will be lost — re-run 'archive summarize' to regenerate.")
		if _, err := db.conn.Exec(`DROP TABLE summaries`); err != nil {
			return err
		}
	}

	// Create v2 table if it doesn't exist (or was just dropped)
	_, err = db.conn.Exec(`
		CREATE TABLE IF NOT EXISTS summaries (
			id             INTEGER PRIMARY KEY,
			recording_id   INTEGER NOT NULL REFERENCES recordings(id),
			recording_type TEXT,
			summary_short  TEXT,
			metadata       TEXT NOT NULL,
			model_used     TEXT,
			created_at     TEXT DEFAULT (datetime('now'))
		);
		CREATE INDEX IF NOT EXISTS idx_summaries_recording_id ON summaries(recording_id);
		CREATE INDEX IF NOT EXISTS idx_summaries_recording_type ON summaries(recording_type);
	`)
	return err
}

// inspectSummariesColumns checks if the summaries table exists and whether
// it has the v2 `metadata` column.
func inspectSummariesColumns(conn *sql.DB) (hasTable, hasMetadata bool, err error) {
	rows, err := conn.Query(`PRAGMA table_info('summaries')`)
	if err != nil {
		return false, false, err
	}
	defer rows.Close()

	for rows.Next() {
		hasTable = true
		var (
			cid        int
			name       string
			ttype      string
			notnull    int
			dfltValue  sql.NullString
			pk         int
		)
		if err := rows.Scan(&cid, &name, &ttype, &notnull, &dfltValue, &pk); err != nil {
			return false, false, err
		}
		if name == "metadata" {
			hasMetadata = true
		}
	}
	return hasTable, hasMetadata, rows.Err()
}
