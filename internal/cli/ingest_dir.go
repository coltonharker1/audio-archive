package cli

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/pipeline"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var (
	batchRecursive bool
	batchSpeaker   string
	batchDate      string
	batchRun       bool
	batchDryRun    bool
)

// audioExtensions lists the file extensions we accept in batch mode.
// All comparisons are case-insensitive.
var audioExtensions = map[string]bool{
	".wav":  true,
	".mp3":  true,
	".m4a":  true,
	".flac": true,
	".aiff": true,
	".aif":  true,
	".aac":  true,
	".ogg":  true,
	".opus": true,
}

var ingestDirCmd = &cobra.Command{
	Use:   "ingest-dir [directory]",
	Short: "Batch ingest all audio files in a directory",
	Long: `Scans a directory for audio files and ingests each one into the archive.
Files already in the archive are silently skipped, so re-running is safe.

Supported formats: wav, mp3, m4a, flac, aiff, aac, ogg, opus

Use --run to also enqueue prep/transcribe/summarize jobs for each ingested
recording. This requires a running worker (archive worker).`,
	Args: cobra.ExactArgs(1),
	RunE: runIngestDir,
}

func init() {
	ingestDirCmd.Flags().BoolVarP(&batchRecursive, "recursive", "r", false, "descend into subdirectories")
	ingestDirCmd.Flags().StringVar(&batchSpeaker, "speaker", "", "speaker name to apply to all recordings")
	ingestDirCmd.Flags().StringVar(&batchDate, "date", "", "recording date for all files (YYYY-MM-DD; default: today)")
	ingestDirCmd.Flags().BoolVar(&batchRun, "run", false, "enqueue prep/transcribe/summarize jobs after each ingest")
	ingestDirCmd.Flags().BoolVar(&batchDryRun, "dry-run", false, "show what would be ingested without actually doing it")
	RootCmd.AddCommand(ingestDirCmd)
}

func runIngestDir(cmd *cobra.Command, args []string) error {
	dirPath := args[0]

	info, err := os.Stat(dirPath)
	if err != nil {
		return fmt.Errorf("cannot access path: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("not a directory: %s", dirPath)
	}

	// Discover audio files
	files, err := discoverAudioFiles(dirPath, batchRecursive)
	if err != nil {
		return fmt.Errorf("scanning directory: %w", err)
	}

	if len(files) == 0 {
		fmt.Printf("No audio files found in %s\n", dirPath)
		return nil
	}

	fmt.Printf("Found %d audio file(s) in %s\n", len(files), dirPath)
	if batchRecursive {
		fmt.Println("  (recursive mode)")
	}
	if batchDryRun {
		fmt.Println("\nDRY RUN — no files will be ingested:")
		for i, f := range files {
			rel, _ := filepath.Rel(dirPath, f)
			fmt.Printf("  [%d] %s\n", i+1, rel)
		}
		return nil
	}

	// Open DB once and reuse
	cfg := config.Default()
	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	ctx := context.Background()
	startTime := time.Now()

	var (
		ingested int
		skipped  int
		failed   int
		enqueued int
	)

	for i, file := range files {
		rel, _ := filepath.Rel(dirPath, file)
		fmt.Printf("[%d/%d] %s ", i+1, len(files), rel)

		result, err := pipeline.IngestFile(ctx, cfg, db, pipeline.IngestOptions{
			SourcePath: file,
			Speaker:    batchSpeaker,
			Date:       batchDate,
			Title:      "", // use filename-derived slug
		})
		if err != nil {
			fmt.Printf("FAILED: %v\n", err)
			failed++
			continue
		}

		if result.Skipped {
			fmt.Printf("skipped (id=%d)\n", result.RecordingID)
			skipped++
		} else {
			dur := ""
			if result.Meta != nil && result.Meta.DurationMs > 0 {
				dur = fmt.Sprintf(" [%s]", formatDuration(result.Meta.DurationMs))
			}
			fmt.Printf("ingested (id=%d)%s\n", result.RecordingID, dur)
			ingested++
		}

		// Optionally enqueue pipeline jobs for this recording
		if batchRun {
			for _, jt := range []store.JobType{store.JobPrep, store.JobTranscribe, store.JobSummarize} {
				if _, err := db.EnqueueJob(result.RecordingID, jt); err != nil {
					fmt.Printf("  enqueue %s failed: %v\n", jt, err)
				} else {
					enqueued++
				}
			}
		}
	}

	elapsed := time.Since(startTime).Round(time.Millisecond)

	fmt.Println()
	fmt.Printf("Batch complete in %s\n", elapsed)
	fmt.Printf("  Ingested: %d\n", ingested)
	fmt.Printf("  Skipped:  %d\n", skipped)
	if failed > 0 {
		fmt.Printf("  Failed:   %d\n", failed)
	}
	if batchRun && enqueued > 0 {
		fmt.Printf("  Enqueued: %d jobs\n", enqueued)
		fmt.Println("  Start a worker to process them: archive worker")
	}

	if failed > 0 {
		return fmt.Errorf("%d file(s) failed to ingest", failed)
	}
	return nil
}

// discoverAudioFiles walks a directory and returns all audio files found,
// sorted by path. If recursive is false, only the top-level directory is
// scanned (subdirectories are skipped).
func discoverAudioFiles(root string, recursive bool) ([]string, error) {
	var files []string

	walkFn := func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		// Skip subdirectories if not recursive
		if d.IsDir() {
			if path == root {
				return nil
			}
			if !recursive {
				return fs.SkipDir
			}
			return nil
		}

		// Skip hidden files (macOS metadata junk like ._filename)
		base := filepath.Base(path)
		if strings.HasPrefix(base, ".") {
			return nil
		}

		ext := strings.ToLower(filepath.Ext(path))
		if audioExtensions[ext] {
			files = append(files, path)
		}
		return nil
	}

	if err := filepath.WalkDir(root, walkFn); err != nil {
		return nil, err
	}

	sort.Strings(files)
	return files, nil
}

