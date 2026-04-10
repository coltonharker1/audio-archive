package pipeline

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/colton/audio-archive/internal/audio"
	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
)

// PrepResult is returned by PrepRecording on success.
type PrepResult struct {
	PrepPath string        // absolute path to the prepared file
	Duration time.Duration // how long the prep took
	Skipped  bool          // true if the file was already prepared
}

// PrepRecording runs the FFmpeg audio preparation pipeline on a recording.
// It's idempotent — if the prep file already exists, it returns with Skipped=true.
func PrepRecording(ctx context.Context, cfg config.Config, db *store.DB, recordingID int64) (*PrepResult, error) {
	rec, err := db.GetRecording(recordingID)
	if err != nil {
		return nil, fmt.Errorf("recording not found: %w", err)
	}

	// Idempotency check — skip if already prepped
	if rec.PrepPath != "" {
		prepAbs := filepath.Join(cfg.DataDir, rec.PrepPath)
		if _, err := os.Stat(prepAbs); err == nil {
			slog.Info("prep skipped — already prepared", "path", prepAbs)
			return &PrepResult{PrepPath: prepAbs, Skipped: true}, nil
		}
	}

	// Compute output path — same name but .prep.wav in the processed/ directory
	masterAbs := filepath.Join(cfg.DataDir, rec.MasterPath)
	base := filepath.Base(rec.MasterPath)
	ext := filepath.Ext(base)
	prepName := strings.TrimSuffix(base, ext) + ".prep.wav"

	relDir := filepath.Dir(rec.MasterPath)
	yearDir := strings.TrimPrefix(relDir, "masters")
	yearDir = strings.TrimPrefix(yearDir, string(os.PathSeparator))

	prepDir := filepath.Join(cfg.ProcessedDir(), yearDir)
	if err := os.MkdirAll(prepDir, 0755); err != nil {
		return nil, fmt.Errorf("creating processed dir: %w", err)
	}

	outputAbs := filepath.Join(prepDir, prepName)

	slog.Info("preparing audio", "input", masterAbs, "output", outputAbs)
	start := time.Now()

	// Apply a 10-minute cap on individual prep jobs
	prepCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	if err := audio.PrepareAudio(prepCtx, cfg.Ffmpeg, masterAbs, outputAbs); err != nil {
		return nil, fmt.Errorf("ffmpeg prep: %w", err)
	}

	elapsed := time.Since(start)

	// Persist the prep path to the database
	relPrepPath, _ := filepath.Rel(cfg.DataDir, outputAbs)
	if err := db.UpdatePrepPath(recordingID, relPrepPath); err != nil {
		return nil, fmt.Errorf("updating database: %w", err)
	}

	return &PrepResult{PrepPath: outputAbs, Duration: elapsed}, nil
}
