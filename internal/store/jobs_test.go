package store

import (
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/colton/audio-archive/internal/model"
)

// newTestDB creates a throwaway SQLite database in t.TempDir().
// It's automatically closed when the test ends.
func newTestDB(t *testing.T) *DB {
	t.Helper()

	dbPath := filepath.Join(t.TempDir(), "test.db")
	db, err := Open(dbPath)
	if err != nil {
		t.Fatalf("opening test db: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	// Short backoff so retry tests don't sleep real seconds.
	db.SetBackoffSeconds(0)

	return db
}

// newTestRecording inserts a minimal recording and returns its ID.
func newTestRecording(t *testing.T, db *DB) int64 {
	t.Helper()
	id, err := db.CreateRecording(&model.Recording{
		Slug:       "test-slug",
		Date:       "2024-01-01",
		MasterPath: "masters/2024/test.wav",
	})
	if err != nil {
		t.Fatalf("creating test recording: %v", err)
	}
	return id
}

// ---- EnqueueJob ----

func TestEnqueueJob_CreatesPendingJob(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)

	jobID, err := db.EnqueueJob(recID, JobPrep)
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if jobID <= 0 {
		t.Errorf("want positive job ID, got %d", jobID)
	}

	counts, err := db.CountJobs()
	if err != nil {
		t.Fatalf("count jobs: %v", err)
	}
	if counts.Pending != 1 {
		t.Errorf("want 1 pending job, got %d", counts.Pending)
	}
}

func TestEnqueueJob_UsesDefaultMaxRetries(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)

	tests := []struct {
		jobType    JobType
		wantRetry  int
	}{
		{JobPrep, 3},
		{JobTranscribe, 2},
		{JobSummarize, 2},
	}

	for _, tc := range tests {
		t.Run(string(tc.jobType), func(t *testing.T) {
			id, err := db.EnqueueJob(recID, tc.jobType)
			if err != nil {
				t.Fatalf("enqueue: %v", err)
			}

			jobs, err := db.ListRecentJobs(100)
			if err != nil {
				t.Fatalf("list: %v", err)
			}

			var got *Job
			for i := range jobs {
				if jobs[i].ID == id {
					got = &jobs[i]
					break
				}
			}
			if got == nil {
				t.Fatalf("job %d not found in list", id)
			}
			if got.MaxRetries != tc.wantRetry {
				t.Errorf("max_retries = %d, want %d", got.MaxRetries, tc.wantRetry)
			}
		})
	}
}

// ---- ClaimNextPendingJob ----

func TestClaimNextPendingJob_Empty(t *testing.T) {
	db := newTestDB(t)

	_, err := db.ClaimNextPendingJob()
	if !errors.Is(err, ErrNoJob) {
		t.Errorf("want ErrNoJob, got %v", err)
	}
}

func TestClaimNextPendingJob_ReturnsOldestFirst(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)
	otherID := newTestRecording(t, db) // independent recording for the second prep

	firstID, _ := db.EnqueueJob(recID, JobPrep)
	// created_at has second-level resolution, so force a delta to avoid ties
	time.Sleep(1100 * time.Millisecond)
	// Second prep is on an *independent* recording so the predecessor filter
	// (which forbids claiming transcribe/summarize while their same-recording
	// predecessor is incomplete) doesn't interfere with this ordering test.
	secondID, _ := db.EnqueueJob(otherID, JobPrep)

	job, err := db.ClaimNextPendingJob()
	if err != nil {
		t.Fatalf("claim: %v", err)
	}
	if job.ID != firstID {
		t.Errorf("want first job (id=%d), got id=%d", firstID, job.ID)
	}
	if job.Status != StatusRunning {
		t.Errorf("status = %s, want running", job.Status)
	}
	if job.Attempt != 1 {
		t.Errorf("attempt = %d, want 1", job.Attempt)
	}

	job2, err := db.ClaimNextPendingJob()
	if err != nil {
		t.Fatalf("claim 2: %v", err)
	}
	if job2.ID != secondID {
		t.Errorf("want second job (id=%d), got id=%d", secondID, job2.ID)
	}
}

