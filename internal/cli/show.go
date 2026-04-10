package cli

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var showSegments bool

var showCmd = &cobra.Command{
	Use:   "show [recording-id]",
	Short: "Show recording details and transcript",
	Args:  cobra.ExactArgs(1),
	RunE:  runShow,
}

func init() {
	showCmd.Flags().BoolVar(&showSegments, "segments", false, "show timed segments instead of plain text")
	RootCmd.AddCommand(showCmd)
}

func runShow(cmd *cobra.Command, args []string) error {
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

	fmt.Printf("Recording #%d\n", rec.ID)
	fmt.Printf("  Date:     %s\n", rec.Date)
	fmt.Printf("  Speaker:  %s\n", rec.Speaker)
	fmt.Printf("  Title:    %s\n", rec.Title)
	fmt.Printf("  Duration: %s\n", formatDuration(rec.DurationMs))
	fmt.Printf("  Master:   %s\n", rec.MasterPath)
	if rec.PrepPath != "" {
		fmt.Printf("  Prepared: %s\n", rec.PrepPath)
	}

	tx, err := db.GetTranscript(id)
	if err != nil {
		fmt.Println("\n  (no transcript — run 'archive transcribe' first)")
		return nil
	}

	fmt.Printf("  Language: %s\n", tx.Language)
	fmt.Printf("  Model:    %s\n", tx.ModelUsed)

	// Show summary if available
	summary, sumErr := db.GetSummary(id)
	if sumErr == nil {
		fmt.Println("\n--- Summary ---")
		if summary.SuggestedTitle != "" {
			fmt.Printf("  Suggested Title: %s\n", summary.SuggestedTitle)
		}
		if summary.EstimatedEra != "" {
			fmt.Printf("  Estimated Era:   %s\n", summary.EstimatedEra)
		}
		fmt.Printf("\n  %s\n", summary.SummaryShort)

		if len(summary.MainTopics) > 0 {
			fmt.Printf("\n  Topics: %s\n", strings.Join(summary.MainTopics, ", "))
		}
		if len(summary.BibleReferences) > 0 {
			fmt.Println("\n  Bible References:")
			for _, ref := range summary.BibleReferences {
				if ref.Chapter > 0 {
					fmt.Printf("    - %s %d:%d — %s\n", ref.Book, ref.Chapter, ref.Verse, ref.Text)
				} else {
					fmt.Printf("    - %s — %s\n", ref.Book, ref.Text)
				}
			}
		}
		if len(summary.Tags) > 0 {
			fmt.Printf("\n  Tags: %s\n", strings.Join(summary.Tags, ", "))
		}
	}

	if showSegments {
		fmt.Println("\n--- Segments ---")
		for _, seg := range tx.Segments {
			fmt.Printf("  [%s → %s] %s\n",
				formatTimestamp(seg.Start), formatTimestamp(seg.End), seg.Text)
		}
	} else {
		fmt.Printf("\n--- Transcript ---\n%s\n", tx.FullText)
	}

	return nil
}

func formatTimestamp(seconds float64) string {
	m := int(seconds) / 60
	s := int(seconds) % 60
	ms := int((seconds - float64(int(seconds))) * 10)
	return fmt.Sprintf("%d:%02d.%d", m, s, ms)
}
