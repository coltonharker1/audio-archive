package store

import (
	"database/sql"
	"encoding/json"
	"fmt"

	"github.com/colton/audio-archive/internal/summarize"
)

// SaveSummary stores a recording summary as a JSON blob.
// The recording_type and summary_short are also denormalized into their
// own columns for efficient filtering/listing.
func (db *DB) SaveSummary(recordingID int64, summary *summarize.RecordingSummary, modelUsed string) (int64, error) {
	metadataJSON, err := json.Marshal(summary)
	if err != nil {
		return 0, fmt.Errorf("marshaling summary: %w", err)
	}

	// Delete any previous summary for this recording so we don't pile up
	// duplicates when re-running `archive summarize`.
	if _, err := db.conn.Exec(`DELETE FROM summaries WHERE recording_id = ?`, recordingID); err != nil {
		return 0, fmt.Errorf("clearing previous summary: %w", err)
	}

	res, err := db.conn.Exec(`
		INSERT INTO summaries (recording_id, recording_type, summary_short, metadata, model_used)
		VALUES (?, ?, ?, ?, ?)`,
		recordingID,
		string(summary.RecordingType),
		summary.SummaryShort,
		string(metadataJSON),
		modelUsed,
	)
	if err != nil {
		return 0, fmt.Errorf("inserting summary: %w", err)
	}
	return res.LastInsertId()
}

// GetSummary retrieves a summary by recording ID.
// Returns sql.ErrNoRows if no summary exists.
func (db *DB) GetSummary(recordingID int64) (*summarize.RecordingSummary, error) {
	var metadataJSON string
	err := db.conn.QueryRow(`
		SELECT metadata FROM summaries WHERE recording_id = ? ORDER BY id DESC LIMIT 1`,
		recordingID,
	).Scan(&metadataJSON)

	if err == sql.ErrNoRows {
		return nil, err
	}
	if err != nil {
		return nil, fmt.Errorf("getting summary: %w", err)
	}

	var summary summarize.RecordingSummary
	if err := json.Unmarshal([]byte(metadataJSON), &summary); err != nil {
		return nil, fmt.Errorf("parsing stored summary: %w", err)
	}
	return &summary, nil
}
