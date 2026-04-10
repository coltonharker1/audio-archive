package store

import (
	"encoding/json"
	"fmt"

	"github.com/colton/audio-archive/internal/summarize"
)

// SaveSummary stores a sermon summary in the database.
func (db *DB) SaveSummary(recordingID int64, summary *summarize.SermonSummary, modelUsed string) (int64, error) {
	topicsJSON, _ := json.Marshal(summary.MainTopics)
	themesJSON, _ := json.Marshal(summary.NotableThemes)
	refsJSON, _ := json.Marshal(summary.BibleReferences)
	histJSON, _ := json.Marshal(summary.HistoricalRefs)
	quotesJSON, _ := json.Marshal(summary.NotableQuotes)
	tagsJSON, _ := json.Marshal(summary.Tags)

	res, err := db.conn.Exec(`
		INSERT INTO summaries (recording_id, summary_short, summary_long,
			main_topics, notable_themes, bible_references, historical_references,
			notable_quotes, tags, suggested_title, suggested_speaker, estimated_era, model_used)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		recordingID, summary.SummaryShort, summary.SummaryLong,
		string(topicsJSON), string(themesJSON), string(refsJSON), string(histJSON),
		string(quotesJSON), string(tagsJSON), summary.SuggestedTitle,
		summary.SuggestedSpeaker, summary.EstimatedEra, modelUsed,
	)
	if err != nil {
		return 0, fmt.Errorf("inserting summary: %w", err)
	}
	return res.LastInsertId()
}

// GetSummary retrieves a summary by recording ID.
func (db *DB) GetSummary(recordingID int64) (*summarize.SermonSummary, error) {
	row := db.conn.QueryRow(`
		SELECT summary_short, summary_long, main_topics, notable_themes,
		       bible_references, historical_references, notable_quotes, tags,
		       suggested_title, suggested_speaker, estimated_era
		FROM summaries WHERE recording_id = ?`, recordingID)

	s := &summarize.SermonSummary{}
	var topicsJSON, themesJSON, refsJSON, histJSON, quotesJSON, tagsJSON string

	err := row.Scan(
		&s.SummaryShort, &s.SummaryLong,
		&topicsJSON, &themesJSON, &refsJSON, &histJSON,
		&quotesJSON, &tagsJSON,
		&s.SuggestedTitle, &s.SuggestedSpeaker, &s.EstimatedEra,
	)
	if err != nil {
		return nil, fmt.Errorf("getting summary: %w", err)
	}

	json.Unmarshal([]byte(topicsJSON), &s.MainTopics)
	json.Unmarshal([]byte(themesJSON), &s.NotableThemes)
	json.Unmarshal([]byte(refsJSON), &s.BibleReferences)
	json.Unmarshal([]byte(histJSON), &s.HistoricalRefs)
	json.Unmarshal([]byte(quotesJSON), &s.NotableQuotes)
	json.Unmarshal([]byte(tagsJSON), &s.Tags)

	return s, nil
}
