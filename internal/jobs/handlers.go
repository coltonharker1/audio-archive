package jobs

import (
	"context"

	"github.com/colton/audio-archive/internal/config"
	"github.com/colton/audio-archive/internal/pipeline"
	"github.com/colton/audio-archive/internal/store"
)

// RegisterDefaultHandlers wires up prep, transcribe, and summarize handlers
// using the pipeline package. This is what the worker command calls.
func RegisterDefaultHandlers(m *Manager, cfg config.Config, db *store.DB) {
	m.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		_, err := pipeline.PrepRecording(ctx, cfg, db, job.RecordingID)
		return err
	})

	m.Register(store.JobTranscribe, func(ctx context.Context, job store.Job) error {
		_, err := pipeline.TranscribeRecording(ctx, cfg, db, job.RecordingID)
		return err
	})

	m.Register(store.JobSummarize, func(ctx context.Context, job store.Job) error {
		_, err := pipeline.SummarizeRecording(ctx, cfg, db, job.RecordingID)
		return err
	})
}