func TestClaimNextPendingJob_IsAtomic(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)

	const numJobs = 50
	for i := 0; i < numJobs; i++ {
		if _, err := db.EnqueueJob(recID, JobPrep); err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
	}

	// Claim concurrently from many goroutines — no job should be claimed twice
	var wg sync.WaitGroup
	var mu sync.Mutex
	claimed := make(map[int64]int) // jobID → times claimed

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				job, err := db.ClaimNextPendingJob()
				if errors.Is(err, ErrNoJob) {
					return
				}
				if err != nil {
					t.Errorf("claim error: %v", err)
					return
				}
				mu.Lock()
				claimed[job.ID]++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if len(claimed) != numJobs {
		t.Errorf("claimed %d unique jobs, want %d", len(claimed), numJobs)
	}
	for id, count := range claimed {
		if count != 1 {
			t.Errorf("job %d claimed %d times (want 1)", id, count)
		}
	}
}

func TestClaimNextPendingJob_BackoffRespected(t *testing.T) {
	db := newTestDB(t)
	db.SetBackoffSeconds(5) // 5s * attempt = 5s wait after first failure
	recID := newTestRecording(t, db)

	_, _ = db.EnqueueJob(recID, JobPrep)

	// Initial claim — first attempt, no finished_at, eligible immediately
	job, err := db.ClaimNextPendingJob()
	if err != nil {
		t.Fatalf("initial claim: %v", err)
	}

	// Simulate failure + retry
	if err := db.MarkJobPendingRetry(job.ID, "simulated failure"); err != nil {
		t.Fatalf("mark retry: %v", err)
	}

	// The job should NOT be reclaimable — 5s backoff hasn't elapsed
	_, err = db.ClaimNextPendingJob()
	if !errors.Is(err, ErrNoJob) {
		t.Errorf("expected backoff to block reclaim, got %v", err)
	}
}

func TestClaimNextPendingJob_NoBackoffReclaimsImmediately(t *testing.T) {
	db := newTestDB(t)
	db.SetBackoffSeconds(0) // zero backoff — should reclaim immediately
	recID := newTestRecording(t, db)

	_, _ = db.EnqueueJob(recID, JobPrep)

	job1, _ := db.ClaimNextPendingJob()
	if err := db.MarkJobPendingRetry(job1.ID, "fail"); err != nil {
		t.Fatalf("mark retry: %v", err)
	}

	job2, err := db.ClaimNextPendingJob()
	if err != nil {
		t.Fatalf("reclaim: %v", err)
	}
	if job2.ID != job1.ID {
		t.Errorf("expected same job on reclaim, got %d", job2.ID)
	}
	if job2.Attempt != 2 {
		t.Errorf("attempt = %d, want 2", job2.Attempt)
	}
}

// ---- Mark transitions ----

func TestMarkJobStarted_SetsStartedAt(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)
	jobID, _ := db.EnqueueJob(recID, JobPrep)
	_, _ = db.ClaimNextPendingJob()

	if err := db.MarkJobStarted(jobID); err != nil {
		t.Fatalf("mark started: %v", err)
	}

	jobs, _ := db.ListRecentJobs(1)
	if len(jobs) != 1 || jobs[0].StartedAt == nil {
		t.Error("started_at should be set")
	}
}

func TestMarkJobComplete(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)
	jobID, _ := db.EnqueueJob(recID, JobPrep)
	_, _ = db.ClaimNextPendingJob()

	if err := db.MarkJobComplete(jobID); err != nil {
		t.Fatalf("mark complete: %v", err)
	}

	counts, _ := db.CountJobs()
	if counts.Complete != 1 {
		t.Errorf("complete count = %d, want 1", counts.Complete)
	}
	if counts.Pending != 0 || counts.Running != 0 {
		t.Errorf("stale counts: %+v", counts)
	}
}

