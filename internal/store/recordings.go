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
		SELECT id, slug, date, speaker, title, series, master_path, prep_path,
		       duration_ms, sample_rate, channels
		FROM recordings WHERE id = ?`, id)

	rec := &model.Recording{}
	var prepPath *string
	err := row.Scan(
		&rec.ID, &rec.Slug, &rec.Date, &rec.Speaker, &rec.Title, &rec.Series,
		&rec.MasterPath, &prepPath, &rec.DurationMs, &rec.SampleRate, &rec.Channels,
	)
	if err != nil {
		return nil, fmt.Errorf("getting recording: %w", err)
	}
	if prepPath != nil {
		rec.PrepPath = *prepPath
	}
	return rec, nil
}

// ListRecordings returns all recordings, newest first.
func (db *DB) ListRecordings() ([]model.Recording, error) {
	rows, err := db.conn.Query(`
		SELECT id, slug, date, speaker, title, master_path, duration_ms
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
