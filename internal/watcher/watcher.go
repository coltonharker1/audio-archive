// Package watcher monitors a directory for new audio files and ingests them
// automatically into the archive. It combines real-time fsnotify events with
// a periodic sweep as a safety net, and waits for files to be "stable" (size
// unchanged for a configurable delay) before ingesting so partial uploads or
// in-progress copies aren't processed prematurely.
package watcher

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/pipeline"
	"github.com/colton/audio-archive/internal/store"
	"github.com/fsnotify/fsnotify"
)

// Options configures a Watcher.
type Options struct {
	// Dir is the directory to watch for new audio files.
	Dir string

	// PollInterval is how often the fallback sweep runs, as a backup for any
	// events fsnotify might miss. Default: 60s.
	PollInterval time.Duration

	// StableDelay is how long a file's size must remain unchanged before it
	// is considered ready to ingest. Prevents ingesting partial copies.
	// Default: 3s.
	StableDelay time.Duration

	// CheckInterval is how often pending files are re-checked for stability.
	// Default: 1s.
	CheckInterval time.Duration

	// DefaultSpeaker is applied to all ingested files unless overridden.
	DefaultSpeaker string

	// EnqueueJobs, if true, adds prep/transcribe/summarize jobs after each
	// successful ingest so a running worker can process them.
	EnqueueJobs bool
}

// Watcher owns the fsnotify subscription, the pending-file map, and the
// coordination loops that turn file events into pipeline work.
type Watcher struct {
	opts Options
	cfg  config.Config
	db   *store.DB
	fs   *fsnotify.Watcher

	// pending tracks files that have been seen but are not yet stable enough
	// to ingest. The map key is the absolute file path.
	//
	// processed tracks files the watcher has already ingested (or skipped as
	// duplicates). On subsequent sweeps we don't re-track these — otherwise
	// every sweep would re-discover already-archived files and produce log
	// noise. This set is in-memory only and resets on watcher restart; that's
	// fine because pipeline.IngestFile is idempotent anyway.
	mu        sync.Mutex
	pending   map[string]*pendingFile
	processed map[string]bool
}

// pendingFile represents a file that the watcher has noticed but not yet
// ingested. It's removed from the map once it's ingested (or disappears).
type pendingFile struct {
	path      string
	size      int64
	sizeSince time.Time // when we last observed this size
	firstSeen time.Time
}

// New constructs a Watcher bound to a directory. The directory must exist.
// Run must be called to actually start watching.
func New(cfg config.Config, db *store.DB, opts Options) (*Watcher, error) {
	if opts.Dir == "" {
		return nil, fmt.Errorf("watcher: Dir is required")
	}
	if opts.PollInterval == 0 {
		opts.PollInterval = 60 * time.Second
	}
	if opts.StableDelay == 0 {
		opts.StableDelay = 3 * time.Second
	}
	if opts.CheckInterval == 0 {
		opts.CheckInterval = 1 * time.Second
	}

	absDir, err := filepath.Abs(opts.Dir)
	if err != nil {
		return nil, fmt.Errorf("watcher: resolving dir: %w", err)
	}
	opts.Dir = absDir

	info, err := os.Stat(opts.Dir)
	if err != nil {
		return nil, fmt.Errorf("watcher: directory: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("watcher: %s is not a directory", opts.Dir)
	}

	fs, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("watcher: creating fsnotify watcher: %w", err)
	}

	return &Watcher{
		opts:      opts,
		cfg:       cfg,
		db:        db,
		fs:        fs,
		pending:   make(map[string]*pendingFile),
		processed: make(map[string]bool),
	}, nil
}

// Run starts the watcher and blocks until ctx is canceled. On return, the
// underlying fsnotify watcher is closed automatically.
//
// The run loop handles three sources of activity:
//   - fsnotify events (file created/written)
//   - checkTicker (re-check pending files for stability)
//   - sweepTicker (periodic scan of the directory as a fsnotify backup)
//
// On startup, an initial sweep catches any files already present in the
// directory when the watcher started.
func (w *Watcher) Run(ctx context.Context) error {
	defer w.fs.Close()

	if err := w.fs.Add(w.opts.Dir); err != nil {
		return fmt.Errorf("watcher: adding watch: %w", err)
	}

	slog.Info("watcher started",
		"dir", w.opts.Dir,
		"poll_interval", w.opts.PollInterval,
		"stable_delay", w.opts.StableDelay,
		"enqueue_jobs", w.opts.EnqueueJobs,
	)

	// Initial sweep to pick up anything already present in the directory
	w.sweep()

	checkTicker := time.NewTicker(w.opts.CheckInterval)
	defer checkTicker.Stop()

	sweepTicker := time.NewTicker(w.opts.PollInterval)
	defer sweepTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("watcher stopping")
			return nil

		case event, ok := <-w.fs.Events:
			if !ok {
				return nil
			}
			w.handleEvent(event)

		case err, ok := <-w.fs.Errors:
			if !ok {
				return nil
			}
			slog.Error("fsnotify error", "error", err)

		case <-checkTicker.C:
			w.checkPending()

		case <-sweepTicker.C:
			w.sweep()
		}
	}
}

// handleEvent processes a single fsnotify event. We care about Create and
// Write events for audio files; everything else is ignored.
func (w *Watcher) handleEvent(e fsnotify.Event) {
	if e.Op&(fsnotify.Create|fsnotify.Write) == 0 {
		return
	}

	if isHiddenOrTemp(e.Name) {
		return
	}
	if !isAudioFile(e.Name) {
		return
	}

	w.trackFile(e.Name)
}

