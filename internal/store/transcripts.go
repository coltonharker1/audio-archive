package store

import (
	"encoding/json"
	"fmt"

	"github.com/colton/audio-archive/internal/transcribe"
)

// Transcript represents a stored transcript record.
type Transcript struct {
	ID          int64
	RecordingID int64
	FullText    string
	Segments    []transcribe.Segment
	Language    string
	ModelUsed   string
}

// SaveTranscript stores a transcription result in the database.
func (db *DB) SaveTranscript(recordingID int64, result *transcribe.Result, modelUsed string) (int64, error) {
	segJSON, err := json.Marshal(result.Segments)
	if err != nil {
		return 0, fmt.Errorf("marshaling segments: %w", err)
	}

	res, err := db.conn.Exec(`
		INSERT INTO transcripts (recording_id, full_text, segments, language, model_used)
		VALUES (?, ?, ?, ?, ?)`,
		recordingID, result.FullText, string(segJSON), result.Language, modelUsed,
	)
	if err != nil {
		return 0, fmt.Errorf("inserting transcript: %w", err)
	}
	return res.LastInsertId()
}

// GetTranscript retrieves a transcript by recording ID.
func (db *DB) GetTranscript(recordingID int64) (*Transcript, error) {
	row := db.conn.QueryRow(`
		SELECT id, recording_id, full_text, segments, language, model_used
		FROM transcripts WHERE recording_id = ?`, recordingID)

	t := &Transcript{}
	var segJSON string
	err := row.Scan(&t.ID, &t.RecordingID, &t.FullText, &segJSON, &t.Language, &t.ModelUsed)
	if err != nil {
		return nil, fmt.Errorf("getting transcript: %w", err)
	}

	if err := json.Unmarshal([]byte(segJSON), &t.Segments); err != nil {
		return nil, fmt.Errorf("parsing segments: %w", err)
	}

	return t, nil
}

// SearchTranscripts performs full-text search across all transcripts.
func (db *DB) SearchTranscripts(query string) ([]SearchResult, error) {
	rows, err := db.conn.Query(`
		SELECT t.recording_id, r.slug, r.date, r.speaker, r.title,
		       snippet(transcripts_fts, 0, '>>>', '<<<', '...', 32) as snippet
		FROM transcripts_fts
		JOIN transcripts t ON t.id = transcripts_fts.rowid
		JOIN recordings r ON r.id = t.recording_id
		WHERE transcripts_fts MATCH ?
		ORDER BY rank`, query)
	if err != nil {
		return nil, fmt.Errorf("searching transcripts: %w", err)
	}
	defer rows.Close()

	var results []SearchResult
	for rows.Next() {
		var sr SearchResult
		if err := rows.Scan(&sr.RecordingID, &sr.Slug, &sr.Date, &sr.Speaker, &sr.Title, &sr.Snippet); err != nil {
			return nil, fmt.Errorf("scanning search result: %w", err)
		}
		results = append(results, sr)
	}
	return results, rows.Err()
}

// SearchResult holds a single full-text search hit.
type SearchResult struct {
	RecordingID int64
	Slug        string
	Date        string
	Speaker     string
	Title       string
	Snippet     string
}
