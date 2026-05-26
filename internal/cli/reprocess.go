package cli

import (
	"fmt"
	"strconv"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var reprocessAll bool

var reprocessCmd = &cobra.Command{
	Use:   "reprocess [recording-ids...]",
	Short: "Re-run prep, transcribe, and summarize for recordings",
	Long: `Enqueues fresh prep/transcribe/summarize jobs for the specified recordings,
or all recordings if --all is passed. A running worker will pick them up.

Use this after upgrading the whisper model, changing the prep filter chain,
or switching the summarization engine.

Examples:
  archive reprocess 1 2 3     # reprocess specific recordings
  archive reprocess --all     # reprocess the entire archive`,
	RunE: runReprocess,
}

func init() {
	reprocessCmd.Flags().BoolVar(&reprocessAll, "all", false, "reprocess every recording in the archive")
	RootCmd.AddCommand(reprocessCmd)
}

func runReprocess(cmd *cobra.Command, args []string) error {
	if !reprocessAll && len(args) == 0 {
		return fmt.Errorf("specify recording IDs or use --all")
	}

	cfg := config.Default()
	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	var ids []int64

	if reprocessAll {
		recordings, err := db.ListRecordings()
		if err != nil {
			return fmt.Errorf("listing recordings: %w", err)
		}
		for _, r := range recordings {
			ids = append(ids, r.ID)
		}
	} else {
		for _, arg := range args {
			id, err := strconv.ParseInt(arg, 10, 64)
			if err != nil {
				return fmt.Errorf("invalid recording ID %q: %w", arg, err)
			}
			ids = append(ids, id)
		}
	}

	if len(ids) == 0 {
		fmt.Println("No recordings to reprocess.")
		return nil
	}

	jobCount := 0
	for _, id := range ids {
		for _, t := range []store.JobType{store.JobPrep, store.JobTranscribe, store.JobSummarize} {
			if _, err := db.EnqueueJob(id, t); err != nil {
				return fmt.Errorf("enqueuing %s for recording %d: %w", t, id, err)
			}
			jobCount++
		}
	}

	fmt.Printf("Enqueued %d jobs for %d recordings (prep + transcribe + summarize each).\n", jobCount, len(ids))
	fmt.Println("The running worker will pick these up automatically.")
	return nil
}
