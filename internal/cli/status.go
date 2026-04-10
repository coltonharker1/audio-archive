package cli

import (
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var statusLimit int

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show job queue status and recent jobs",
	RunE:  runStatus,
}

func init() {
	statusCmd.Flags().IntVar(&statusLimit, "limit", 15, "number of recent jobs to show")
	RootCmd.AddCommand(statusCmd)
}

func runStatus(cmd *cobra.Command, args []string) error {
	cfg := config.Default()

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	counts, err := db.CountJobs()
	if err != nil {
		return fmt.Errorf("counting jobs: %w", err)
	}

	fmt.Println("Job queue status:")
	fmt.Printf("  Pending:  %d\n", counts.Pending)
	fmt.Printf("  Running:  %d\n", counts.Running)
	fmt.Printf("  Complete: %d\n", counts.Complete)
	fmt.Printf("  Failed:   %d\n", counts.Failed)

	jobList, err := db.ListRecentJobs(statusLimit)
	if err != nil {
		return fmt.Errorf("listing jobs: %w", err)
	}

	if len(jobList) == 0 {
		fmt.Println("\nNo jobs yet. Use 'archive enqueue' to add some.")
		return nil
	}

	fmt.Printf("\nRecent jobs (last %d):\n", len(jobList))
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tREC\tTYPE\tSTATUS\tATTEMPT\tAGE\tDURATION\tERROR")
	fmt.Fprintln(w, "--\t---\t----\t------\t-------\t---\t--------\t-----")

	for _, j := range jobList {
		age := time.Since(j.CreatedAt).Round(time.Second)
		duration := "-"
		if j.StartedAt != nil && j.FinishedAt != nil {
			duration = j.FinishedAt.Sub(*j.StartedAt).Round(time.Second).String()
		} else if j.StartedAt != nil {
			duration = time.Since(*j.StartedAt).Round(time.Second).String() + "..."
		}

		attemptStr := fmt.Sprintf("%d/%d", j.Attempt, j.MaxRetries)
		errStr := truncate(j.Error, 40)

		fmt.Fprintf(w, "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
			j.ID, j.RecordingID, j.Type, j.Status, attemptStr, age, duration, errStr)
	}
	return w.Flush()
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max-3] + "..."
}
