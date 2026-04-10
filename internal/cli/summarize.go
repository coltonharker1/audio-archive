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
	"github.com/colton/audio-archive/internal/summarize"
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

	rec, err := db.GetRecording(id)
	if err != nil {
		return fmt.Errorf("recording not found: %w", err)
	}

	tx, err := db.GetTranscript(id)
	if err != nil {
		return fmt.Errorf("no transcript found — run 'archive transcribe %d' first: %w", id, err)
	}

	if strings.TrimSpace(tx.FullText) == "" {
		return fmt.Errorf("transcript is empty — nothing to summarize")
	}

	// Set up debug output directory
	baseName := strings.TrimSuffix(filepath.Base(rec.MasterPath), filepath.Ext(filepath.Base(rec.MasterPath)))
	relDir := filepath.Dir(rec.MasterPath)
	yearDir := strings.TrimPrefix(relDir, "masters")
	yearDir = strings.TrimPrefix(yearDir, string(os.PathSeparator))

	debugDir := filepath.Join(cfg.MetadataDir(), yearDir, baseName+"_debug")
	if err := os.MkdirAll(debugDir, 0755); err != nil {
		return fmt.Errorf("creating debug dir: %w", err)
	}

	wordCount := len(strings.Fields(tx.FullText))
	engine := summarize.NewEngine(cfg.OllamaModel)

	fmt.Printf("Summarizing recording %d (%d words) with model '%s'\n", id, wordCount, cfg.OllamaModel)
	fmt.Printf("  Stage 1: chunk summarization\n")
	fmt.Printf("  Stage 2: summary merge\n")
	fmt.Printf("  Stage 3: structured metadata extraction\n")
	fmt.Println()
	start := time.Now()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	result, err := engine.Summarize(ctx, tx.FullText, debugDir)
	if err != nil {
		return fmt.Errorf("summarization failed: %w", err)
	}

	elapsed := time.Since(start).Round(time.Second)
	summary := result.Metadata

	// Save to database
	sumID, err := db.SaveSummary(id, summary, cfg.OllamaModel)
	if err != nil {
		return fmt.Errorf("saving summary: %w", err)
	}

	// Write final .meta.json
	if err := cfg.EnsureDirs(); err != nil {
		return fmt.Errorf("creating dirs: %w", err)
	}

	metaDir := filepath.Join(cfg.MetadataDir(), yearDir)
	metaPath := filepath.Join(metaDir, baseName+".meta.json")
	metaJSON, _ := json.MarshalIndent(summary, "", "  ")
	if err := os.WriteFile(metaPath, metaJSON, 0644); err != nil {
		return fmt.Errorf("writing metadata file: %w", err)
	}

	// Print results
	fmt.Printf("Summarized in %s (DB ID: %d)\n", elapsed, sumID)
	fmt.Printf("  Metadata:    %s\n", metaPath)
	fmt.Printf("  Debug files: %s\n", debugDir)
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

	slog.Info("summarization complete",
		"recording_id", id,
		"chunks", len(result.ChunkSummaries),
		"topics", len(summary.MainTopics),
		"bible_refs", len(summary.BibleReferences),
		"tags", len(summary.Tags),
	)

	return nil
}
