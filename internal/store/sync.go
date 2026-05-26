package store

import (
	"fmt"

	"github.com/colton/audio-archive/internal/model"
)

// MarkSynced records that a recording was synced to remanence with the given
// catalog number (e.g. "RA-042").
func (db *DB) MarkSynced(id int64, catalogNumber string) error {
	_, err := db.conn.Exec(`
		UPDATE recordings
		SET synced_at = datetime('now'),
		    remanence_catalog_number = ?,
		    updated_at = datetime('now')
		WHERE id = ?`, catalogNumber, id)
	return err
}

// SyncableRecordings returns recordings that have a completed summary but
// haven't been synced yet (synced_at IS NULL).
func (db *DB) SyncableRecordings() ([]model.Recording, error) {
	rows, err := db.conn.Query(`
		SELECT r.id, r.slug, COALESCE(r.date, ''), COALESCE(r.speaker, ''),
		       COALESCE(r.title, ''), r.master_path, COALESCE(r.duration_ms, 0)
		FROM recordings r
		JOIN summaries s ON s.recording_id = r.id
		WHERE r.synced_at IS NULL
		ORDER BY r.id`)
	if err != nil {
		return nil, fmt.Errorf("listing syncable recordings: %w", err)
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

// GetRemanenceCatalogNumber returns the catalog number for a previously synced
// recording, or empty string if not synced.
func (db *DB) GetRemanenceCatalogNumber(id int64) (string, error) {
	var catNum *string
	err := db.conn.QueryRow(`SELECT remanence_catalog_number FROM recordings WHERE id = ?`, id).Scan(&catNum)
	if err != nil {
		return "", err
	}
	if catNum == nil {
		return "", nil
	}
	return *catNum, nil
}
