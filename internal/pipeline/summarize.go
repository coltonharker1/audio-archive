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

	slog.Info("summarizing", "words", len(strings.Fields(tx.FullText)), "model", cfg.OllamaModel)
	start := time.Now()

	// 30-minute cap per summarization job
	sumCtx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()

	engine := summarize.NewEngine(cfg.OllamaModel)
	result, err := engine.Summarize(sumCtx, summarize.SummarizeInput{
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
	sumID, err := db.SaveSummary(recordingID, summary, cfg.OllamaModel)
	if err != nil {
		return nil, fmt.Errorf("saving summary: %w", err)
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
