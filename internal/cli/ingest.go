package cli

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
	"github.com/spf13/cobra"
)

var (
	ingestSpeaker string
	ingestDate    string
	ingestTitle   string
)

var ingestCmd = &cobra.Command{
	Use:   "ingest [file]",
	Short: "Ingest a recording into the archive",
	Long:  "Copies the audio file to the masters directory, extracts metadata, and creates a database record.",
	Args:  cobra.ExactArgs(1),
	RunE:  runIngest,
}

func init() {
	ingestCmd.Flags().StringVar(&ingestSpeaker, "speaker", "", "speaker name")
	ingestCmd.Flags().StringVar(&ingestDate, "date", "", "recording date (YYYY-MM-DD)")
	ingestCmd.Flags().StringVar(&ingestTitle, "title", "", "recording title or description")
	RootCmd.AddCommand(ingestCmd)
}

func runIngest(cmd *cobra.Command, args []string) error {
	inputPath := args[0]
	cfg := config.Default()

	// Verify source file exists
	if _, err := os.Stat(inputPath); err != nil {
		return fmt.Errorf("source file not found: %w", err)
	}

	// Ensure data directories exist
	if err := cfg.EnsureDirs(); err != nil {
		return fmt.Errorf("creating data dirs: %w", err)
	}

	// Default date to today if not provided
	if ingestDate == "" {
		ingestDate = time.Now().Format("2006-01-02")
	}

	// Build the archive filename
	slug := buildSlug(inputPath, ingestTitle)
	archiveName := buildArchiveName(ingestDate, slug, ingestSpeaker, filepath.Ext(inputPath))

	// Determine year subdirectory
	year := ingestDate[:4]
	destDir := filepath.Join(cfg.MastersDir(), year)
	if err := os.MkdirAll(destDir, 0755); err != nil {
		return fmt.Errorf("creating year dir: %w", err)
	}

	destPath := filepath.Join(destDir, archiveName)

	// Check if destination already exists
	if _, err := os.Stat(destPath); err == nil {
		return fmt.Errorf("file already exists in archive: %s", destPath)
	}

	// Copy file to masters
	if err := copyFile(inputPath, destPath); err != nil {
		return fmt.Errorf("copying to masters: %w", err)
	}

	slog.Info("copied to masters", "path", destPath)

	// Extract metadata via ffprobe
	ctx := context.Background()
	meta, err := audio.Probe(ctx, cfg.Ffprobe, destPath)
	if err != nil {
		slog.Warn("ffprobe failed, continuing without metadata", "error", err)
	} else {
		slog.Info("audio metadata",
			"duration_ms", meta.DurationMs,
			"sample_rate", meta.SampleRate,
			"channels", meta.Channels,
			"format", meta.Format,
		)
	}

	// Store path relative to data dir for portability
	relPath, _ := filepath.Rel(cfg.DataDir, destPath)

	// Open database and insert recording
	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	rec := &model.Recording{
		Slug:       slug,
		Date:       ingestDate,
		Speaker:    ingestSpeaker,
		Title:      ingestTitle,
		MasterPath: relPath,
	}
	if meta != nil {
		rec.DurationMs = meta.DurationMs
		rec.SampleRate = meta.SampleRate
		rec.Channels = meta.Channels
	}

	id, err := db.CreateRecording(rec)
	if err != nil {
		return fmt.Errorf("saving to database: %w", err)
	}

	fmt.Printf("Ingested: %s (id=%d)\n", destPath, id)
	if meta != nil {
		durationSec := float64(meta.DurationMs) / 1000
		minutes := int(durationSec) / 60
		seconds := int(durationSec) % 60
		fmt.Printf("Duration: %d:%02d | Sample Rate: %d Hz | Channels: %d\n",
			minutes, seconds, meta.SampleRate, meta.Channels)
	}

	return nil
}

// buildSlug creates a URL-safe slug from the title or filename.
func buildSlug(filePath, title string) string {
	source := title
	if source == "" {
		// Use filename without extension
		source = strings.TrimSuffix(filepath.Base(filePath), filepath.Ext(filePath))
	}
	slug := strings.ToLower(source)
	slug = strings.ReplaceAll(slug, " ", "-")
	// Remove anything that isn't alphanumeric or hyphen
	var clean strings.Builder
	for _, r := range slug {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			clean.WriteRune(r)
		}
	}
	return clean.String()
}

// buildArchiveName creates the standard archive filename.
// Format: {date}_{slug}_{speaker}.{ext}
func buildArchiveName(date, slug, speaker, ext string) string {
	parts := []string{date}
	if slug != "" {
		parts = append(parts, slug)
	}
	if speaker != "" {
		parts = append(parts, buildSlug("", speaker))
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
