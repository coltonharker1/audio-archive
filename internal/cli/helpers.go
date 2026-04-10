package cli

import (
	"fmt"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/store"
)

func getConfig() config.Config {
	return config.Default()
}

func openDB(cfg config.Config) (*store.DB, error) {
	db, err := store.Open(cfg.DBPath)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}
	return db, nil
}
