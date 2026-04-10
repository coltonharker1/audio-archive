package cli

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/pipeline"
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
  3. Classification + metadata extraction — classifies the recording type and extracts
     universal + type-specific structured metadata (topics, people, places, etc.)

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
	fmt.Println("  Stage 3: classification + structured metadata extraction")
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
	printSummary(summary)
	return nil
}

// printSummary renders a RecordingSummary to the terminal in a compact
// human-readable form.
func printSummary(s *summarize.RecordingSummary) {
	fmt.Printf("Type:    %s", s.RecordingType)
	if s.TypeConfidence != "" {
		fmt.Printf(" (%s confidence)", s.TypeConfidence)
	}
	fmt.Println()

	if s.SuggestedTitle != "" {
		fmt.Printf("Title:   %s\n", s.SuggestedTitle)
	}
	if s.EstimatedEra != "" || s.EstimatedDate != "" {
		parts := []string{}
		if s.EstimatedDate != "" {
			parts = append(parts, s.EstimatedDate)
		}
		if s.EstimatedEra != "" {
			parts = append(parts, s.EstimatedEra)
		}
		fmt.Printf("When:    %s\n", strings.Join(parts, " / "))
	}
	if s.Mood != "" {
		fmt.Printf("Mood:    %s\n", s.Mood)
	}
	fmt.Printf("Summary: %s\n", s.SummaryShort)
	fmt.Println()

	if len(s.MainTopics) > 0 {
		fmt.Println("Topics:")
		for _, t := range s.MainTopics {
			fmt.Printf("  - %s\n", t)
		}
	}

	if len(s.Themes) > 0 {
		fmt.Printf("\nThemes: %s\n", strings.Join(s.Themes, ", "))
	}

	if len(s.People) > 0 {
		fmt.Printf("\nPeople: %s\n", strings.Join(s.People, ", "))
	}
	if len(s.Places) > 0 {
		fmt.Printf("Places: %s\n", strings.Join(s.Places, ", "))
	}
	if len(s.Organizations) > 0 {
		fmt.Printf("Orgs:   %s\n", strings.Join(s.Organizations, ", "))
	}
	if len(s.DatesMentioned) > 0 {
		fmt.Printf("Dates:  %s\n", strings.Join(s.DatesMentioned, ", "))
	}

	if len(s.NotableQuotes) > 0 {
		fmt.Println("\nNotable Quotes:")
		for _, q := range s.NotableQuotes {
			fmt.Printf("  \"%s\"\n", q)
		}
	}

	if len(s.ActionItems) > 0 {
		fmt.Println("\nAction Items:")
		for _, item := range s.ActionItems {
			fmt.Printf("  - %s\n", item)
		}
	}

	// Type-specific fields
	if len(s.TypeSpecific) > 0 {
		fmt.Printf("\n%s-specific:\n", titleCase(string(s.RecordingType)))
		printTypeSpecific(s.TypeSpecific)
	}

	if len(s.Tags) > 0 {
		fmt.Printf("\nTags: %s\n", strings.Join(s.Tags, ", "))
	}
}

// printTypeSpecific renders the map[string]any of type-specific fields.
// It handles nested arrays/objects by JSON-encoding them compactly.
func printTypeSpecific(m map[string]any) {
	// Sort keys for stable output
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, k := range keys {
		v := m[k]
		switch vv := v.(type) {
		case string:
			if vv != "" {
				fmt.Printf("  %s: %s\n", k, vv)
			}
		case bool:
			fmt.Printf("  %s: %v\n", k, vv)
		case float64:
			fmt.Printf("  %s: %v\n", k, vv)
		case []any:
			if len(vv) > 0 {
				fmt.Printf("  %s:\n", k)
				for _, item := range vv {
					fmt.Printf("    - %v\n", formatAnyValue(item))
				}
			}
		case map[string]any:
			if len(vv) > 0 {
				fmt.Printf("  %s: %v\n", k, formatAnyValue(vv))
			}
		default:
			fmt.Printf("  %s: %v\n", k, v)
		}
	}
}

// formatAnyValue formats a nested value for display (used inside arrays).
// For objects, it skips empty string values so we don't render noise like
// "text=, verse=" when the LLM left fields blank.
func formatAnyValue(v any) string {
	switch vv := v.(type) {
	case map[string]any:
		var parts []string
		keys := make([]string, 0, len(vv))
		for k := range vv {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			val := vv[k]
			// Skip empty string values
			if s, ok := val.(string); ok && s == "" {
				continue
			}
			// Skip zero integer/float values for optional fields like chapter/verse
			if f, ok := val.(float64); ok && f == 0 {
				continue
			}
			parts = append(parts, fmt.Sprintf("%s=%v", k, val))
		}
		return "{" + strings.Join(parts, ", ") + "}"
	case string:
		return vv
	default:
		return fmt.Sprintf("%v", v)
	}
}

func titleCase(s string) string {
	if s == "" {
		return ""
	}
	// Replace underscores with spaces and capitalize first letter of each word
	s = strings.ReplaceAll(s, "_", " ")
	words := strings.Fields(s)
	for i, w := range words {
		if len(w) > 0 {
			words[i] = strings.ToUpper(w[:1]) + w[1:]
		}
	}
	return strings.Join(words, " ")
}
