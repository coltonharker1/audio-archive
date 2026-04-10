package store

// migrate runs schema migrations. For the MVP we use a simple version check
// rather than a full migration framework — keeps dependencies light.
func (db *DB) migrate() error {
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

		CREATE TABLE IF NOT EXISTS summaries (
			id                   INTEGER PRIMARY KEY,
			recording_id         INTEGER NOT NULL REFERENCES recordings(id),
			summary_short        TEXT,
			summary_long         TEXT,
			main_topics          TEXT,
			notable_themes       TEXT,
			bible_references     TEXT,
			historical_references TEXT,
			notable_quotes       TEXT,
			tags                 TEXT,
			suggested_title      TEXT,
			suggested_speaker    TEXT,
			estimated_era        TEXT,
			model_used           TEXT,
			created_at           TEXT DEFAULT (datetime('now'))
		);
	`)
	if err != nil {
		return err
	}

	// FTS sync trigger — CREATE TRIGGER IF NOT EXISTS isn't supported,
	// so we drop and recreate.
	db.conn.Exec("DROP TRIGGER IF EXISTS transcripts_ai")
	_, err = db.conn.Exec(`
		CREATE TRIGGER transcripts_ai AFTER INSERT ON transcripts BEGIN
			INSERT INTO transcripts_fts(rowid, full_text) VALUES (new.id, new.full_text);
		END;
	`)
	return err
}
