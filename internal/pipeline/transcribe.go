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

	// Verify whisper.cpp binary exists.
	if _, err := os.Stat(cfg.WhisperCppBin); err != nil {
		return nil, fmt.Errorf("whisper.cpp binary not found at %s — run: brew install whisper-cpp", cfg.WhisperCppBin)
	}
	if _, err := os.Stat(cfg.WhisperCppModel); err != nil {
		return nil, fmt.Errorf("whisper.cpp speech model not found at %s — download from https://huggingface.co/ggerganov/whisper.cpp", cfg.WhisperCppModel)
	}

	slog.Info("transcribing", "audio", audioPath, "backend", "whisper.cpp", "model", filepath.Base(cfg.WhisperCppModel))
	start := time.Now()

	// 60-minute cap per transcription job. On Metal this is wildly
	// oversized — r005 (~69min sermon) ran in 1m41s during cutover
	// benchmark — but preserves headroom for long tapes processed on
	// older hardware.
	txCtx, cancel := context.WithTimeout(ctx, 60*time.Minute)
	defer cancel()

	result, err := transcribe.RunWhisperCpp(txCtx, cfg.WhisperCppBin, cfg.WhisperCppModel, cfg.WhisperCppVADModel, audioPath)
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
