package jobs

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/pipeline"
	"github.com/colton/audio-archive/internal/store"
	"github.com/colton/audio-archive/internal/summarize"
)

// RegisterDefaultHandlers wires up prep, transcribe, and summarize handlers
// using the pipeline package. This is what the worker command calls.
func RegisterDefaultHandlers(m *Manager, cfg config.Config, db *store.DB) {
	m.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		_, err := pipeline.PrepRecording(ctx, cfg, db, job.RecordingID)
		return err
	})

	m.Register(store.JobTranscribe, func(ctx context.Context, job store.Job) error {
		runCfg := cfg
		if job.Model != "" {
			runCfg.WhisperCppModel = filepath.Join(cfg.ModelsDir(), "ggml-"+job.Model+".en.bin")
			runCfg.ModelSize = job.Model
		}
		_, err := pipeline.TranscribeRecording(ctx, runCfg, db, job.RecordingID)
		return err
	})

	m.Register(store.JobSummarize, func(ctx context.Context, job store.Job) error {
		_, err := pipeline.SummarizeRecording(ctx, cfg, db, job.RecordingID)
		if err != nil {
			return err
		}

		// Post-summarize: move source file, then write outbox.
		// Both are best-effort — failures are logged but don't fail the job.
		moveSourceToProcessed(db, job.RecordingID)
		writeOutbox(cfg, db, job.RecordingID)

		return nil
	})
}

// writeOutbox creates a folder in ~/.audio-archive/outbox/ with the
// transcript and summary for review. For grouped recordings, only writes
// the outbox when all group members have completed summarization.
func writeOutbox(cfg config.Config, db *store.DB, recordingID int64) {
	// Check if this is part of a group
	groupID, groupTitle, _ := db.GetRecordingGroup(recordingID)

	if groupID != "" {
		ready, err := db.IsGroupFullySummarized(groupID)
		if err != nil {
			slog.Warn("outbox: failed to check group status", "group_id", groupID, "error", err)
			return
		}
		if !ready {
			slog.Info("outbox: group not fully summarized yet, deferring",
				"recording_id", recordingID,
				"group", groupTitle)
			return
		}
		writeGroupOutbox(cfg, db, groupID, groupTitle)
		return
	}

	writeSingleOutbox(cfg, db, recordingID)
}

func writeSingleOutbox(cfg config.Config, db *store.DB, recordingID int64) {
	rec, err := db.GetRecording(recordingID)
	if err != nil {
		slog.Warn("outbox: failed to get recording", "recording_id", recordingID, "error", err)
		return
	}

	summary, err := db.GetSummary(recordingID)
	if err != nil {
		slog.Warn("outbox: no summary", "recording_id", recordingID, "error", err)
		return
	}

	transcript, _ := db.GetTranscript(recordingID)

	title := rec.Title
	if title == "" && summary != nil {
		title = summary.SuggestedTitle
	}
	if title == "" {
		title = rec.Slug
	}

	dirName := fmt.Sprintf("%s_%s", time.Now().Format("2006-01-02"), sanitizeDirName(title))
	outDir := filepath.Join(cfg.OutboxDir(), dirName)

	if err := os.MkdirAll(outDir, 0755); err != nil {
		slog.Warn("outbox: failed to create dir", "dir", outDir, "error", err)
		return
	}

	// Write transcript
	if transcript != nil && transcript.FullText != "" {
		writeFile(outDir, "transcript.txt", transcript.FullText)
	}

	// Write human-readable summary
	writeFile(outDir, "summary.txt", formatSummaryText(title, summary))

	// Write machine-readable summary
	summaryJSON, _ := json.MarshalIndent(summary, "", "  ")
	writeFile(outDir, "summary.json", string(summaryJSON))

	// Symlink to the prep file so it's easy to listen
	if rec.PrepPath != "" {
		prepAbs := filepath.Join(cfg.DataDir, rec.PrepPath)
		if _, err := os.Stat(prepAbs); err == nil {
			os.Symlink(prepAbs, filepath.Join(outDir, filepath.Base(rec.PrepPath)))
		}
	}

	slog.Info("outbox: wrote review folder",
		"recording_id", recordingID,
		"dir", outDir)
}

