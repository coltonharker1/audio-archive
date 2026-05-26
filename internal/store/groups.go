package store

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"

	"github.com/colton/audio-archive/internal/model"
)

// NewGroupID generates a random group identifier.
func NewGroupID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// SetGroup assigns a group_id and group_title to a recording.
func (db *DB) SetGroup(recordingID int64, groupID, groupTitle string) error {
	_, err := db.conn.Exec(`
		UPDATE recordings
		SET group_id = ?, group_title = ?, updated_at = datetime('now')
		WHERE id = ?`, groupID, groupTitle, recordingID)
	return err
}

// GetGroupRecordings returns all recordings that share the given group_id,
// ordered by slug (which gives a natural filename sort).
func (db *DB) GetGroupRecordings(groupID string) ([]model.Recording, error) {
	rows, err := db.conn.Query(`
		SELECT id, slug, COALESCE(date, ''), COALESCE(speaker, ''),
		       COALESCE(title, ''), master_path, COALESCE(prep_path, ''),
		       COALESCE(duration_ms, 0)
		FROM recordings
		WHERE group_id = ?
		ORDER BY slug, id`, groupID)
	if err != nil {
		return nil, fmt.Errorf("listing group recordings: %w", err)
	}
	defer rows.Close()

	var recs []model.Recording
	for rows.Next() {
		var rec model.Recording
		if err := rows.Scan(&rec.ID, &rec.Slug, &rec.Date, &rec.Speaker, &rec.Title, &rec.MasterPath, &rec.PrepPath, &rec.DurationMs); err != nil {
			return nil, fmt.Errorf("scanning recording: %w", err)
		}
		recs = append(recs, rec)
	}
	return recs, rows.Err()
}

// GetRecordingGroup returns the group_id and group_title for a recording.
// Returns empty strings if the recording is ungrouped.
func (db *DB) GetRecordingGroup(recordingID int64) (groupID, groupTitle string, err error) {
	var gid, gtitle *string
	err = db.conn.QueryRow(`
		SELECT group_id, group_title FROM recordings WHERE id = ?`,
		recordingID).Scan(&gid, &gtitle)
	if err != nil {
		return "", "", err
	}
	if gid != nil {
		groupID = *gid
	}
	if gtitle != nil {
		groupTitle = *gtitle
	}
	return
}

// IsGroupFullySummarized returns true if every recording in the group has
// a completed summary. Returns false if any member is missing a summary.
func (db *DB) IsGroupFullySummarized(groupID string) (bool, error) {
	var total, summarized int
	err := db.conn.QueryRow(`
		SELECT
			COUNT(*) as total,
			COUNT(s.id) as summarized
		FROM recordings r
		LEFT JOIN summaries s ON s.recording_id = r.id
		WHERE r.group_id = ?`, groupID).Scan(&total, &summarized)
	if err != nil {
		return false, err
	}
	return total > 0 && total == summarized, nil
}

// SyncableGroups returns group_ids that have at least one recording with a
// completed summary and where no recording in the group has been synced yet.
// This lets --pending sync groups as a unit.
func (db *DB) SyncableGroups() ([]string, error) {
	rows, err := db.conn.Query(`
		SELECT DISTINCT r.group_id
		FROM recordings r
		JOIN summaries s ON s.recording_id = r.id
		WHERE r.group_id IS NOT NULL
		  AND r.synced_at IS NULL
		GROUP BY r.group_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var groups []string
	for rows.Next() {
		var gid string
		if err := rows.Scan(&gid); err != nil {
			return nil, err
		}
		groups = append(groups, gid)
	}
	return groups, rows.Err()
}