func TestMarkJobFailed(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)
	jobID, _ := db.EnqueueJob(recID, JobPrep)
	_, _ = db.ClaimNextPendingJob()

	errMsg := "something went wrong"
	if err := db.MarkJobFailed(jobID, errMsg); err != nil {
		t.Fatalf("mark failed: %v", err)
	}

	jobs, _ := db.ListRecentJobs(1)
	if jobs[0].Status != StatusFailed {
		t.Errorf("status = %s, want failed", jobs[0].Status)
	}
	if jobs[0].Error != errMsg {
		t.Errorf("error = %q, want %q", jobs[0].Error, errMsg)
	}
	if jobs[0].FinishedAt == nil {
		t.Error("finished_at should be set on failure")
	}
}

// ---- Predecessor dependency filter ----

// summarize must NOT be claimed while its transcribe predecessor is still
// pending — the handler would immediately error with "no transcript" and
// burn the retry budget. Reproduces the 2026-04-11 rec-6 cascade.
func TestClaimNextPendingJob_SummarizeBlockedUntilTranscribeComplete(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)

	_, _ = db.EnqueueJob(recID, JobPrep)
	txID, _ := db.EnqueueJob(recID, JobTranscribe)
	_, _ = db.EnqueueJob(recID, JobSummarize)

	// Claim 1: only prep is eligible. Mark it complete.
	j1, err := db.ClaimNextPendingJob()
	if err != nil {
		t.Fatalf("claim prep: %v", err)
	}
	if j1.Type != JobPrep {
		t.Fatalf("claim 1 type = %s, want prep", j1.Type)
	}
	if err := db.MarkJobComplete(j1.ID); err != nil {
		t.Fatalf("mark prep complete: %v", err)
	}

	// Claim 2: now transcribe becomes eligible (prep is complete). But
	// summarize still must not be claimed because transcribe is not yet
	// complete — it's only claimed.
	j2, err := db.ClaimNextPendingJob()
	if err != nil {
		t.Fatalf("claim transcribe: %v", err)
	}
	if j2.Type != JobTranscribe {
		t.Fatalf("claim 2 type = %s, want transcribe", j2.Type)
	}
	if j2.ID != txID {
		t.Fatalf("claim 2 id = %d, want %d", j2.ID, txID)
	}

	// Claim 3: summarize should NOT yet be eligible — transcribe is
	// 'running', not 'complete'.
	_, err = db.ClaimNextPendingJob()
	if !errors.Is(err, ErrNoJob) {
		t.Fatalf("expected ErrNoJob while transcribe is running, got %v", err)
	}

	// Now complete the transcribe. Summarize should become claimable.
	if err := db.MarkJobComplete(j2.ID); err != nil {
		t.Fatalf("mark transcribe complete: %v", err)
	}
	j3, err := db.ClaimNextPendingJob()
	if err != nil {
		t.Fatalf("claim summarize: %v", err)
	}
	if j3.Type != JobSummarize {
		t.Fatalf("claim 3 type = %s, want summarize", j3.Type)
	}
}

// Even when a prep is running (not complete), transcribe for the same
// recording is not claimable. Independent recordings aren't affected.
func TestClaimNextPendingJob_PredecessorFilterIsPerRecording(t *testing.T) {
	db := newTestDB(t)
	recA := newTestRecording(t, db)
	recB := newTestRecording(t, db)

	// Rec A: prep enqueued, will be claimed but not completed.
	_, _ = db.EnqueueJob(recA, JobPrep)
	_, _ = db.EnqueueJob(recA, JobTranscribe)
	// Rec B: independent prep + transcribe.
	_, _ = db.EnqueueJob(recB, JobPrep)

	// Claim rec A prep (goes to running).
	j1, _ := db.ClaimNextPendingJob()
	if j1.RecordingID != recA || j1.Type != JobPrep {
		t.Fatalf("claim 1 = rec=%d type=%s, want recA prep", j1.RecordingID, j1.Type)
	}

	// Claim 2: rec A transcribe is blocked (rec A prep is only running,
	// not complete). Rec B prep should be claimed instead.
	j2, err := db.ClaimNextPendingJob()
	if err != nil {
		t.Fatalf("claim 2: %v", err)
	}
	if j2.RecordingID != recB || j2.Type != JobPrep {
		t.Errorf("claim 2 = rec=%d type=%s, want recB prep", j2.RecordingID, j2.Type)
	}
}

