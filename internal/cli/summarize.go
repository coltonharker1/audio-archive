package cli

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/pipeline"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var summarizeModelFlag string

var summarizeCmd = &cobra.Command{
	Use:   "summarize [recording-id]",
	Short: "Generate a structured summary using a local LLM via Ollama",
	Long: `Runs a 3-stage summarization pipeline:
  1. Chunk summarization — splits transcript to fit model context, summarizes each chunk
  2. Summary merge — combines chunk summaries into one coherent narrative
  3. Metadata extraction — extracts structured JSON (topics, references, tags, etc.)

Intermediate outputs are saved for debugging in the metadata directory.`,
	Args: cobra.ExactArgs(1),
	RunE: runSummarize,
}

func init() {
	summarizeCmd.Flags().StringVar(&summarizeModelFlag, "model", "", "Ollama model to use (default: mistral)")
	RootCmd.AddCommand(summarizeCmd)
}

func runSummarize(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid recording ID: %w", err)
	}

	cfg := config.Default()
	if summarizeModelFlag != "" {
		cfg.OllamaModel = summarizeModelFlag
	}

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	fmt.Printf("Summarizing recording %d with model '%s'\n", id, cfg.OllamaModel)
	fmt.Println("  Stage 1: chunk summarization")
	fmt.Println("  Stage 2: summary merge")
	fmt.Println("  Stage 3: structured metadata extraction")
	fmt.Println()

	result, err := pipeline.SummarizeRecording(context.Background(), cfg, db, id)
	if err != nil {
		return err
	}

	summary := result.Summary
	fmt.Printf("Summarized in %s (DB ID: %d)\n", result.Duration.Round(1e9), result.SummaryID)
	fmt.Printf("  Metadata:    %s\n", result.MetaPath)
	fmt.Printf("  Debug files: %s\n", result.DebugDir)
	fmt.Println()
	fmt.Printf("Title:   %s\n", summary.SuggestedTitle)
	if summary.EstimatedEra != "" {
		fmt.Printf("Era:     %s\n", summary.EstimatedEra)
	}
	fmt.Printf("Summary: %s\n", summary.SummaryShort)
	fmt.Println()

	fmt.Println("Topics:")
	for _, t := range summary.MainTopics {
		fmt.Printf("  - %s\n", t)
	}

	if len(summary.BibleReferences) > 0 {
		fmt.Println("\nBible References:")
		for _, ref := range summary.BibleReferences {
			if ref.Chapter > 0 {
				fmt.Printf("  - %s %d:%d — %s\n", ref.Book, ref.Chapter, ref.Verse, ref.Text)
			} else {
				fmt.Printf("  - %s — %s\n", ref.Book, ref.Text)
			}
		}
	}

	if len(summary.NotableQuotes) > 0 {
		fmt.Println("\nNotable Quotes:")
		for _, q := range summary.NotableQuotes {
			fmt.Printf("  \"%s\"\n", q)
		}
	}

	fmt.Printf("\nTags: %s\n", strings.Join(summary.Tags, ", "))

	return nil
}
