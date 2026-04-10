package cli

import (
	"context"
	"fmt"
	"os/signal"
	"syscall"
	"time"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/colton/audio-archive/internal/watcher"
	"github.com/spf13/cobra"
)

var (
	watchPoll        time.Duration
	watchStableDelay time.Duration
	watchSpeaker     string
	watchNoEnqueue   bool
)

var watchCmd = &cobra.Command{
	Use:   "watch [directory]",
	Short: "Watch a folder for new audio files and automatically process them",
	Long: `Runs a long-lived process that monitors a directory for new audio files
and automatically ingests them into the archive. Uses fsnotify for real-time
detection plus a periodic sweep as a safety net.

Each detected file waits for its size to be stable (no changes for --stable-delay)
before being ingested, so files that are still being copied aren't processed mid-write.

After a successful ingest, prep + transcribe + summarize jobs are enqueued for
the worker to pick up. Use --no-enqueue to ingest only (e.g. if you want to
trigger processing manually later).

Designed to run as a background daemon via launchd. Press Ctrl+C for graceful shutdown.`,
	Args: cobra.ExactArgs(1),
	RunE: runWatch,
}

func init() {
	watchCmd.Flags().DurationVar(&watchPoll, "poll", 60*time.Second, "periodic directory sweep interval")
	watchCmd.Flags().DurationVar(&watchStableDelay, "stable-delay", 3*time.Second, "file must have unchanged size for this long before ingesting")
	watchCmd.Flags().StringVar(&watchSpeaker, "speaker", "", "default speaker for ingested files")
	watchCmd.Flags().BoolVar(&watchNoEnqueue, "no-enqueue", false, "ingest only, don't enqueue pipeline jobs")
	RootCmd.AddCommand(watchCmd)
}

func runWatch(cmd *cobra.Command, args []string) error {
	cfg := config.Default()

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	w, err := watcher.New(cfg, db, watcher.Options{
		Dir:            args[0],
		PollInterval:   watchPoll,
		StableDelay:    watchStableDelay,
		DefaultSpeaker: watchSpeaker,
		EnqueueJobs:    !watchNoEnqueue,
	})
	if err != nil {
		return fmt.Errorf("creating watcher: %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	fmt.Printf("Watching %s\n", args[0])
	fmt.Printf("  Stable delay: %s (files must be unchanged this long before ingest)\n", watchStableDelay)
	fmt.Printf("  Sweep interval: %s (periodic backup scan)\n", watchPoll)
	if watchNoEnqueue {
		fmt.Println("  Pipeline jobs: disabled (--no-enqueue)")
	} else {
		fmt.Println("  Pipeline jobs: enabled (prep + transcribe + summarize)")
	}
	fmt.Println("\nPress Ctrl+C to stop.")

	if err := w.Run(ctx); err != nil {
		return fmt.Errorf("watcher: %w", err)
	}

	fmt.Println("\nWatcher stopped cleanly.")
	return nil
}
