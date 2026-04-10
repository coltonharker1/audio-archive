package jobs

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/colton/audio-archive/internal/store"
)

// Handler executes a single job. It should respect context cancellation
// and return an error if the job fails; returning nil marks it complete.
type Handler func(ctx context.Context, job store.Job) error

// Manager runs a pool of goroutines that consume jobs from the SQLite queue.
//
// Architecture:
//
//	Dispatcher goroutine:
//	  Polls the DB every pollInterval for pending jobs.
//	  Claims jobs atomically and pushes them onto the jobs channel.
//
//	Worker goroutines (pool size = concurrency):
//	  Read from the jobs channel.
//	  Look up the handler for the job type.
//	  Run it with a bounded context.
//	  Update DB state based on result (complete / retry / failed).
//
//	Shutdown:
//	  When the parent context is canceled, the dispatcher stops polling
//	  and closes the jobs channel. Workers drain remaining jobs and exit.
//	  A WaitGroup ensures Run() doesn't return until all workers are done.
type Manager struct {
	db           *store.DB
	handlers     map[store.JobType]Handler
	pollInterval time.Duration
}

// NewManager creates a manager without any registered handlers.
// Register handlers with Register before calling Run.
func NewManager(db *store.DB) *Manager {
	return &Manager{
		db:           db,
		handlers:     make(map[store.JobType]Handler),
		pollInterval: 2 * time.Second,
	}
}

// SetPollInterval overrides the dispatcher's poll frequency. Useful for
// tests that need faster job discovery.
func (m *Manager) SetPollInterval(d time.Duration) {
	m.pollInterval = d
}

// Register associates a job type with a handler function.
// Only one handler may be registered per type.
func (m *Manager) Register(jobType store.JobType, handler Handler) {
	m.handlers[jobType] = handler
}

// Run starts the worker pool and dispatcher, blocking until ctx is canceled.
// concurrency is the number of worker goroutines (must be >= 1).
//
// On startup, it resets any jobs that were left in 'running' state by a
// previous crash, so they get retried.
func (m *Manager) Run(ctx context.Context, concurrency int) error {
	if concurrency < 1 {
		return errors.New("concurrency must be >= 1")
	}
	if len(m.handlers) == 0 {
		return errors.New("no handlers registered")
	}

	// Crash recovery: any running jobs from a previous process are stale
	if n, err := m.db.ResetStuckJobs(); err != nil {
		return fmt.Errorf("crash recovery: %w", err)
	} else if n > 0 {
		slog.Warn("reset stuck jobs from previous run", "count", n)
	}

	// Buffered channel — small buffer so dispatcher doesn't get too far
	// ahead of workers. Channel closing signals workers to drain and exit.
	jobQueue := make(chan store.Job, concurrency*2)

	// Worker pool
	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go m.worker(ctx, i+1, jobQueue, &wg)
	}

	slog.Info("job manager started",
		"workers", concurrency,
		"poll_interval", m.pollInterval,
		"handlers", len(m.handlers))

	// Dispatcher — runs in this goroutine (Run blocks on it)
	m.dispatcher(ctx, jobQueue)

	// Once dispatcher returns, the channel is closed; wait for workers to drain
	wg.Wait()
	slog.Info("job manager stopped")
	return nil
}

// dispatcher polls the DB for pending jobs and pushes them to the channel.
// Exits (closing the channel) when ctx is canceled.
func (m *Manager) dispatcher(ctx context.Context, out chan<- store.Job) {
	defer close(out)

	ticker := time.NewTicker(m.pollInterval)
	defer ticker.Stop()

	// Tick once immediately so the worker doesn't wait pollInterval on start
	tick := make(chan struct{}, 1)
	tick <- struct{}{}

	for {
		select {
		case <-ctx.Done():
			slog.Info("dispatcher stopping")
			return

		case <-tick:
			m.drainPending(ctx, out)

		case <-ticker.C:
			m.drainPending(ctx, out)
		}
	}
}

// drainPending claims all currently-ready jobs and pushes them onto the queue.
// It stops claiming as soon as ClaimNextPendingJob returns ErrNoJob, or when
// the context is canceled.
func (m *Manager) drainPending(ctx context.Context, out chan<- store.Job) {
	for {
		if ctx.Err() != nil {
			return
		}

		job, err := m.db.ClaimNextPendingJob()
		if err == store.ErrNoJob {
			return
		}
		if err != nil {
			slog.Error("claiming next job", "error", err)
			return
		}

		slog.Info("claimed job",
			"id", job.ID,
			"type", job.Type,
			"recording", job.RecordingID,
			"attempt", job.Attempt)

		// Blocking send — if channel is full, dispatcher waits for a worker
		// to make room. Also respects cancellation.
		select {
		case out <- *job:
		case <-ctx.Done():
			// Roll back the claim so this job gets picked up by a future worker
			if rbErr := m.db.MarkJobPendingRetry(job.ID, "dispatcher canceled"); rbErr != nil {
				slog.Error("rolling back claimed job", "id", job.ID, "error", rbErr)
			}
			return
		}
	}
}

// worker consumes jobs from the channel and runs their handlers.
func (m *Manager) worker(ctx context.Context, id int, jobs <-chan store.Job, wg *sync.WaitGroup) {
	defer wg.Done()

	slog.Info("worker started", "worker_id", id)
	defer slog.Info("worker stopped", "worker_id", id)

	for job := range jobs {
		m.executeJob(ctx, id, job)
	}
}

// executeJob runs a single job and updates its DB state based on the outcome.
func (m *Manager) executeJob(ctx context.Context, workerID int, job store.Job) {
	handler, ok := m.handlers[job.Type]
	if !ok {
		err := fmt.Errorf("no handler for job type %q", job.Type)
		slog.Error("unhandled job type", "worker", workerID, "job", job.ID, "type", job.Type)
		m.db.MarkJobFailed(job.ID, err.Error())
		return
	}

	slog.Info("executing job",
		"worker", workerID,
		"job", job.ID,
		"type", job.Type,
		"attempt", job.Attempt,
		"max_retries", job.MaxRetries)

	// Record the actual execution start time, distinct from the claim time.
	if err := m.db.MarkJobStarted(job.ID); err != nil {
		slog.Warn("failed to mark job started", "job", job.ID, "error", err)
	}

	start := time.Now()
	err := handler(ctx, job)
	elapsed := time.Since(start).Round(time.Millisecond)

	if err == nil {
		slog.Info("job complete",
			"worker", workerID,
			"job", job.ID,
			"type", job.Type,
			"duration", elapsed)
		if dbErr := m.db.MarkJobComplete(job.ID); dbErr != nil {
			slog.Error("marking job complete", "job", job.ID, "error", dbErr)
		}
		return
	}

	// Handler failed. Decide whether to retry or give up.
	if job.Attempt < job.MaxRetries {
		slog.Warn("job failed, scheduling retry",
			"worker", workerID,
			"job", job.ID,
			"type", job.Type,
			"attempt", job.Attempt,
			"max_retries", job.MaxRetries,
			"error", err)
		if dbErr := m.db.MarkJobPendingRetry(job.ID, err.Error()); dbErr != nil {
			slog.Error("marking job for retry", "job", job.ID, "error", dbErr)
		}
		return
	}

	slog.Error("job failed permanently",
		"worker", workerID,
		"job", job.ID,
		"type", job.Type,
		"attempts", job.Attempt,
		"error", err)
	if dbErr := m.db.MarkJobFailed(job.ID, err.Error()); dbErr != nil {
		slog.Error("marking job failed", "job", job.ID, "error", dbErr)
	}
}
