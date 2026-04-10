package jobs

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/colton/audio-archive/internal/model"
	"github.com/colton/audio-archive/internal/store"
)

// testSetup creates a fresh DB + manager wired with fast polling and zero
// backoff, plus a recording to attach jobs to.
func testSetup(t *testing.T) (*store.DB, *Manager, int64) {
	t.Helper()

	dbPath := filepath.Join(t.TempDir(), "test.db")
	db, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	db.SetBackoffSeconds(0) // no backoff in tests

	recID, err := db.CreateRecording(&model.Recording{
		Slug:       "test",
		Date:       "2024-01-01",
		MasterPath: "masters/2024/test.wav",
	})
	if err != nil {
		t.Fatalf("create recording: %v", err)
	}

	mgr := NewManager(db)
	mgr.SetPollInterval(10 * time.Millisecond) // poll fast for tests

	return db, mgr, recID
}

// waitForJob polls the DB until the job reaches the given status or the
// deadline expires. Returns the observed job.
func waitForJob(t *testing.T, db *store.DB, jobID int64, want store.JobStatus, timeout time.Duration) *store.Job {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		jobs, err := db.ListRecentJobs(100)
		if err != nil {
			t.Fatalf("list jobs: %v", err)
		}
		for i := range jobs {
			if jobs[i].ID == jobID && jobs[i].Status == want {
				return &jobs[i]
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("job %d never reached status %s within %s", jobID, want, timeout)
	return nil
}

// runManagerBriefly spins up the manager in a goroutine, waits for the test
// body to finish (signaled by done), then cancels and waits for clean exit.
func runManagerBriefly(t *testing.T, mgr *Manager, concurrency int, body func(ctx context.Context)) {
	t.Helper()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	mgrDone := make(chan error, 1)
	go func() {
		mgrDone <- mgr.Run(ctx, concurrency)
	}()

	body(ctx)

	cancel()
	select {
	case err := <-mgrDone:
		if err != nil {
			t.Errorf("manager returned error: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("manager did not shut down within 5s")
	}
}

// ---- Single-job execution ----

func TestManager_ExecutesSingleJob(t *testing.T) {
	db, mgr, recID := testSetup(t)

	var called int32
	mgr.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		atomic.AddInt32(&called, 1)
		return nil
	})

	jobID, _ := db.EnqueueJob(recID, store.JobPrep)

	runManagerBriefly(t, mgr, 1, func(ctx context.Context) {
		waitForJob(t, db, jobID, store.StatusComplete, 3*time.Second)
	})

	if atomic.LoadInt32(&called) != 1 {
		t.Errorf("handler called %d times, want 1", atomic.LoadInt32(&called))
	}
}

// ---- Multiple jobs processed in order ----

func TestManager_ExecutesMultipleJobs(t *testing.T) {
	db, mgr, recID := testSetup(t)

	var (
		mu    sync.Mutex
		order []int64
	)
	handler := func(ctx context.Context, job store.Job) error {
		mu.Lock()
		order = append(order, job.ID)
		mu.Unlock()
		return nil
	}
	mgr.Register(store.JobPrep, handler)
	mgr.Register(store.JobTranscribe, handler)
	mgr.Register(store.JobSummarize, handler)

	var ids []int64
	for _, jt := range []store.JobType{store.JobPrep, store.JobTranscribe, store.JobSummarize} {
		id, _ := db.EnqueueJob(recID, jt)
		ids = append(ids, id)
	}

	runManagerBriefly(t, mgr, 1, func(ctx context.Context) {
		for _, id := range ids {
			waitForJob(t, db, id, store.StatusComplete, 3*time.Second)
		}
	})

	mu.Lock()
	defer mu.Unlock()
	if len(order) != len(ids) {
		t.Fatalf("processed %d jobs, want %d", len(order), len(ids))
	}
	for i, got := range order {
		if got != ids[i] {
			t.Errorf("order[%d] = %d, want %d", i, got, ids[i])
		}
	}
}

// ---- Retry on handler error ----

func TestManager_RetriesFailedJob(t *testing.T) {
	db, mgr, recID := testSetup(t)

	var attempts int32
	mgr.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		n := atomic.AddInt32(&attempts, 1)
		if n < 3 {
			return errors.New("transient failure")
		}
		return nil
	})

	jobID, _ := db.EnqueueJob(recID, store.JobPrep)

	runManagerBriefly(t, mgr, 1, func(ctx context.Context) {
		job := waitForJob(t, db, jobID, store.StatusComplete, 5*time.Second)
		if job.Attempt != 3 {
			t.Errorf("final attempt = %d, want 3", job.Attempt)
		}
	})

	if atomic.LoadInt32(&attempts) != 3 {
		t.Errorf("handler called %d times, want 3", atomic.LoadInt32(&attempts))
	}
}

