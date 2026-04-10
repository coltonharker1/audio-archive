package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/colton/audio-archive/internal/transcribe"
	"github.com/spf13/cobra"
)

var transcribeModel string

var transcribeCmd = &cobra.Command{
	Use:   "transcribe [recording-id]",
	Short: "Transcribe a recording using faster-whisper",
	Long:  "Invokes the Python transcription worker on a prepared recording. Saves transcript text and timed JSON.",
	Args:  cobra.ExactArgs(1),
	RunE:  runTranscribe,
}

func init() {
	transcribeCmd.Flags().StringVar(&transcribeModel, "model", "", "whisper model size (tiny, base, small, medium, large)")
	RootCmd.AddCommand(transcribeCmd)
}

func runTranscribe(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid recording ID: %w", err)
	}

	cfg := config.Default()
	if transcribeModel != "" {
		cfg.ModelSize = transcribeModel
	}

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	rec, err := db.GetRecording(id)
	if err != nil {
		return fmt.Errorf("recording not found: %w", err)
	}

	// Prefer prepped audio, fall back to master
	audioRel := rec.PrepPath
	if audioRel == "" {
		audioRel = rec.MasterPath
		slog.Warn("no prepared audio, using master file — consider running 'archive prep' first")
	}
	audioPath := filepath.Join(cfg.DataDir, audioRel)

	if _, err := os.Stat(audioPath); err != nil {
		return fmt.Errorf("audio file not found: %s", audioPath)
	}

	// Verify Python worker exists
	if _, err := os.Stat(cfg.PythonPath); err != nil {
		return fmt.Errorf("python not found at %s — run: python3 -m venv .venv && .venv/bin/pip install faster-whisper", cfg.PythonPath)
	}

	fmt.Printf("Transcribing recording %d with model '%s'...\n", id, cfg.ModelSize)
	start := time.Now()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Minute)
	defer cancel()

	result, err := transcribe.Run(ctx, cfg.PythonPath, cfg.WorkerPath, audioPath, cfg.ModelSize)
	if err != nil {
		return fmt.Errorf("transcription failed: %w", err)
	}

	elapsed := time.Since(start).Round(time.Millisecond)

	// Save to database
	txID, err := db.SaveTranscript(id, result, cfg.ModelSize)
	if err != nil {
		return fmt.Errorf("saving transcript to database: %w", err)
	}

	// Save transcript files alongside the recording
	if err := cfg.EnsureDirs(); err != nil {
		return fmt.Errorf("creating dirs: %w", err)
	}

	baseName := strings.TrimSuffix(filepath.Base(rec.MasterPath), filepath.Ext(filepath.Base(rec.MasterPath)))
	// Strip .prep if it's in the base
	baseName = strings.TrimSuffix(baseName, ".prep")

	relDir := filepath.Dir(rec.MasterPath)
	yearDir := strings.TrimPrefix(relDir, "masters")
	yearDir = strings.TrimPrefix(yearDir, string(os.PathSeparator))

	txDir := filepath.Join(cfg.TranscriptsDir(), yearDir)
	if err := os.MkdirAll(txDir, 0755); err != nil {
		return fmt.Errorf("creating transcripts dir: %w", err)
	}

	// Write plain text transcript
	txtPath := filepath.Join(txDir, baseName+".txt")
	if err := os.WriteFile(txtPath, []byte(result.FullText), 0644); err != nil {
		return fmt.Errorf("writing text transcript: %w", err)
	}

	// Write JSON transcript with timestamps
	jsonPath := filepath.Join(txDir, baseName+".json")
	jsonData, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling JSON transcript: %w", err)
	}
	if err := os.WriteFile(jsonPath, jsonData, 0644); err != nil {
		return fmt.Errorf("writing JSON transcript: %w", err)
	}

	fmt.Printf("Transcribed in %s — %d segments, language: %s (%.0f%%)\n",
		elapsed, len(result.Segments), result.Language, result.LanguageProbability*100)
	fmt.Printf("  Text:  %s\n", txtPath)
	fmt.Printf("  JSON:  %s\n", jsonPath)
	fmt.Printf("  DB ID: %d\n", txID)

	return nil
}
