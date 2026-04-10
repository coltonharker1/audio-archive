package cli

import (
	"context"
	"fmt"
	"os/signal"
	"syscall"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/jobs"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var workerConcurrency int

var workerCmd = &cobra.Command{
	Use:   "worker",
	Short: "Start the background job worker (blocks until Ctrl+C)",
	Long: `Starts a pool of worker goroutines that process pending jobs from the queue.

The worker handles prep, transcribe, and summarize jobs. Press Ctrl+C for
graceful shutdown — any in-progress jobs will finish before exit.

On startup, any jobs left in 'running' state from a previous crashed worker
are automatically reset to 'pending' for retry.`,
	RunE: runWorker,
}

func init() {
	workerCmd.Flags().IntVar(&workerConcurrency, "concurrency", 1, "number of worker goroutines")
	RootCmd.AddCommand(workerCmd)
}

func runWorker(cmd *cobra.Command, args []string) error {
	cfg := config.Default()

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	manager := jobs.NewManager(db)
	jobs.RegisterDefaultHandlers(manager, cfg, db)

	// Set up graceful shutdown on SIGINT/SIGTERM
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	fmt.Printf("Worker started (concurrency=%d). Press Ctrl+C to stop.\n", workerConcurrency)

	if err := manager.Run(ctx, workerConcurrency); err != nil {
		return fmt.Errorf("worker: %w", err)
	}

	fmt.Println("\nWorker stopped cleanly.")
	return nil
}
