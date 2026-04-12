package store

import (
	"fmt"

	"github.com/colton/audio-archive/internal/model"
)

// CreateRecording inserts a new recording and returns its ID.
func (db *DB) CreateRecording(rec *model.Recording) (int64, error) {
	result, err := db.conn.Exec(`
		INSERT INTO recordings (slug, date, speaker, title, series, master_path, duration_ms, sample_rate, channels, format)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		rec.Slug, rec.Date, rec.Speaker, rec.Title, rec.Series,
		rec.MasterPath, rec.DurationMs, rec.SampleRate, rec.Channels, "",
	)
	if err != nil {
		return 0, fmt.Errorf("inserting recording: %w", err)
	}
	return result.LastInsertId()
}

// GetRecording retrieves a recording by ID.
func (db *DB) GetRecording(id int64) (*model.Recording, error) {
	row := db.conn.QueryRow(`
		SELECT id, slug, COALESCE(date, ''), COALESCE(speaker, ''),
		       COALESCE(title, ''), COALESCE(series, ''),
		       master_path, COALESCE(prep_path, ''),
		       COALESCE(duration_ms, 0), COALESCE(sample_rate, 0), COALESCE(channels, 0)
		FROM recordings WHERE id = ?`, id)

	rec := &model.Recording{}
	err := row.Scan(
		&rec.ID, &rec.Slug, &rec.Date, &rec.Speaker, &rec.Title, &rec.Series,
		&rec.MasterPath, &rec.PrepPath, &rec.DurationMs, &rec.SampleRate, &rec.Channels,
	)
	if err != nil {
		return nil, fmt.Errorf("getting recording: %w", err)
	}
	return rec, nil
}

// ListRecordings returns all recordings, newest first.
func (db *DB) ListRecordings() ([]model.Recording, error) {
	rows, err := db.conn.Query(`
		SELECT id, slug, COALESCE(date, ''), COALESCE(speaker, ''),
		       COALESCE(title, ''), master_path, COALESCE(duration_ms, 0)
		FROM recordings ORDER BY date DESC, id DESC`)
	if err != nil {
		return nil, fmt.Errorf("listing recordings: %w", err)
	}
	defer rows.Close()

	var recs []model.Recording
	for rows.Next() {
		var rec model.Recording
		if err := rows.Scan(&rec.ID, &rec.Slug, &rec.Date, &rec.Speaker, &rec.Title, &rec.MasterPath, &rec.DurationMs); err != nil {
			return nil, fmt.Errorf("scanning recording: %w", err)
		}
		recs = append(recs, rec)
	}
	return recs, rows.Err()
}

// UpdatePrepPath sets the processed audio path for a recording.
func (db *DB) UpdatePrepPath(id int64, prepPath string) error {
	_, err := db.conn.Exec(`UPDATE recordings SET prep_path = ?, updated_at = datetime('now') WHERE id = ?`, prepPath, id)
	return err
}

// UpdateRecordingMetadata backfills title, speaker, and date on a recording
// row, but only for fields that are currently empty. This preserves any
// values the user explicitly provided via --speaker, --date, or --title at
// ingest time while enriching the rest from the summarization output.
//
// Called by the pipeline after a successful summarize so that `archive list`
// shows meaningful metadata instead of empty columns.
func (db *DB) UpdateRecordingMetadata(id int64, title, speaker, date string) error {
	_, err := db.conn.Exec(`
		UPDATE recordings
		SET title   = CASE WHEN COALESCE(title, '')   = '' THEN ? ELSE title   END,
		    speaker = CASE WHEN COALESCE(speaker, '') = '' THEN ? ELSE speaker END,
		    date    = CASE WHEN COALESCE(date, '')    = '' THEN ? ELSE date    END,
		    updated_at = datetime('now')
		WHERE id = ?`,
		title, speaker, date, id)
	return err
}

// GetRecordingIDByMasterPath looks up a recording ID by its relative master path.
// Returns sql.ErrNoRows if not found.
func (db *DB) GetRecordingIDByMasterPath(masterPath string) (int64, error) {
	var id int64
	err := db.conn.QueryRow(`SELECT id FROM recordings WHERE master_path = ?`, masterPath).Scan(&id)
	return id, err
}
