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
	"github.com/colton/audio-archive/internal/transcribe"
)

// TranscribeResult is returned on successful transcription.
type TranscribeResult struct {
	Result       *transcribe.Result // the raw transcription result
	TxtPath      string
	JSONPath     string
	Duration     time.Duration
	TranscriptID int64
}

// TranscribeRecording runs the Python faster-whisper worker on a recording.
// Prefers the prepared audio file; falls back to the master if no prep exists.
func TranscribeRecording(ctx context.Context, cfg config.Config, db *store.DB, recordingID int64) (*TranscribeResult, error) {
	rec, err := db.GetRecording(recordingID)
	if err != nil {
		return nil, fmt.Errorf("recording not found: %w", err)
	}

	// Prefer prepped audio, fall back to master
	audioRel := rec.PrepPath
	if audioRel == "" {
		audioRel = rec.MasterPath
		slog.Warn("no prepared audio, transcribing master — consider running prep first")
	}
	audioPath := filepath.Join(cfg.DataDir, audioRel)

	if _, err := os.Stat(audioPath); err != nil {
		return nil, fmt.Errorf("audio file not found: %s", audioPath)
	}

	// Verify Python worker exists
	if _, err := os.Stat(cfg.PythonPath); err != nil {
		return nil, fmt.Errorf("python not found at %s — run: python3 -m venv .venv && .venv/bin/pip install -r worker/requirements.txt", cfg.PythonPath)
	}

	slog.Info("transcribing", "audio", audioPath, "model", cfg.ModelSize)
	start := time.Now()

	// 60-minute cap per transcription job
	txCtx, cancel := context.WithTimeout(ctx, 60*time.Minute)
	defer cancel()

	result, err := transcribe.Run(txCtx, cfg.PythonPath, cfg.WorkerPath, audioPath, cfg.ModelSize)
	if err != nil {
		return nil, fmt.Errorf("transcription worker: %w", err)
	}

	elapsed := time.Since(start)

	// Save to database
	txID, err := db.SaveTranscript(recordingID, result, cfg.ModelSize)
	if err != nil {
		return nil, fmt.Errorf("saving transcript: %w", err)
	}

	// Write transcript files
	if err := cfg.EnsureDirs(); err != nil {
		return nil, fmt.Errorf("creating dirs: %w", err)
	}

	baseName := strings.TrimSuffix(filepath.Base(rec.MasterPath), filepath.Ext(filepath.Base(rec.MasterPath)))
	relDir := filepath.Dir(rec.MasterPath)
	yearDir := strings.TrimPrefix(relDir, "masters")
	yearDir = strings.TrimPrefix(yearDir, string(os.PathSeparator))

	txDir := filepath.Join(cfg.TranscriptsDir(), yearDir)
	if err := os.MkdirAll(txDir, 0755); err != nil {
		return nil, fmt.Errorf("creating transcripts dir: %w", err)
	}

	txtPath := filepath.Join(txDir, baseName+".txt")
	if err := os.WriteFile(txtPath, []byte(result.FullText), 0644); err != nil {
		return nil, fmt.Errorf("writing text transcript: %w", err)
	}

	jsonPath := filepath.Join(txDir, baseName+".json")
	jsonData, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshaling JSON transcript: %w", err)
	}
	if err := os.WriteFile(jsonPath, jsonData, 0644); err != nil {
		return nil, fmt.Errorf("writing JSON transcript: %w", err)
	}

	return &TranscribeResult{
		Result:       result,
		TxtPath:      txtPath,
		JSONPath:     jsonPath,
		Duration:     elapsed,
		TranscriptID: txID,
	}, nil
}
