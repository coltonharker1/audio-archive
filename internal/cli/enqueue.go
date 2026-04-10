package cli

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var enqueueCmd = &cobra.Command{
	Use:   "enqueue [recording-id] [job-type]",
	Short: "Enqueue a background job (prep, transcribe, or summarize)",
	Long: `Adds a job to the queue. A running worker (see 'archive worker') will pick it up.

Job types:
  prep        — run the FFmpeg audio preparation pipeline
  transcribe  — run the Python faster-whisper transcription
  summarize   — run the 3-stage Ollama summarization pipeline
  all         — enqueue prep, transcribe, and summarize in order`,
	Args: cobra.ExactArgs(2),
	RunE: runEnqueue,
}

func init() {
	RootCmd.AddCommand(enqueueCmd)
}

func runEnqueue(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid recording ID: %w", err)
	}

	jobTypeArg := strings.ToLower(args[1])

	cfg := config.Default()
	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	// Verify recording exists
	if _, err := db.GetRecording(id); err != nil {
		return fmt.Errorf("recording not found: %w", err)
	}

	var types []store.JobType
	switch jobTypeArg {
	case "prep":
		types = []store.JobType{store.JobPrep}
	case "transcribe":
		types = []store.JobType{store.JobTranscribe}
	case "summarize":
		types = []store.JobType{store.JobSummarize}
	case "all":
		types = []store.JobType{store.JobPrep, store.JobTranscribe, store.JobSummarize}
	default:
		return fmt.Errorf("unknown job type %q — must be prep, transcribe, summarize, or all", jobTypeArg)
	}

	for _, t := range types {
		jobID, err := db.EnqueueJob(id, t)
		if err != nil {
			return fmt.Errorf("enqueuing %s: %w", t, err)
		}
		fmt.Printf("Enqueued job %d: %s for recording %d\n", jobID, t, id)
	}

	fmt.Println("\nStart a worker to process jobs: archive worker")
	return nil
}
