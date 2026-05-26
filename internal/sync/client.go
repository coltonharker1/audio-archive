package sync

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/model"
	"github.com/colton/audio-archive/internal/store"
	"github.com/colton/audio-archive/internal/summarize"
)

// Client talks to the remanence-archive sync API.
type Client struct {
	baseURL string
	apiKey  string
	http    *http.Client
	cfg     config.Config
}

// NewClient creates a sync client for the given remanence base URL and API key.
func NewClient(baseURL, apiKey string, cfg config.Config) *Client {
	return &Client{
		baseURL: baseURL,
		apiKey:  apiKey,
		http:    &http.Client{Timeout: 5 * time.Minute},
		cfg:     cfg,
	}
}

// SyncResult holds the outcome of syncing a single recording.
type SyncResult struct {
	CatalogNumber string
	Created       bool // true if new, false if updated
}

// NextCatalogNumber reserves the next catalog number from remanence.
func (c *Client) NextCatalogNumber() (string, error) {
	resp, err := c.doRequest("GET", "/api/sync", nil)
	if err != nil {
		return "", fmt.Errorf("getting next catalog number: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status %d getting catalog number", resp.StatusCode)
	}

	var result struct {
		CatalogNumber string `json:"catalogNumber"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	return result.CatalogNumber, nil
}

// uploadFileRequest is one entry in the batch presigned URL request.
type uploadFileRequest struct {
	Filename    string `json:"filename"`
	ContentType string `json:"contentType"`
	Type        string `json:"type"` // "audio" or "transcript"
}

// uploadFileResult is one entry in the presigned URL response.
type uploadFileResult struct {
	Filename  string `json:"filename"`
	Type      string `json:"type"`
	UploadURL string `json:"uploadUrl"`
	Key       string `json:"key"`
}

// GetPresignedURLs requests presigned upload URLs for a set of files.
func (c *Client) GetPresignedURLs(catalogNumber string, files []uploadFileRequest) ([]uploadFileResult, error) {
	body := map[string]any{
		"catalogNumber": catalogNumber,
		"files":         files,
	}

	resp, err := c.doRequest("POST", "/api/sync/upload", body)
	if err != nil {
		return nil, fmt.Errorf("getting presigned URLs: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("presigned URL request failed (%d): %s", resp.StatusCode, msg)
	}

	var result struct {
		Files []uploadFileResult `json:"files"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result.Files, nil
}

// UploadToR2 uploads a file directly to R2 via a presigned PUT URL.
func (c *Client) UploadToR2(presignedURL, contentType, filePath string) error {
	f, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("opening file %s: %w", filePath, err)
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return err
	}

	req, err := http.NewRequest("PUT", presignedURL, f)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", contentType)
	req.ContentLength = stat.Size()

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("uploading to R2: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("R2 upload failed (%d): %s", resp.StatusCode, msg)
	}
	return nil
}