// ---- Cascade failure ----

// When a transcribe job fails terminally, the summarize for the same
// recording should be cascade-failed (not left in pending forever, since
// the predecessor filter would never let it be claimed again).
func TestMarkJobFailed_CascadesToDependents(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)
	otherID := newTestRecording(t, db)

	prepID, _ := db.EnqueueJob(recID, JobPrep)
	txID, _ := db.EnqueueJob(recID, JobTranscribe)
	sumID, _ := db.EnqueueJob(recID, JobSummarize)
	// Jobs on a different recording must NOT be affected by the cascade.
	otherPrepID, _ := db.EnqueueJob(otherID, JobPrep)

	// Mark prep complete so transcribe is meaningful to fail.
	if err := db.MarkJobComplete(prepID); err != nil {
		t.Fatalf("prep complete: %v", err)
	}

	// Terminally fail the transcribe. Should cascade to summarize for
	// the same recording only.
	if err := db.MarkJobFailed(txID, "whisper crashed"); err != nil {
		t.Fatalf("mark tx failed: %v", err)
	}

	jobs, _ := db.ListRecentJobs(100)
	byID := map[int64]Job{}
	for _, j := range jobs {
		byID[j.ID] = j
	}

	if byID[txID].Status != StatusFailed {
		t.Errorf("transcribe status = %s, want failed", byID[txID].Status)
	}
	if byID[sumID].Status != StatusFailed {
		t.Errorf("summarize status = %s, want failed (cascade)", byID[sumID].Status)
	}
	if byID[sumID].Error == "" || byID[sumID].Error == "whisper crashed" {
		t.Errorf("summarize error did not get cascade message: %q", byID[sumID].Error)
	}
	if byID[otherPrepID].Status != StatusPending {
		t.Errorf("independent recording's job was cascaded: status=%s", byID[otherPrepID].Status)
	}
}

// prep failure should cascade to BOTH transcribe and summarize for the
// same recording, since they're both downstream.
func TestMarkJobFailed_PrepCascadesToTranscribeAndSummarize(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)

	prepID, _ := db.EnqueueJob(recID, JobPrep)
	txID, _ := db.EnqueueJob(recID, JobTranscribe)
	sumID, _ := db.EnqueueJob(recID, JobSummarize)

	if err := db.MarkJobFailed(prepID, "ffmpeg died"); err != nil {
		t.Fatalf("mark prep failed: %v", err)
	}

	jobs, _ := db.ListRecentJobs(100)
	byID := map[int64]Job{}
	for _, j := range jobs {
		byID[j.ID] = j
	}
	if byID[txID].Status != StatusFailed {
		t.Errorf("transcribe should be cascaded failed, got %s", byID[txID].Status)
	}
	if byID[sumID].Status != StatusFailed {
		t.Errorf("summarize should be cascaded failed, got %s", byID[sumID].Status)
	}
}

// summarize has no downstream stage; its failure should not affect
// anything else.
func TestMarkJobFailed_SummarizeCascadesToNothing(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)

	prepID, _ := db.EnqueueJob(recID, JobPrep)
	txID, _ := db.EnqueueJob(recID, JobTranscribe)
	sumID, _ := db.EnqueueJob(recID, JobSummarize)

	if err := db.MarkJobFailed(sumID, "ollama unreachable"); err != nil {
		t.Fatalf("mark sum failed: %v", err)
	}

	jobs, _ := db.ListRecentJobs(100)
	byID := map[int64]Job{}
	for _, j := range jobs {
		byID[j.ID] = j
	}
	if byID[prepID].Status != StatusPending {
		t.Errorf("prep should be untouched, got %s", byID[prepID].Status)
	}
	if byID[txID].Status != StatusPending {
		t.Errorf("transcribe should be untouched, got %s", byID[txID].Status)
	}
	if byID[sumID].Status != StatusFailed {
		t.Errorf("summarize status = %s, want failed", byID[sumID].Status)
	}
}