func writeGroupOutbox(cfg config.Config, db *store.DB, groupID, groupTitle string) {
	recs, err := db.GetGroupRecordings(groupID)
	if err != nil {
		slog.Warn("outbox: failed to get group recordings", "group_id", groupID, "error", err)
		return
	}

	dirName := fmt.Sprintf("%s_%s", time.Now().Format("2006-01-02"), sanitizeDirName(groupTitle))
	outDir := filepath.Join(cfg.OutboxDir(), dirName)

	if err := os.MkdirAll(outDir, 0755); err != nil {
		slog.Warn("outbox: failed to create dir", "dir", outDir, "error", err)
		return
	}

	// Write each member's transcript and summary
	var allSummaries []string
	for i, rec := range recs {
		full, err := db.GetRecording(rec.ID)
		if err != nil {
			continue
		}

		summary, _ := db.GetSummary(rec.ID)
		transcript, _ := db.GetTranscript(rec.ID)

		title := full.Title
		if title == "" && summary != nil {
			title = summary.SuggestedTitle
		}
		if title == "" {
			title = full.Slug
		}

		prefix := fmt.Sprintf("track-%d", i+1)

		if transcript != nil && transcript.FullText != "" {
			writeFile(outDir, prefix+"-transcript.txt", transcript.FullText)
		}

		if summary != nil {
			writeFile(outDir, prefix+"-summary.txt", formatSummaryText(title, summary))
			summaryJSON, _ := json.MarshalIndent(summary, "", "  ")
			writeFile(outDir, prefix+"-summary.json", string(summaryJSON))
			allSummaries = append(allSummaries, fmt.Sprintf("### Track %d: %s\n\n%s", i+1, title, summary.SummaryLong))
		}

		// Symlink prep file
		if full.PrepPath != "" {
			prepAbs := filepath.Join(cfg.DataDir, full.PrepPath)
			if _, err := os.Stat(prepAbs); err == nil {
				os.Symlink(prepAbs, filepath.Join(outDir, prefix+"-"+filepath.Base(full.PrepPath)))
			}
		}
	}

	// Write a combined overview
	if len(allSummaries) > 0 {
		overview := fmt.Sprintf("# %s\n\n%d tracks\n\n---\n\n%s\n",
			groupTitle, len(recs), strings.Join(allSummaries, "\n\n---\n\n"))
		writeFile(outDir, "overview.txt", overview)
	}

	slog.Info("outbox: wrote group review folder",
		"group", groupTitle,
		"tracks", len(recs),
		"dir", outDir)
}

func formatSummaryText(title string, s *summarize.RecordingSummary) string {
	var b strings.Builder

	fmt.Fprintf(&b, "# %s\n\n", title)
	fmt.Fprintf(&b, "Type: %s (%s confidence)\n", s.RecordingType, s.TypeConfidence)
	if s.EstimatedEra != "" {
		fmt.Fprintf(&b, "Era: %s\n", s.EstimatedEra)
	}
	if s.Mood != "" {
		fmt.Fprintf(&b, "Mood: %s\n", s.Mood)
	}
	if len(s.Speakers) > 0 {
		fmt.Fprintf(&b, "Speakers: %s\n", strings.Join(s.Speakers, ", "))
	}
	b.WriteString("\n")

	if s.SummaryShort != "" {
		fmt.Fprintf(&b, "%s\n\n", s.SummaryShort)
	}
	if s.SummaryLong != "" {
		fmt.Fprintf(&b, "---\n\n%s\n\n", s.SummaryLong)
	}

	if len(s.MainTopics) > 0 {
		b.WriteString("## Topics\n")
		for _, t := range s.MainTopics {
			fmt.Fprintf(&b, "- %s\n", t)
		}
		b.WriteString("\n")
	}

	if len(s.People) > 0 {
		b.WriteString("## People\n")
		for _, p := range s.People {
			fmt.Fprintf(&b, "- %s\n", p)
		}
		b.WriteString("\n")
	}

	if len(s.Places) > 0 {
		b.WriteString("## Places\n")
		for _, p := range s.Places {
			fmt.Fprintf(&b, "- %s\n", p)
		}
		b.WriteString("\n")
	}

	if len(s.NotableQuotes) > 0 {
		b.WriteString("## Notable Quotes\n")
		for _, q := range s.NotableQuotes {
			fmt.Fprintf(&b, "> %s\n\n", q)
		}
	}

	if len(s.Tags) > 0 {
		fmt.Fprintf(&b, "## Tags\n%s\n", strings.Join(s.Tags, ", "))
	}

	return b.String()
}

func sanitizeDirName(name string) string {
	name = strings.ToLower(name)
	name = strings.ReplaceAll(name, " ", "-")
	var clean strings.Builder
	for _, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			clean.WriteRune(r)
		}
	}
	result := clean.String()
	for strings.Contains(result, "--") {
		result = strings.ReplaceAll(result, "--", "-")
	}
	result = strings.Trim(result, "-")
	if len(result) > 80 {
		result = result[:80]
	}
	return result
}

func writeFile(dir, name, content string) {
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		slog.Warn("outbox: failed to write file", "path", path, "error", err)
	}
}

// moveSourceToProcessed moves the original inbox file to a processed/
// subdirectory. Best-effort — failures are logged but don't fail the job.
func moveSourceToProcessed(db *store.DB, recordingID int64) {
	sourcePath, err := db.GetSourcePath(recordingID)
	if err != nil || sourcePath == "" {
		return
	}

	if _, err := os.Stat(sourcePath); err != nil {
		return
	}

	processedDir := filepath.Join(filepath.Dir(sourcePath), "processed")
	if err := os.MkdirAll(processedDir, 0755); err != nil {
		slog.Warn("failed to create processed dir", "dir", processedDir, "error", err)
		return
	}

	destPath := filepath.Join(processedDir, filepath.Base(sourcePath))

	if _, err := os.Stat(destPath); err == nil {
		ext := filepath.Ext(destPath)
		base := destPath[:len(destPath)-len(ext)]
		destPath = base + "_" + time.Now().Format("20060102-150405") + ext
	}

	if err := os.Rename(sourcePath, destPath); err != nil {
		slog.Warn("failed to move source to processed",
			"source", sourcePath,
			"dest", destPath,
			"error", err)
		return
	}

	slog.Info("moved source to processed",
		"recording_id", recordingID,
		"from", filepath.Base(sourcePath),
		"to", destPath)
}
