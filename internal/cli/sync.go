package cli

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	syncpkg "github.com/colton/audio-archive/internal/sync"
	"github.com/spf13/cobra"
)

var (
	syncDryRun  bool
	syncPending bool
	syncURL     string
	syncAPIKey  string
)

var syncCmd = &cobra.Command{
	Use:   "sync [id]",
	Short: "Sync recordings to remanence-archive",
	Long: `Push processed recordings (audio + transcript + metadata) to remanence-archive.

Syncs a single recording by ID, or use --pending to sync all unsynced recordings
that have completed summarization. Grouped recordings (from folder ingest) are
synced as a single sound with multiple tracks.

Requires REMANENCE_URL and REMANENCE_SYNC_KEY environment variables, or use
--url and --key flags.`,
	Args: cobra.MaximumNArgs(1),
	RunE: runSync,
}

func init() {
	syncCmd.Flags().BoolVar(&syncDryRun, "dry-run", false, "show what would be synced without actually syncing")
	syncCmd.Flags().BoolVar(&syncPending, "pending", false, "sync all unsynced recordings with completed summaries")
	syncCmd.Flags().StringVar(&syncURL, "url", "", "remanence-archive base URL (or set REMANENCE_URL)")
	syncCmd.Flags().StringVar(&syncAPIKey, "key", "", "sync API key (or set REMANENCE_SYNC_KEY)")
	RootCmd.AddCommand(syncCmd)
}

func runSync(cmd *cobra.Command, args []string) error {
	if len(args) == 0 && !syncPending {
		return fmt.Errorf("provide a recording ID or use --pending")
	}

	url := syncURL
	if url == "" {
		url = os.Getenv("REMANENCE_URL")
	}
	if url == "" {
		return fmt.Errorf("remanence URL required: use --url or set REMANENCE_URL")
	}

	key := syncAPIKey
	if key == "" {
		key = os.Getenv("REMANENCE_SYNC_KEY")
	}
	if key == "" {
		return fmt.Errorf("sync API key required: use --key or set REMANENCE_SYNC_KEY")
	}

	cfg := config.Default()
	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	client := syncpkg.NewClient(url, key, cfg)

	if syncPending {
		return syncAllPending(db, client, cfg)
	}

	// Single recording by ID
	var id int64
	if _, err := fmt.Sscanf(args[0], "%d", &id); err != nil {
		return fmt.Errorf("invalid recording ID: %s", args[0])
	}

	// Check if this recording is part of a group
	groupID, groupTitle, _ := db.GetRecordingGroup(id)
	if groupID != "" {
		fmt.Printf("Recording %d is part of group %q — syncing entire group.\n", id, groupTitle)
		return syncGroup(db, client, cfg, groupID, groupTitle)
	}

	return syncOne(db, client, cfg, id)
}

// syncAllPending syncs all unsynced recordings, handling groups as units.
func syncAllPending(db *store.DB, client *syncpkg.Client, cfg config.Config) error {
	// First, sync grouped recordings
	groupIDs, err := db.SyncableGroups()
	if err != nil {
		return err
	}
	for _, gid := range groupIDs {
		recs, err := db.GetGroupRecordings(gid)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error loading group %s: %v\n", gid, err)
			continue
		}
		if len(recs) == 0 {
			continue
		}
		groupTitle := ""
		if len(recs) > 0 {
			_, groupTitle, _ = db.GetRecordingGroup(recs[0].ID)
		}
		if err := syncGroup(db, client, cfg, gid, groupTitle); err != nil {
			fmt.Fprintf(os.Stderr, "error syncing group %q: %v\n", groupTitle, err)
		}
	}

	// Then, sync ungrouped recordings
	recs, err := db.SyncableRecordings()
	if err != nil {
		return err
	}

	// Filter out any that are in groups (already handled above)
	var ungrouped []int64
	for _, r := range recs {
		gid, _, _ := db.GetRecordingGroup(r.ID)
		if gid == "" {
			ungrouped = append(ungrouped, r.ID)
		}
	}

	if len(groupIDs) == 0 && len(ungrouped) == 0 {
		fmt.Println("No unsynced recordings with completed summaries.")
		return nil
	}

	if len(ungrouped) > 0 {
		fmt.Printf("Found %d ungrouped recording(s) to sync.\n", len(ungrouped))
	}

	for _, id := range ungrouped {
		if err := syncOne(db, client, cfg, id); err != nil {
			fmt.Fprintf(os.Stderr, "error syncing recording %d: %v\n", id, err)
		}
	}

	return nil
}