func TestMarkJobPendingRetry_SetsFinishedAtForBackoff(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)
	jobID, _ := db.EnqueueJob(recID, JobPrep)
	_, _ = db.ClaimNextPendingJob()

	// Without finished_at being set here, the backoff query would break —
	// this is exactly the bug the fix addresses.
	if err := db.MarkJobPendingRetry(jobID, "try again"); err != nil {
		t.Fatalf("mark retry: %v", err)
	}

	jobs, _ := db.ListRecentJobs(1)
	if jobs[0].Status != StatusPending {
		t.Errorf("status = %s, want pending", jobs[0].Status)
	}
	if jobs[0].FinishedAt == nil {
		t.Error("finished_at must be set so backoff query can compute eligibility")
	}
	if jobs[0].Error != "try again" {
		t.Errorf("error = %q, want %q", jobs[0].Error, "try again")
	}
}

// ---- ResetStuckJobs ----

func TestResetStuckJobs_RunningJobsBackToPending(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)

	for i := 0; i < 3; i++ {
		_, _ = db.EnqueueJob(recID, JobPrep)
	}

	// Claim two, leave one pending — simulates a crash with two in-flight
	_, _ = db.ClaimNextPendingJob()
	_, _ = db.ClaimNextPendingJob()

	before, _ := db.CountJobs()
	if before.Running != 2 {
		t.Fatalf("setup: running = %d, want 2", before.Running)
	}

	n, err := db.ResetStuckJobs()
	if err != nil {
		t.Fatalf("reset: %v", err)
	}
	if n != 2 {
		t.Errorf("reset count = %d, want 2", n)
	}

	after, _ := db.CountJobs()
	if after.Running != 0 {
		t.Errorf("after reset, running = %d, want 0", after.Running)
	}
	if after.Pending != 3 {
		t.Errorf("after reset, pending = %d, want 3", after.Pending)
	}
}

func TestResetStuckJobs_Idempotent(t *testing.T) {
	db := newTestDB(t)

	n, err := db.ResetStuckJobs()
	if err != nil {
		t.Fatalf("reset on empty: %v", err)
	}
	if n != 0 {
		t.Errorf("want 0 reset on empty db, got %d", n)
	}
}

// ---- CountJobs ----

func TestCountJobs_MixedStatuses(t *testing.T) {
	db := newTestDB(t)
	recID := newTestRecording(t, db)

	// 3 complete
	for i := 0; i < 3; i++ {
		id, _ := db.EnqueueJob(recID, JobPrep)
		_, _ = db.ClaimNextPendingJob()
		_ = db.MarkJobComplete(id)
	}
	// 2 failed
	for i := 0; i < 2; i++ {
		id, _ := db.EnqueueJob(recID, JobPrep)
		_, _ = db.ClaimNextPendingJob()
		_ = db.MarkJobFailed(id, "boom")
	}
	// 1 running
	_, _ = db.EnqueueJob(recID, JobPrep)
	_, _ = db.ClaimNextPendingJob()
	// 4 pending
	for i := 0; i < 4; i++ {
		_, _ = db.EnqueueJob(recID, JobPrep)
	}

	counts, err := db.CountJobs()
	if err != nil {
		t.Fatalf("count: %v", err)
	}

	want := JobCounts{Pending: 4, Running: 1, Complete: 3, Failed: 2}
	if counts != want {
		t.Errorf("counts = %+v, want %+v", counts, want)
	}
}
