package cli

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/colton/audio-archive/internal/audio"
	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var prepCmd = &cobra.Command{
	Use:   "prep [recording-id]",
	Short: "Prepare audio for transcription (normalize, filter, convert)",
	Long:  "Runs the FFmpeg audio preparation pipeline: high-pass filter, loudness normalization, silence trimming, and conversion to 16kHz mono WAV.",
	Args:  cobra.ExactArgs(1),
	RunE:  runPrep,
}

func init() {
	RootCmd.AddCommand(prepCmd)
}

func runPrep(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid recording ID: %w", err)
	}

	cfg := config.Default()

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	rec, err := db.GetRecording(id)
	if err != nil {
		return fmt.Errorf("recording not found: %w", err)
	}

	if rec.PrepPath != "" {
		prepAbs := filepath.Join(cfg.DataDir, rec.PrepPath)
		if _, err := os.Stat(prepAbs); err == nil {
			fmt.Printf("Already prepared: %s\n", prepAbs)
			return nil
		}
	}

	// Build output path: same name but in processed/ with .prep.wav extension
	masterAbs := filepath.Join(cfg.DataDir, rec.MasterPath)
	base := filepath.Base(rec.MasterPath)
	ext := filepath.Ext(base)
	prepName := strings.TrimSuffix(base, ext) + ".prep.wav"

	// Preserve year subdirectory structure
	relDir := filepath.Dir(rec.MasterPath)                        // e.g. "masters/2024"
	yearDir := strings.TrimPrefix(relDir, "masters")              // e.g. "/2024"
	yearDir = strings.TrimPrefix(yearDir, string(os.PathSeparator))

	prepDir := filepath.Join(cfg.ProcessedDir(), yearDir)
	if err := os.MkdirAll(prepDir, 0755); err != nil {
		return fmt.Errorf("creating processed dir: %w", err)
	}

	outputAbs := filepath.Join(prepDir, prepName)

	slog.Info("preparing audio", "input", masterAbs, "output", outputAbs)
	start := time.Now()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	if err := audio.PrepareAudio(ctx, cfg.Ffmpeg, masterAbs, outputAbs); err != nil {
		return fmt.Errorf("audio preparation failed: %w", err)
	}

	elapsed := time.Since(start).Round(time.Millisecond)

	// Update database with prep path
	relPrepPath, _ := filepath.Rel(cfg.DataDir, outputAbs)
	if err := db.UpdatePrepPath(id, relPrepPath); err != nil {
		return fmt.Errorf("updating database: %w", err)
	}

	fmt.Printf("Prepared: %s (%s)\n", outputAbs, elapsed)
	return nil
}