// syncGroup syncs all recordings in a group as a single RA sound with multiple tracks.
func syncGroup(db *store.DB, client *syncpkg.Client, cfg config.Config, groupID, groupTitle string) error {
	recs, err := db.GetGroupRecordings(groupID)
	if err != nil {
		return err
	}

	fmt.Printf("\nSyncing group %q (%d recordings)\n", groupTitle, len(recs))

	var members []syncpkg.GroupMember
	for _, rec := range recs {
		r := rec // copy
		full, err := db.GetRecording(r.ID)
		if err != nil {
			return fmt.Errorf("getting recording %d: %w", r.ID, err)
		}

		summary, err := db.GetSummary(r.ID)
		if err == sql.ErrNoRows {
			fmt.Printf("  recording %d (%s) has no summary — skipping from group\n", r.ID, r.Slug)
			continue
		}
		if err != nil {
			return fmt.Errorf("getting summary for %d: %w", r.ID, err)
		}

		transcript, _ := db.GetTranscript(r.ID)

		title := full.Title
		if title == "" && summary != nil {
			title = summary.SuggestedTitle
		}
		if title == "" {
			title = full.Slug
		}
		fmt.Printf("  track: %s [%s]\n", title, formatDuration(full.DurationMs))

		members = append(members, syncpkg.GroupMember{
			Rec:        full,
			Transcript: transcript,
			Summary:    summary,
		})
	}

	if len(members) == 0 {
		return fmt.Errorf("no recordings in group have summaries")
	}

	if syncDryRun {
		fmt.Println("  [dry-run] would sync group to remanence — skipping")
		return nil
	}

	// Check if any member was previously synced (use first member's catalog number)
	existingCatNum, _ := db.GetRemanenceCatalogNumber(recs[0].ID)
	if existingCatNum != "" {
		fmt.Printf("  previously synced as %s — will update\n", existingCatNum)
	}

	result, err := client.SyncGroup(groupTitle, members, existingCatNum)
	if err != nil {
		return err
	}

	// Mark all members as synced
	for _, rec := range recs {
		if err := db.MarkSynced(rec.ID, result.CatalogNumber); err != nil {
			fmt.Fprintf(os.Stderr, "  warning: failed to mark recording %d as synced: %v\n", rec.ID, err)
		}
	}

	action := "updated"
	if result.Created {
		action = "created"
	}
	fmt.Printf("  %s as %s (%d tracks, unpublished draft)\n", action, result.CatalogNumber, len(members))
	return nil
}

func syncOne(db *store.DB, client *syncpkg.Client, cfg config.Config, id int64) error {
	rec, err := db.GetRecording(id)
	if err != nil {
		return fmt.Errorf("recording %d not found: %w", id, err)
	}

	summary, err := db.GetSummary(id)
	if err == sql.ErrNoRows {
		return fmt.Errorf("recording %d has no summary — run 'archive summarize %d' first", id, id)
	}
	if err != nil {
		return fmt.Errorf("getting summary for %d: %w", id, err)
	}

	transcript, err := db.GetTranscript(id)
	if err != nil && err.Error() != fmt.Sprintf("getting transcript: %s", sql.ErrNoRows.Error()) {
		return fmt.Errorf("getting transcript for %d: %w", id, err)
	}

	title := rec.Title
	if title == "" && summary != nil {
		title = summary.SuggestedTitle
	}
	if title == "" {
		title = rec.Slug
	}

	fmt.Printf("\nSyncing recording %d: %s\n", id, title)

	existingCatNum, _ := db.GetRemanenceCatalogNumber(id)
	if existingCatNum != "" {
		fmt.Printf("  previously synced as %s — will update\n", existingCatNum)
	}

	masterPath := filepath.Join(cfg.DataDir, rec.MasterPath)
	if fi, err := os.Stat(masterPath); err == nil {
		fmt.Printf("  master: %s (%d MB)\n", filepath.Base(rec.MasterPath), fi.Size()/(1024*1024))
	}
	if rec.PrepPath != "" {
		prepPath := filepath.Join(cfg.DataDir, rec.PrepPath)
		if fi, err := os.Stat(prepPath); err == nil {
			fmt.Printf("  prep:   %s (%d MB)\n", filepath.Base(rec.PrepPath), fi.Size()/(1024*1024))
		}
	}
	if transcript != nil {
		fmt.Printf("  transcript: ~%d words\n", len(transcript.FullText)/5)
	}
	fmt.Printf("  summary type: %s\n", summary.RecordingType)

	if syncDryRun {
		fmt.Println("  [dry-run] would sync to remanence — skipping")
		return nil
	}

	result, err := client.SyncRecording(rec, transcript, summary, existingCatNum)
	if err != nil {
		return err
	}

	if err := db.MarkSynced(id, result.CatalogNumber); err != nil {
		fmt.Fprintf(os.Stderr, "  warning: synced to remanence but failed to mark locally: %v\n", err)
	}

	action := "updated"
	if result.Created {
		action = "created"
	}
	fmt.Printf("  %s as %s (unpublished draft)\n", action, result.CatalogNumber)
	return nil
}
