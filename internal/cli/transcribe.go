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

	fmt.Printf("Transcribing recording %d with model '%s'...\n", id, cfg.ModelSize)

	result, err := pipeline.TranscribeRecording(context.Background(), cfg, db, id)
	if err != nil {
		return err
	}

	fmt.Printf("Transcribed in %s — %d segments, language: %s (%.0f%%)\n",
		result.Duration.Round(1e6), len(result.Result.Segments),
		result.Result.Language, result.Result.LanguageProbability*100)
	fmt.Printf("  Text:  %s\n", result.TxtPath)
	fmt.Printf("  JSON:  %s\n", result.JSONPath)
	fmt.Printf("  DB ID: %d\n", result.TranscriptID)

	return nil
}
