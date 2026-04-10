package cli

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var listCmd = &cobra.Command{
	Use:   "list",
	Short: "List all recordings in the archive",
	RunE:  runList,
}

func init() {
	RootCmd.AddCommand(listCmd)
}

func runList(cmd *cobra.Command, args []string) error {
	cfg := config.Default()

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	recs, err := db.ListRecordings()
	if err != nil {
		return fmt.Errorf("listing recordings: %w", err)
	}

	if len(recs) == 0 {
		fmt.Println("No recordings found. Use 'archive ingest' to add one.")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tDATE\tSPEAKER\tTITLE\tDURATION")
	fmt.Fprintln(w, "--\t----\t-------\t-----\t--------")

	for _, rec := range recs {
		dur := formatDuration(rec.DurationMs)
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n",
			rec.ID, rec.Date, rec.Speaker, rec.Title, dur)
	}
	return w.Flush()
}

func formatDuration(ms int64) string {
	if ms == 0 {
		return "-"
	}
	totalSec := ms / 1000
	m := totalSec / 60
	s := totalSec % 60
	return fmt.Sprintf("%d:%02d", m, s)
}
