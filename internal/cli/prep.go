package cli

import (
	"context"
	"fmt"
	"strconv"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/pipeline"
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

	result, err := pipeline.PrepRecording(context.Background(), cfg, db, id)
	if err != nil {
		return err
	}

	if result.Skipped {
		fmt.Printf("Already prepared: %s\n", result.PrepPath)
	} else {
		fmt.Printf("Prepared: %s (%s)\n", result.PrepPath, result.Duration.Round(1e6))
	}
	return nil
}
