package cli

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
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
	workerCmd.Flags().IntVar(&workerConcurrency, "concurrency", 3, "number of worker goroutines")
	RootCmd.AddCommand(workerCmd)
}

func runWorker(cmd *cobra.Command, args []string) error {
	cfg := config.Default()

	// Acquire the worker PID lock before opening the DB. Two workers
	// hitting SQLite's single-writer connection deadlock the queue.
	releaseLock, err := acquireWorkerLock(cfg)
	if err != nil {
		return err
	}
	defer releaseLock()

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

// acquireWorkerLock writes a PID file in the data dir. If a PID file
// already exists with a process that's still alive, returns an error.
// Returns a release function that removes the PID file on shutdown.
func acquireWorkerLock(cfg config.Config) (func(), error) {
	if err := cfg.EnsureDirs(); err != nil {
		return nil, fmt.Errorf("ensuring data dirs: %w", err)
	}

	pidFile := filepath.Join(cfg.DataDir, "worker.pid")

	if data, err := os.ReadFile(pidFile); err == nil {
		pidStr := strings.TrimSpace(string(data))
		if pid, err := strconv.Atoi(pidStr); err == nil && pid > 0 {
			// Send signal 0 to check liveness without affecting the process.
			if proc, err := os.FindProcess(pid); err == nil {
				if err := proc.Signal(syscall.Signal(0)); err == nil {
					return nil, fmt.Errorf(
						"another worker is already running (pid %d). "+
							"Stop it first or remove %s if it's stale",
						pid, pidFile)
				}
			}
		}
		// Stale PID file — remove it and continue.
		os.Remove(pidFile)
	}

	pid := strconv.Itoa(os.Getpid())
	if err := os.WriteFile(pidFile, []byte(pid), 0644); err != nil {
		return nil, fmt.Errorf("writing PID file: %w", err)
	}

	return func() {
		os.Remove(pidFile)
	}, nil
}
