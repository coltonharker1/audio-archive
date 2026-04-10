package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

var (
	runSpeaker      string
	runDate         string
	runTitle        string
	runModel        string
	runOllamaModel  string
	runSkipSummarize bool
)

var runCmd = &cobra.Command{
	Use:   "run [file]",
	Short: "Run the full pipeline: ingest → prep → transcribe → summarize",
	Args:  cobra.ExactArgs(1),
	RunE:  runPipeline,
}

func init() {
	runCmd.Flags().StringVar(&runSpeaker, "speaker", "", "speaker name")
	runCmd.Flags().StringVar(&runDate, "date", "", "recording date (YYYY-MM-DD)")
	runCmd.Flags().StringVar(&runTitle, "title", "", "recording title or description")
	runCmd.Flags().StringVar(&runModel, "model", "", "whisper model size (tiny, base, small, medium, large)")
	runCmd.Flags().StringVar(&runOllamaModel, "llm", "", "Ollama model for summarization (default: mistral)")
	runCmd.Flags().BoolVar(&runSkipSummarize, "no-summary", false, "skip the summarization step")
	RootCmd.AddCommand(runCmd)
}

func runPipeline(cmd *cobra.Command, args []string) error {
	totalSteps := 4
	if runSkipSummarize {
		totalSteps = 3
	}

	// Step 1: Ingest
	fmt.Printf("=== Step 1/%d: Ingest ===\n", totalSteps)
	ingestSpeaker = runSpeaker
	ingestDate = runDate
	ingestTitle = runTitle
	if err := runIngest(cmd, args); err != nil {
		return fmt.Errorf("ingest failed: %w", err)
	}

	// Get the ID of the just-ingested recording
	cfg := getConfig()
	db, err := openDB(cfg)
	if err != nil {
		return err
	}
	defer db.Close()

	recs, err := db.ListRecordings()
	if err != nil || len(recs) == 0 {
		return fmt.Errorf("could not find ingested recording")
	}
	// Most recent recording (first in list, sorted by date DESC, id DESC)
	latestID := fmt.Sprintf("%d", recs[0].ID)

	// Step 2: Prep
	fmt.Printf("\n=== Step 2/%d: Prep ===\n", totalSteps)
	if err := runPrep(cmd, []string{latestID}); err != nil {
		return fmt.Errorf("prep failed: %w", err)
	}

	// Step 3: Transcribe
	fmt.Printf("\n=== Step 3/%d: Transcribe ===\n", totalSteps)
	transcribeModel = runModel
	if err := runTranscribe(cmd, []string{latestID}); err != nil {
		return fmt.Errorf("transcribe failed: %w", err)
	}

	// Step 4: Summarize (optional)
	if !runSkipSummarize {
		fmt.Printf("\n=== Step 4/%d: Summarize ===\n", totalSteps)
		summarizeModelFlag = runOllamaModel
		if err := runSummarize(cmd, []string{latestID}); err != nil {
			// Summarization failure shouldn't fail the whole pipeline
			fmt.Printf("Warning: summarization failed: %v\n", err)
			fmt.Println("You can retry later with: archive summarize", latestID)
		}
	}

	fmt.Printf("\nPipeline complete for recording %s\n", latestID)
	return nil
}
