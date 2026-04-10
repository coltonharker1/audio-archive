package model

import "time"

// Recording represents a single audio recording in the archive.
type Recording struct {
	ID         int64
	Slug       string
	Date       string // ISO 8601 date
	Speaker    string
	Title      string
	Series     string
	MasterPath string // relative to data dir
	PrepPath   string
	DurationMs int64
	SampleRate int
	Channels   int
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

// AudioMeta holds metadata extracted from an audio file via ffprobe.
type AudioMeta struct {
	DurationMs int64
	SampleRate int
	Channels   int
	Format     string
	BitRate    int
}
