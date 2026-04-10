package pipeline

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/colton/audio-archive/internal/audio"
	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/model"
	"github.com/colton/audio-archive/internal/store"
)

// IngestOptions controls how a source file is ingested into the archive.
type IngestOptions struct {
	SourcePath string
	Speaker    string
	Date       string // ISO YYYY-MM-DD; empty = today
	Title      string // if empty, derived from filename
}

// IngestResult describes the outcome of an ingest call.
type IngestResult struct {
	RecordingID int64
	ArchivePath string // absolute path to the master file in the archive
	Skipped     bool   // true if destination already existed
	Meta        *model.AudioMeta
}

// IngestFile copies a source audio file into the archive, extracts metadata,
// and creates a DB record. It is idempotent — if the destination filename
// already exists in the archive, it returns Skipped=true without error.
func IngestFile(ctx context.Context, cfg config.Config, db *store.DB, opts IngestOptions) (*IngestResult, error) {
	// Verify source file exists
	if _, err := os.Stat(opts.SourcePath); err != nil {
		return nil, fmt.Errorf("source file not found: %w", err)
	}

	// Ensure all data directories exist
	if err := cfg.EnsureDirs(); err != nil {
		return nil, fmt.Errorf("creating data dirs: %w", err)
	}

	// Default date to today
	date := opts.Date
	if date == "" {
		date = time.Now().Format("2006-01-02")
	}

	// Build slug and archive filename
	slug := BuildSlug(opts.SourcePath, opts.Title)
	archiveName := BuildArchiveName(date, slug, opts.Speaker, filepath.Ext(opts.SourcePath))

	// Year subdirectory (derived from date)
	year := date[:4]
	destDir := filepath.Join(cfg.MastersDir(), year)
	if err := os.MkdirAll(destDir, 0755); err != nil {
		return nil, fmt.Errorf("creating year dir: %w", err)
	}

	destPath := filepath.Join(destDir, archiveName)

	// Idempotency check
	if _, err := os.Stat(destPath); err == nil {
		// Find the existing DB record if any so caller can act on it
		rel, _ := filepath.Rel(cfg.DataDir, destPath)
		if recID, err := db.GetRecordingIDByMasterPath(rel); err == nil {
			return &IngestResult{RecordingID: recID, ArchivePath: destPath, Skipped: true}, nil
		}
		// File exists on disk but not in DB — unusual, treat as skip anyway
		return &IngestResult{ArchivePath: destPath, Skipped: true}, nil
	}

	// Copy the file, preserving the original
	if err := copyFile(opts.SourcePath, destPath); err != nil {
		return nil, fmt.Errorf("copying to masters: %w", err)
	}
	slog.Info("copied to masters", "path", destPath)

	// Extract audio metadata via ffprobe (best-effort)
	meta, probeErr := audio.Probe(ctx, cfg.Ffprobe, destPath)
	if probeErr != nil {
		slog.Warn("ffprobe failed, continuing without metadata", "error", probeErr)
	}

	// Persist DB record
	relPath, _ := filepath.Rel(cfg.DataDir, destPath)
	rec := &model.Recording{
		Slug:       slug,
		Date:       date,
		Speaker:    opts.Speaker,
		Title:      opts.Title,
		MasterPath: relPath,
	}
	if meta != nil {
		rec.DurationMs = meta.DurationMs
		rec.SampleRate = meta.SampleRate
		rec.Channels = meta.Channels
	}

	id, err := db.CreateRecording(rec)
	if err != nil {
		return nil, fmt.Errorf("saving to database: %w", err)
	}

	return &IngestResult{
		RecordingID: id,
		ArchivePath: destPath,
		Skipped:     false,
		Meta:        meta,
	}, nil
}

// BuildSlug creates a URL-safe slug from the title or filename.
func BuildSlug(filePath, title string) string {
	source := title
	if source == "" {
		source = strings.TrimSuffix(filepath.Base(filePath), filepath.Ext(filePath))
	}
	slug := strings.ToLower(source)
	slug = strings.ReplaceAll(slug, " ", "-")
	slug = strings.ReplaceAll(slug, "_", "-")
	var clean strings.Builder
	for _, r := range slug {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			clean.WriteRune(r)
		}
	}
	// Collapse multiple hyphens and trim
	result := clean.String()
	for strings.Contains(result, "--") {
		result = strings.ReplaceAll(result, "--", "-")
	}
	return strings.Trim(result, "-")
}

// BuildArchiveName creates the standard archive filename.
// Format: {date}_{slug}_{speaker-slug}{ext}
func BuildArchiveName(date, slug, speaker, ext string) string {
	parts := []string{date}
	if slug != "" {
		parts = append(parts, slug)
	}
	if speaker != "" {
		parts = append(parts, BuildSlug("", speaker))
	}
	return strings.Join(parts, "_") + ext
}

// copyFile copies src to dst, preserving the original.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}
