package cli

import (
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var searchCmd = &cobra.Command{
	Use:   "search [query]",
	Short: "Search transcripts using full-text search",
	Args:  cobra.MinimumNArgs(1),
	RunE:  runSearch,
}

func init() {
	RootCmd.AddCommand(searchCmd)
}

func runSearch(cmd *cobra.Command, args []string) error {
	query := strings.Join(args, " ")
	cfg := config.Default()

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	results, err := db.SearchTranscripts(query)
	if err != nil {
		return fmt.Errorf("search failed: %w", err)
	}

	if len(results) == 0 {
		fmt.Printf("No results for: %s\n", query)
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(w, "Found %d result(s) for: %s\n\n", len(results), query)

	for _, r := range results {
		fmt.Fprintf(w, "[%d] %s — %s (%s)\n", r.RecordingID, r.Date, r.Title, r.Speaker)
		fmt.Fprintf(w, "    %s\n\n", r.Snippet)
	}
	return w.Flush()
}