// ---- Terminal failure after exhausting retries ----

func TestManager_TerminalFailureAfterMaxRetries(t *testing.T) {
	db, mgr, recID := testSetup(t)

	var attempts int32
	mgr.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		atomic.AddInt32(&attempts, 1)
		return errors.New("permanently broken")
	})

	jobID, _ := db.EnqueueJob(recID, store.JobPrep)

	runManagerBriefly(t, mgr, 1, func(ctx context.Context) {
		job := waitForJob(t, db, jobID, store.StatusFailed, 5*time.Second)
		if job.Error != "permanently broken" {
			t.Errorf("error = %q, want %q", job.Error, "permanently broken")
		}
	})

	// JobPrep defaults to 3 retries
	if got := atomic.LoadInt32(&attempts); got != 3 {
		t.Errorf("handler called %d times, want 3", got)
	}
}

// ---- Unknown job type ----

func TestManager_UnknownJobTypeFailsImmediately(t *testing.T) {
	db, mgr, recID := testSetup(t)

	// Register a placeholder handler so NewManager passes the "no handlers" check,
	// but for a DIFFERENT job type than what we enqueue.
	mgr.Register(store.JobTranscribe, func(ctx context.Context, job store.Job) error {
		return nil
	})

	jobID, _ := db.EnqueueJob(recID, store.JobPrep)

	runManagerBriefly(t, mgr, 1, func(ctx context.Context) {
		job := waitForJob(t, db, jobID, store.StatusFailed, 3*time.Second)
		if job.Error == "" {
			t.Error("expected error message on failure")
		}
	})
}

// ---- Graceful shutdown ----

func TestManager_GracefulShutdownFinishesInFlightJob(t *testing.T) {
	db, mgr, recID := testSetup(t)

	started := make(chan struct{})
	finished := make(chan struct{})
	mgr.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		close(started)
		// Simulate a slow job that ignores context cancellation briefly
		time.Sleep(100 * time.Millisecond)
		close(finished)
		return nil
	})

	jobID, _ := db.EnqueueJob(recID, store.JobPrep)

	ctx, cancel := context.WithCancel(context.Background())
	mgrDone := make(chan error, 1)
	go func() { mgrDone <- mgr.Run(ctx, 1) }()

	// Wait until the job starts, then cancel
	<-started
	cancel()

	// Manager should wait for the in-flight job to finish before returning
	select {
	case <-finished:
		// good — the handler completed before manager exited
	case <-time.After(2 * time.Second):
		t.Fatal("handler did not finish before manager shutdown")
	}

	select {
	case <-mgrDone:
		// clean shutdown
	case <-time.After(2 * time.Second):
		t.Fatal("manager did not return after cancel")
	}

	// Job should be marked complete, not lost
	jobs, _ := db.ListRecentJobs(1)
	if len(jobs) == 0 || jobs[0].ID != jobID || jobs[0].Status != store.StatusComplete {
		t.Errorf("job not completed: %+v", jobs)
	}
}

// ---- Crash recovery ----

