package cli

import (
	"github.com/spf13/cobra"
)

var RootCmd = &cobra.Command{
	Use:   "archive",
	Short: "Audio archive — ingest, prep, transcribe, and search recordings",
}
