package cli

import (
	"context"
	"fmt"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/pipeline"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var (
	ingestSpeaker string
	ingestDate    string
	ingestTitle   string
)

var ingestCmd = &cobra.Command{
	Use:   "ingest [file]",
	Short: "Ingest a recording into the archive",
	Long:  "Copies the audio file to the masters directory, extracts metadata, and creates a database record.",
	Args:  cobra.ExactArgs(1),
	RunE:  runIngest,
}

func init() {
	ingestCmd.Flags().StringVar(&ingestSpeaker, "speaker", "", "speaker name")
	ingestCmd.Flags().StringVar(&ingestDate, "date", "", "recording date (YYYY-MM-DD)")
	ingestCmd.Flags().StringVar(&ingestTitle, "title", "", "recording title or description")
	RootCmd.AddCommand(ingestCmd)
}

func runIngest(cmd *cobra.Command, args []string) error {
	cfg := config.Default()

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	result, err := pipeline.IngestFile(context.Background(), cfg, db, pipeline.IngestOptions{
		SourcePath: args[0],
		Speaker:    ingestSpeaker,
		Date:       ingestDate,
		Title:      ingestTitle,
	})
	if err != nil {
		return err
	}

	if result.Skipped {
		fmt.Printf("Already in archive: %s (id=%d)\n", result.ArchivePath, result.RecordingID)
		return nil
	}

	fmt.Printf("Ingested: %s (id=%d)\n", result.ArchivePath, result.RecordingID)
	if result.Meta != nil {
		durationSec := float64(result.Meta.DurationMs) / 1000
		minutes := int(durationSec) / 60
		seconds := int(durationSec) % 60
		fmt.Printf("Duration: %d:%02d | Sample Rate: %d Hz | Channels: %d\n",
			minutes, seconds, result.Meta.SampleRate, result.Meta.Channels)
	}
	return nil
}
