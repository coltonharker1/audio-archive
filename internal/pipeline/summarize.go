package pipeline

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
	"github.com/colton/audio-archive/internal/store"
	"github.com/colton/audio-archive/internal/summarize"
)

// SummarizeResult is returned on successful summarization.
type SummarizeResult struct {
	Summary   *summarize.RecordingSummary
	MetaPath  string
	DebugDir  string
	Duration  time.Duration
	SummaryID int64
}

// SummarizeRecording runs the 3-stage summarization pipeline on a recording's
// transcript using a local LLM via Ollama.
func SummarizeRecording(ctx context.Context, cfg config.Config, db *store.DB, recordingID int64) (*SummarizeResult, error) {
	rec, err := db.GetRecording(recordingID)
	if err != nil {
		return nil, fmt.Errorf("recording not found: %w", err)
	}

	tx, err := db.GetTranscript(recordingID)
	if err != nil {
		return nil, fmt.Errorf("no transcript — transcribe first: %w", err)
	}

	// Note: we no longer error on empty transcripts. An empty transcript
	// combined with the recording's duration is a strong signal to the
	// classifier that this is a non-speech recording (music, field recording,
	// ambient). The engine handles this by skipping chunk/merge stages and
	// synthesizing a minimal input for the extraction step.

	// Set up debug directory (per-recording)
	baseName := strings.TrimSuffix(filepath.Base(rec.MasterPath), filepath.Ext(filepath.Base(rec.MasterPath)))
	relDir := filepath.Dir(rec.MasterPath)
	yearDir := strings.TrimPrefix(relDir, "masters")
	yearDir = strings.TrimPrefix(yearDir, string(os.PathSeparator))

	debugDir := filepath.Join(cfg.MetadataDir(), yearDir, baseName+"_debug")
	if err := os.MkdirAll(debugDir, 0755); err != nil {
		return nil, fmt.Errorf("creating debug dir: %w", err)
	}

	slog.Info("summarizing",
		"words", len(strings.Fields(tx.FullText)),
		"engine", cfg.SummarizeEngine)
	start := time.Now()

	// 5-minute cap for claude (network), 30-minute cap for ollama (local).
	timeout := 30 * time.Minute
	if cfg.SummarizeEngine == "claude" {
		timeout = 5 * time.Minute
	}
	sumCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// Select summarization engine based on config.
	var summarizer interface {
		Summarize(ctx context.Context, input summarize.SummarizeInput) (*summarize.PipelineResult, error)
	}
	switch cfg.SummarizeEngine {
	case "claude":
		summarizer = summarize.NewClaudeEngine(cfg.ClaudeBin)
	default:
		summarizer = summarize.NewEngine(cfg.OllamaModel)
	}

	result, err := summarizer.Summarize(sumCtx, summarize.SummarizeInput{
		Transcript: tx.FullText,
		DurationMs: rec.DurationMs,
		Title:      rec.Title,
		SourceName: filepath.Base(rec.MasterPath),
		DebugDir:   debugDir,
	})
	if err != nil {
		return nil, fmt.Errorf("summarization engine: %w", err)
	}

	elapsed := time.Since(start)
	summary := result.Metadata

	// Save to database
	modelUsed := cfg.OllamaModel
	if cfg.SummarizeEngine == "claude" {
		modelUsed = "claude"
	}
	sumID, err := db.SaveSummary(recordingID, summary, modelUsed)
	if err != nil {
		return nil, fmt.Errorf("saving summary: %w", err)
	}

	// Backfill recording metadata from the summary so `archive list` shows
	// meaningful titles, speakers, and dates instead of empty columns.
	// Only fills fields the user didn't already set at ingest time.
	speaker := ""
	if len(summary.Speakers) > 0 {
		speaker = summary.Speakers[0]
	}
	if err := db.UpdateRecordingMetadata(recordingID, summary.SuggestedTitle, speaker, summary.EstimatedDate); err != nil {
		slog.Warn("failed to backfill recording metadata from summary", "recording", recordingID, "error", err)
	}

	// Write final .meta.json file
	if err := cfg.EnsureDirs(); err != nil {
		return nil, fmt.Errorf("creating dirs: %w", err)
	}

	metaDir := filepath.Join(cfg.MetadataDir(), yearDir)
	metaPath := filepath.Join(metaDir, baseName+".meta.json")
	metaJSON, _ := json.MarshalIndent(summary, "", "  ")
	if err := os.WriteFile(metaPath, metaJSON, 0644); err != nil {
		return nil, fmt.Errorf("writing metadata file: %w", err)
	}

	return &SummarizeResult{
		Summary:   summary,
		MetaPath:  metaPath,
		DebugDir:  debugDir,
		Duration:  elapsed,
		SummaryID: sumID,
	}, nil
}