func TestManager_ResetsStuckRunningJobsOnStartup(t *testing.T) {
	db, mgr, recID := testSetup(t)

	// Enqueue and claim a job to simulate a stuck running state from a
	// previous crashed worker.
	jobID, _ := db.EnqueueJob(recID, store.JobPrep)
	if _, err := db.ClaimNextPendingJob(); err != nil {
		t.Fatalf("setup claim: %v", err)
	}

	before, _ := db.CountJobs()
	if before.Running != 1 {
		t.Fatalf("setup: running = %d, want 1", before.Running)
	}

	// Register a handler that will complete the recovered job
	mgr.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		return nil
	})

	runManagerBriefly(t, mgr, 1, func(ctx context.Context) {
		// On startup, stuck jobs get reset to pending and reclaimed.
		// Should reach complete after restart cycle.
		waitForJob(t, db, jobID, store.StatusComplete, 3*time.Second)
	})
}

// ---- Concurrent workers, no double-dispatch ----

func TestManager_ConcurrentWorkersNoDoubleDispatch(t *testing.T) {
	db, mgr, recID := testSetup(t)

	const numJobs = 40
	var (
		mu      sync.Mutex
		handled = make(map[int64]int)
	)

	mgr.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		mu.Lock()
		handled[job.ID]++
		mu.Unlock()
		// small work to increase chance of concurrency collisions
		time.Sleep(5 * time.Millisecond)
		return nil
	})

	var jobIDs []int64
	for i := 0; i < numJobs; i++ {
		id, _ := db.EnqueueJob(recID, store.JobPrep)
		jobIDs = append(jobIDs, id)
	}

	runManagerBriefly(t, mgr, 4, func(ctx context.Context) {
		// Wait for all jobs to complete
		for _, id := range jobIDs {
			waitForJob(t, db, id, store.StatusComplete, 10*time.Second)
		}
	})

	mu.Lock()
	defer mu.Unlock()

	if len(handled) != numJobs {
		t.Errorf("handled %d unique jobs, want %d", len(handled), numJobs)
	}
	for id, count := range handled {
		if count != 1 {
			t.Errorf("job %d handled %d times (want 1)", id, count)
		}
	}
}

// ---- Context cancellation reaches the handler ----

func TestManager_HandlerSeesContextCancellation(t *testing.T) {
	db, mgr, recID := testSetup(t)

	handlerCtxDone := make(chan struct{})
	handlerStarted := make(chan struct{})
	mgr.Register(store.JobPrep, func(ctx context.Context, job store.Job) error {
		close(handlerStarted)
		select {
		case <-ctx.Done():
			close(handlerCtxDone)
			return ctx.Err()
		case <-time.After(10 * time.Second):
			return nil
		}
	})

	_, _ = db.EnqueueJob(recID, store.JobPrep)

	ctx, cancel := context.WithCancel(context.Background())
	mgrDone := make(chan error, 1)
	go func() { mgrDone <- mgr.Run(ctx, 1) }()

	<-handlerStarted
	cancel()

	select {
	case <-handlerCtxDone:
		// good — the handler saw the cancellation
	case <-time.After(2 * time.Second):
		t.Fatal("handler context not canceled within 2s")
	}

	<-mgrDone
}

// ---- Configuration errors ----

func TestManager_RunErrorsIfNoHandlers(t *testing.T) {
	_, mgr, _ := testSetup(t)

	err := mgr.Run(context.Background(), 1)
	if err == nil || err.Error() != "no handlers registered" {
		t.Errorf("want 'no handlers registered' error, got %v", err)
	}
}

func TestManager_RunErrorsOnInvalidConcurrency(t *testing.T) {
	_, mgr, _ := testSetup(t)
	mgr.Register(store.JobPrep, func(ctx context.Context, job store.Job) error { return nil })

	if err := mgr.Run(context.Background(), 0); err == nil {
		t.Error("want error for concurrency=0")
	}
}