// sweep scans the watched directory for audio files and adds any it finds
// to the pending map. This is the backup path — fsnotify should catch most
// files first, but sweep covers:
//   - files present at startup, before Run was called
//   - events fsnotify might have missed
//   - files that were added while fsnotify was rate-limited or buffered
func (w *Watcher) sweep() {
	entries, err := os.ReadDir(w.opts.Dir)
	if err != nil {
		slog.Error("sweep read failed", "error", err)
		return
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if isHiddenOrTemp(name) {
			continue
		}
		path := filepath.Join(w.opts.Dir, name)
		if !isAudioFile(path) {
			continue
		}
		w.trackFile(path)
	}
}

// trackFile adds or updates a file in the pending map. If the file is new,
// it's added with the current size and timestamp. If the file is already
// tracked and its size has changed, the size and timestamp are updated —
// this resets the stability clock so we wait for the new size to hold.
//
// Files that have already been processed in this watcher session are
// silently ignored to avoid re-triggering the pipeline on them.
func (w *Watcher) trackFile(path string) {
	info, err := os.Stat(path)
	if err != nil {
		// File disappeared between the event and the stat — ignore.
		return
	}

	w.mu.Lock()
	defer w.mu.Unlock()

	if w.processed[path] {
		return
	}

	existing, found := w.pending[path]
	now := time.Now()

	if !found {
		w.pending[path] = &pendingFile{
			path:      path,
			size:      info.Size(),
			sizeSince: now,
			firstSeen: now,
		}
		slog.Info("tracking new file",
			"file", filepath.Base(path),
			"size_bytes", info.Size())
		return
	}

	if existing.size != info.Size() {
		existing.size = info.Size()
		existing.sizeSince = now
	}
}

// checkPending looks at every file in the pending map and ingests any that
// have been stable (size unchanged) for at least StableDelay. Ingested
// files are removed from the map. Files that have grown since last check
// have their stability timer reset. Zero-byte files are never considered
// stable — a real audio file is never zero bytes, and some tools (including
// macOS `say` and Finder's copy) create the target file at size 0 before
// streaming the content in.
func (w *Watcher) checkPending() {
	w.mu.Lock()
	var ready []string
	now := time.Now()

	for path, pf := range w.pending {
		if now.Sub(pf.sizeSince) < w.opts.StableDelay {
			continue
		}

		// Re-stat before declaring stable, in case the file changed
		// since the last trackFile call.
		info, err := os.Stat(path)
		if err != nil {
			// Disappeared — drop from pending.
			delete(w.pending, path)
			continue
		}

		// Never declare a zero-byte file stable. Some tools (macOS `say`,
		// Finder copy) create the destination at 0 bytes and stream data
		// in afterward, which would otherwise be "stable at 0" and ingested
		// as an empty file. Keep waiting for content.
		if info.Size() == 0 {
			continue
		}

		if info.Size() != pf.size {
			pf.size = info.Size()
			pf.sizeSince = now
			continue
		}

		ready = append(ready, path)
		delete(w.pending, path)
	}
	w.mu.Unlock()

	for _, path := range ready {
		w.processFile(path)
	}
}

// processFile ingests a single file via the pipeline package and, if
// EnqueueJobs is true, queues prep/transcribe/summarize jobs for a worker
// to process later. Errors are logged but don't stop the watcher.
//
// Successfully-ingested (or already-ingested) paths are added to the
// processed set so subsequent sweeps don't re-discover them.
func (w *Watcher) processFile(path string) {
	slog.Info("processing file", "file", filepath.Base(path))

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	result, err := pipeline.IngestFile(ctx, w.cfg, w.db, pipeline.IngestOptions{
		SourcePath: path,
		Speaker:    w.opts.DefaultSpeaker,
	})
	if err != nil {
		slog.Error("ingest failed", "file", filepath.Base(path), "error", err)
		return
	}

	// Mark as processed regardless of whether it was a fresh ingest or a
	// skip — either way, we shouldn't re-trigger on it in this session.
	w.mu.Lock()
	w.processed[path] = true
	w.mu.Unlock()

	if result.Skipped {
		slog.Info("skipped — already in archive",
			"file", filepath.Base(path),
			"recording_id", result.RecordingID)
		return
	}

	slog.Info("ingested",
		"file", filepath.Base(path),
		"recording_id", result.RecordingID,
		"archive_path", result.ArchivePath)

	if !w.opts.EnqueueJobs {
		return
	}

	jobTypes := []store.JobType{store.JobPrep, store.JobTranscribe, store.JobSummarize}
	for _, jt := range jobTypes {
		if _, err := w.db.EnqueueJob(result.RecordingID, jt); err != nil {
			slog.Error("enqueue failed",
				"recording_id", result.RecordingID,
				"type", jt,
				"error", err)
			continue
		}
		slog.Info("enqueued job",
			"recording_id", result.RecordingID,
			"type", jt)
	}
}

// ---- File filtering ----

// audioExts lists extensions we treat as audio files. Case-insensitive.
var audioExts = map[string]bool{
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

func isAudioFile(path string) bool {
	return audioExts[strings.ToLower(filepath.Ext(path))]
}

func isHiddenOrTemp(path string) bool {
	base := filepath.Base(path)
	if strings.HasPrefix(base, ".") {
		return true
	}
	if strings.HasSuffix(base, ".tmp") || strings.HasSuffix(base, "~") {
		return true
	}
	// Common in-progress transfer suffixes (e.g., rsync, Finder copy-in-place)
	if strings.HasSuffix(base, ".part") || strings.HasSuffix(base, ".crdownload") {
		return true
	}
	return false
}