// CreateSound posts the sound record to remanence.
func (c *Client) CreateSound(payload map[string]any) (*SyncResult, error) {
	resp, err := c.doRequest("POST", "/api/sync", payload)
	if err != nil {
		return nil, fmt.Errorf("creating sound: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		msg, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("create sound failed (%d): %s", resp.StatusCode, msg)
	}

	var sound struct {
		CatalogNumber string `json:"catalogNumber"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&sound); err != nil {
		return nil, err
	}

	return &SyncResult{
		CatalogNumber: sound.CatalogNumber,
		Created:       resp.StatusCode == http.StatusCreated,
	}, nil
}

// SyncRecording syncs a single recording to remanence. It handles:
// 1. Getting or reusing a catalog number
// 2. Uploading master audio, prepped audio, and transcript to R2
// 3. Creating/updating the sound record with full metadata
func (c *Client) SyncRecording(
	rec *model.Recording,
	transcript *store.Transcript,
	summary *summarize.RecordingSummary,
	existingCatalogNum string,
) (*SyncResult, error) {
	// Determine catalog number
	catalogNumber := existingCatalogNum
	if catalogNumber == "" {
		var err error
		catalogNumber, err = c.NextCatalogNumber()
		if err != nil {
			return nil, err
		}
	}

	// Build list of files to upload
	var filesToUpload []uploadFileRequest
	masterPath := filepath.Join(c.cfg.DataDir, rec.MasterPath)
	if _, err := os.Stat(masterPath); err == nil {
		filesToUpload = append(filesToUpload, uploadFileRequest{
			Filename:    filepath.Base(masterPath),
			ContentType: "audio/wav",
			Type:        "audio",
		})
	}

	prepPath := filepath.Join(c.cfg.DataDir, rec.PrepPath)
	if rec.PrepPath != "" {
		if _, err := os.Stat(prepPath); err == nil {
			filesToUpload = append(filesToUpload, uploadFileRequest{
				Filename:    filepath.Base(prepPath),
				ContentType: "audio/wav",
				Type:        "audio",
			})
		}
	}

	// Transcript as a .txt file — we'll write it to a temp file for upload
	var transcriptTmpPath string
	if transcript != nil && transcript.FullText != "" {
		tmpFile, err := os.CreateTemp("", "transcript-*.txt")
		if err != nil {
			return nil, fmt.Errorf("creating temp transcript file: %w", err)
		}
		defer os.Remove(tmpFile.Name())
		if _, err := tmpFile.WriteString(transcript.FullText); err != nil {
			tmpFile.Close()
			return nil, err
		}
		tmpFile.Close()
		transcriptTmpPath = tmpFile.Name()

		filesToUpload = append(filesToUpload, uploadFileRequest{
			Filename:    rec.Slug + "-transcript.txt",
			ContentType: "text/plain",
			Type:        "transcript",
		})
	}

	if len(filesToUpload) == 0 {
		return nil, fmt.Errorf("no files to upload for recording %d", rec.ID)
	}

	// Get presigned URLs
	presigned, err := c.GetPresignedURLs(catalogNumber, filesToUpload)
	if err != nil {
		return nil, err
	}

	// Upload each file to R2
	r2PublicURL := "" // we'll need keys to construct public URLs
	var masterKey, prepKey, transcriptKey string

	for i, p := range presigned {
		var localPath string
		switch filesToUpload[i].Type {
		case "transcript":
			localPath = transcriptTmpPath
		default:
			// First audio = master, second = prep
			if masterKey == "" {
				localPath = masterPath
			} else {
				localPath = prepPath
			}
		}

		fmt.Printf("  uploading %s (%s)...\n", p.Filename, p.Type)
		if err := c.UploadToR2(p.UploadURL, filesToUpload[i].ContentType, localPath); err != nil {
			return nil, fmt.Errorf("uploading %s: %w", p.Filename, err)
		}

		switch p.Type {
		case "audio":
			if masterKey == "" {
				masterKey = p.Key
			} else {
				prepKey = p.Key
			}
		case "transcript":
			transcriptKey = p.Key
		}
	}

	// If we don't know the R2 public URL, extract it from env or use the key pattern
	// The sync endpoint on RA will resolve keys to public URLs
	_ = r2PublicURL

	// Build the sound record payload
	durationSec := int(rec.DurationMs / 1000)
	title := rec.Title
	if title == "" && summary != nil {
		title = summary.SuggestedTitle
	}
	if title == "" {
		title = rec.Slug
	}

	tracks := []map[string]any{
		{
			"title":            title,
			"audioUrl":         prepKey,  // RA will need to resolve these to public URLs
			"audioFilename":    filepath.Base(rec.PrepPath),
			"downloadUrl":      masterKey,
			"downloadFilename": filepath.Base(rec.MasterPath),
			"duration":         durationSec,
		},
	}

	description := ""
	if summary != nil {
		description = summary.SummaryLong
	}

	metadata := map[string]any{
		"source":           "audio-archive",
		"audio_archive_id": rec.ID,
	}
	if summary != nil {
		metadata["summary_short"] = summary.SummaryShort
		metadata["summary_long"] = summary.SummaryLong
		metadata["main_topics"] = summary.MainTopics
		metadata["themes"] = summary.Themes
		metadata["tags"] = summary.Tags
		metadata["people"] = summary.People
		metadata["places"] = summary.Places
		metadata["notable_quotes"] = summary.NotableQuotes
		metadata["speakers"] = summary.Speakers
		metadata["estimated_era"] = summary.EstimatedEra
		metadata["mood"] = summary.Mood
		metadata["recording_type"] = summary.RecordingType
		metadata["type_specific"] = summary.TypeSpecific
		metadata["suggested_title"] = summary.SuggestedTitle
	}
	if transcriptKey != "" {
		metadata["transcript_key"] = transcriptKey
	}

	payload := map[string]any{
		"catalogNumber":          catalogNumber,
		"title":                  title,
		"description":            description,
		"medium":                 "reel-to-reel", // default — admin can fix in RA
		"estimatedRecordingDate": estimatedDate(rec, summary),
		"tracks":                 tracks,
		"metadata":               metadata,
	}

	if rec.Speaker != "" {
		if description != "" {
			payload["description"] = fmt.Sprintf("Speaker: %s\n\n%s", rec.Speaker, description)
		} else {
			payload["description"] = fmt.Sprintf("Speaker: %s", rec.Speaker)
		}
	}

	return c.CreateSound(payload)
}

// GroupMember holds the data for one recording in a group sync.
type GroupMember struct {
	Rec        *model.Recording
	Transcript *store.Transcript
	Summary    *summarize.RecordingSummary
}

// SyncGroup syncs multiple recordings as a single RA sound with multiple tracks.
// The group title is used as the RA sound title. Each recording becomes one track.
func (c *Client) SyncGroup(
	groupTitle string,
	members []GroupMember,
	existingCatalogNum string,
) (*SyncResult, error) {
	if len(members) == 0 {
		return nil, fmt.Errorf("no members in group")
	}

	catalogNumber := existingCatalogNum
	if catalogNumber == "" {
		var err error
		catalogNumber, err = c.NextCatalogNumber()
		if err != nil {
			return nil, err
		}
	}

	// Collect all files to upload across all members
	var filesToUpload []uploadFileRequest
	type fileRef struct {
		memberIdx int
		localPath string
		role      string // "master", "prep", "transcript"
	}
	var fileRefs []fileRef

	for i, m := range members {
		masterPath := filepath.Join(c.cfg.DataDir, m.Rec.MasterPath)
		if _, err := os.Stat(masterPath); err == nil {
			filesToUpload = append(filesToUpload, uploadFileRequest{
				Filename:    filepath.Base(masterPath),
				ContentType: "audio/wav",
				Type:        "audio",
			})
			fileRefs = append(fileRefs, fileRef{i, masterPath, "master"})
		}

		if m.Rec.PrepPath != "" {
			prepPath := filepath.Join(c.cfg.DataDir, m.Rec.PrepPath)
			if _, err := os.Stat(prepPath); err == nil {
				filesToUpload = append(filesToUpload, uploadFileRequest{
					Filename:    filepath.Base(prepPath),
					ContentType: "audio/wav",
					Type:        "audio",
				})
				fileRefs = append(fileRefs, fileRef{i, prepPath, "prep"})
			}
		}

		if m.Transcript != nil && m.Transcript.FullText != "" {
			tmpFile, err := os.CreateTemp("", "transcript-*.txt")
			if err != nil {
				return nil, err
			}
			defer os.Remove(tmpFile.Name())
			tmpFile.WriteString(m.Transcript.FullText)
			tmpFile.Close()

			filesToUpload = append(filesToUpload, uploadFileRequest{
				Filename:    m.Rec.Slug + "-transcript.txt",
				ContentType: "text/plain",
				Type:        "transcript",
			})
			fileRefs = append(fileRefs, fileRef{i, tmpFile.Name(), "transcript"})
		}
	}

	// Get presigned URLs
	presigned, err := c.GetPresignedURLs(catalogNumber, filesToUpload)
	if err != nil {
		return nil, err
	}

	// Upload everything and track keys per member
	type memberKeys struct {
		masterKey     string
		prepKey       string
		transcriptKey string
	}
	keyMap := make([]memberKeys, len(members))

	for i, p := range presigned {
		ref := fileRefs[i]
		fmt.Printf("  uploading %s (%s)...\n", p.Filename, p.Type)
		if err := c.UploadToR2(p.UploadURL, filesToUpload[i].ContentType, ref.localPath); err != nil {
			return nil, fmt.Errorf("uploading %s: %w", p.Filename, err)
		}

		switch ref.role {
		case "master":
			keyMap[ref.memberIdx].masterKey = p.Key
		case "prep":
			keyMap[ref.memberIdx].prepKey = p.Key
		case "transcript":
			keyMap[ref.memberIdx].transcriptKey = p.Key
		}
	}

	// Build multi-track payload
	var tracks []map[string]any
	var transcriptKeys []string

	for i, m := range members {
		title := m.Rec.Title
		if title == "" && m.Summary != nil {
			title = m.Summary.SuggestedTitle
		}
		if title == "" {
			title = m.Rec.Slug
		}

		track := map[string]any{
			"title":    title,
			"duration": int(m.Rec.DurationMs / 1000),
		}
		if keyMap[i].prepKey != "" {
			track["audioUrl"] = keyMap[i].prepKey
			track["audioFilename"] = filepath.Base(m.Rec.PrepPath)
		}
		if keyMap[i].masterKey != "" {
			track["downloadUrl"] = keyMap[i].masterKey
			track["downloadFilename"] = filepath.Base(m.Rec.MasterPath)
		}
		tracks = append(tracks, track)

		if keyMap[i].transcriptKey != "" {
			transcriptKeys = append(transcriptKeys, keyMap[i].transcriptKey)
		}
	}

	// Build description from all summaries
	var description string
	for _, m := range members {
		if m.Summary != nil && m.Summary.SummaryLong != "" {
			if description != "" {
				description += "\n\n---\n\n"
			}
			trackTitle := m.Rec.Title
			if trackTitle == "" && m.Summary != nil {
				trackTitle = m.Summary.SuggestedTitle
			}
			description += fmt.Sprintf("### %s\n\n%s", trackTitle, m.Summary.SummaryLong)
		}
	}

	// Use the first member with a summary for the group-level metadata
	metadata := map[string]any{
		"source":           "audio-archive",
		"audio_archive_id": members[0].Rec.ID, // primary member for lookup
		"group":            true,
		"member_ids":       memberIDs(members),
	}

	// Merge tags, topics, etc. from all summaries
	var allTopics, allTags, allQuotes []string
	for _, m := range members {
		if m.Summary == nil {
			continue
		}
		allTopics = append(allTopics, m.Summary.MainTopics...)
		allTags = append(allTags, m.Summary.Tags...)
		allQuotes = append(allQuotes, m.Summary.NotableQuotes...)
	}
	metadata["main_topics"] = dedup(allTopics)
	metadata["tags"] = dedup(allTags)
	metadata["notable_quotes"] = allQuotes
	if len(transcriptKeys) > 0 {
		metadata["transcript_keys"] = transcriptKeys
	}

	// Use the first summary's recording type and era
	for _, m := range members {
		if m.Summary != nil {
			metadata["recording_type"] = m.Summary.RecordingType
			metadata["estimated_era"] = m.Summary.EstimatedEra
			metadata["mood"] = m.Summary.Mood
			break
		}
	}

	estimatedDate := ""
	for _, m := range members {
		if m.Summary != nil {
			if m.Summary.EstimatedDate != "" {
				estimatedDate = m.Summary.EstimatedDate
				break
			}
			if m.Summary.EstimatedEra != "" {
				estimatedDate = m.Summary.EstimatedEra
				break
			}
		}
	}
	if estimatedDate == "" {
		estimatedDate = members[0].Rec.Date
	}

	payload := map[string]any{
		"catalogNumber":          catalogNumber,
		"title":                  groupTitle,
		"description":            description,
		"medium":                 "reel-to-reel",
		"estimatedRecordingDate": estimatedDate,
		"tracks":                 tracks,
		"metadata":               metadata,
	}

	return c.CreateSound(payload)
}

func memberIDs(members []GroupMember) []int64 {
	ids := make([]int64, len(members))
	for i, m := range members {
		ids[i] = m.Rec.ID
	}
	return ids
}

func dedup(items []string) []string {
	seen := make(map[string]bool)
	var result []string
	for _, item := range items {
		if !seen[item] {
			seen[item] = true
			result = append(result, item)
		}
	}
	return result
}

func (c *Client) doRequest(method, path string, body any) (*http.Response, error) {
	var bodyReader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequest(method, c.baseURL+path, bodyReader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	return c.http.Do(req)
}

// estimatedDate picks the best date/era string for remanence's
// estimatedRecordingDate field. Prefers the summary's estimated date or era
// over the recording's ingest date.
func estimatedDate(rec *model.Recording, summary *summarize.RecordingSummary) string {
	if summary != nil {
		if summary.EstimatedDate != "" {
			return summary.EstimatedDate
		}
		if summary.EstimatedEra != "" {
			return summary.EstimatedEra
		}
	}
	return rec.Date
}
