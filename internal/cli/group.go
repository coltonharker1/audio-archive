package cli

import (
	"fmt"
	"strconv"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
	"github.com/spf13/cobra"
)

var groupTitle string

var groupCmd = &cobra.Command{
	Use:   "group [id...] --title <name>",
	Short: "Group recordings as tracks of a single tape/reel",
	Long: `Assign multiple recordings to a group so they sync to remanence-archive
as a single sound with multiple tracks.

Example:
  archive group 2 4 5 --title "Accordion Performances"`,
	Args: cobra.MinimumNArgs(2),
	RunE: runGroup,
}

func init() {
	groupCmd.Flags().StringVar(&groupTitle, "title", "", "group title (required)")
	groupCmd.MarkFlagRequired("title")
	RootCmd.AddCommand(groupCmd)
}

func runGroup(cmd *cobra.Command, args []string) error {
	cfg := config.Default()
	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer db.Close()

	// Parse recording IDs
	var ids []int64
	for _, arg := range args {
		id, err := strconv.ParseInt(arg, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid recording ID: %s", arg)
		}
		ids = append(ids, id)
	}

	// Verify all recordings exist
	for _, id := range ids {
		if _, err := db.GetRecording(id); err != nil {
			return fmt.Errorf("recording %d not found: %w", id, err)
		}
	}

	groupID := store.NewGroupID()

	for _, id := range ids {
		if err := db.SetGroup(id, groupID, groupTitle); err != nil {
			return fmt.Errorf("setting group for recording %d: %w", id, err)
		}
	}

	fmt.Printf("Grouped %d recordings as %q (group_id: %s)\n", len(ids), groupTitle, groupID)
	for _, id := range ids {
		rec, _ := db.GetRecording(id)
		title := rec.Title
		if title == "" {
			title = rec.Slug
		}
		fmt.Printf("  [%d] %s\n", id, title)
	}

	return nil
}
