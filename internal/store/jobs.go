package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// JobType identifies what work a job performs.
type JobType string

const (
	JobPrep       JobType = "prep"
	JobTranscribe JobType = "transcribe"
	JobSummarize  JobType = "summarize"
)

// JobStatus represents a job's position in its lifecycle.
type JobStatus string

const (
	StatusPending  JobStatus = "pending"
	StatusRunning  JobStatus = "running"
	StatusComplete JobStatus = "complete"
	StatusFailed   JobStatus = "failed"
)

// Default retry policy per job type. Transcribe and summarize jobs are
// expensive, so we give them more retries.
var defaultMaxRetries = map[JobType]int{
	JobPrep:       3,
	JobTranscribe: 2,
	JobSummarize:  2,
}

// predecessorType maps each job type to the job type it depends on for the
// same recording. Prep has no predecessor (it runs on the master file).
// Transcribe depends on prep producing the normalized audio; summarize
// depends on transcribe producing the transcript text. Used by the claim
// query to filter out ineligible jobs, and by MarkJobFailed to cascade
// failure to downstream stages of the same recording.
var predecessorType = map[JobType]JobType{
	JobTranscribe: JobPrep,
	JobSummarize:  JobTranscribe,
}

// successorTypes maps each job type to the downstream job types for the
// same recording that become unrunnable if this one fails permanently.
// Used by MarkJobFailed to cascade-fail dependents so they don't sit in
// pending forever (before: they'd stay pending; or worse, under the old
// dispatcher, they'd be claimed anyway and burn their retry budget on
// "no transcript — transcribe first" errors).
var successorTypes = map[JobType][]JobType{
	JobPrep:       {JobTranscribe, JobSummarize},
	JobTranscribe: {JobSummarize},
	JobSummarize:  nil,
}

// Job is a single unit of work in the queue.
type Job struct {
	ID          int64
	RecordingID int64
	Type        JobType
	Status      JobStatus
	Attempt     int
	MaxRetries  int
	Error       string
	Model       string // optional override for transcribe jobs ("base", "small", "medium", etc.); empty = use config default
	CreatedAt   time.Time
	StartedAt   *time.Time
	FinishedAt  *time.Time
}

// ErrNoJob is returned by ClaimNextPendingJob when no work is available.
var ErrNoJob = errors.New("no pending jobs")

// EnqueueJob inserts a new pending job for the given recording.
func (db *DB) EnqueueJob(recordingID int64, jobType JobType) (int64, error) {
	return db.EnqueueJobWithModel(recordingID, jobType, "")
}

// EnqueueJobWithModel inserts a new pending job with an optional model
// override (e.g. "base", "small", "medium"). Empty model means use the
// config default. Only meaningful for transcribe jobs.
func (db *DB) EnqueueJobWithModel(recordingID int64, jobType JobType, model string) (int64, error) {
	maxRetries, ok := defaultMaxRetries[jobType]
	if !ok {
		maxRetries = 3
	}

	res, err := db.conn.Exec(`
		INSERT INTO jobs (recording_id, type, status, max_retries, model)
		VALUES (?, ?, 'pending', ?, NULLIF(?, ''))`,
		recordingID, string(jobType), maxRetries, model,
	)
	if err != nil {
		return 0, fmt.Errorf("enqueuing job: %w", err)
	}
	return res.LastInsertId()
}

// ClaimNextPendingJob atomically fetches the oldest pending job and marks
// it as running, returning the claimed job. It skips jobs that have been
// updated recently (for retry backoff) and jobs whose predecessor stage
// for the same recording has not completed yet. Returns ErrNoJob if
// nothing is ready.
//
// Predecessor filtering: a summarize job for recording N is only eligible
// when a transcribe job for recording N is in state 'complete'. Likewise
// transcribe requires a complete prep. Without this filter, the dispatcher
// could claim a summarize whose transcribe was still pending/running/failed
// and the handler would immediately error with "no transcript — transcribe
// first", burning the retry budget for no reason. (Evidence: the 2026-04-11
// rec-6 cascade, where 2 summarize jobs failed permanently for exactly
// this reason.)
//
// Note: the claim increments attempt and sets status=running, but leaves
// started_at to be set by the worker via MarkJobStarted once execution
// actually begins. This way started_at reflects real work time, not the
// wait time in the channel buffer between dispatcher and worker.
//
// The atomic fetch-and-update prevents two workers from claiming the same job.
func (db *DB) ClaimNextPendingJob() (*Job, error) {
	// Backoff: jobs that previously finished (with failure leading to retry)
	// must wait attempt * backoffSecondsPerAttempt before being reclaimed.
	// First-attempt jobs have finished_at NULL so are immediately eligible.
	//
	// Predecessor filter: a job is eligible only if it has no predecessor
	// stage (prep), OR a completed predecessor exists for the same recording.
	// Encoded as a CASE expression in the subquery WHERE clause because the
	// predecessor type depends on the candidate job's type.
	// Transcribe concurrency cap: only one transcribe runs at a time.
	// whisper.cpp pins the GPU and uses substantial memory; running multiple
	// in parallel triggers OOM kills under load (Apr 2026 batch incident).
	// Prep (FFmpeg, CPU) and summarize (Claude HTTP) can still overlap freely.
	query := fmt.Sprintf(`
		UPDATE jobs
		SET status = 'running',
		    attempt = attempt + 1
		WHERE id = (
			SELECT id FROM jobs AS j
			WHERE j.status = 'pending'
			  AND (j.finished_at IS NULL
			       OR datetime(j.finished_at, '+' || (j.attempt * %d) || ' seconds') <= datetime('now'))
			  AND (
			       j.type = 'prep'
			       OR EXISTS (
			            SELECT 1 FROM jobs AS p
			            WHERE p.recording_id = j.recording_id
			              AND p.status = 'complete'
			              AND p.type = CASE j.type
			                             WHEN 'transcribe' THEN 'prep'
			                             WHEN 'summarize'  THEN 'transcribe'
			                           END
			       )
			  )
			  AND (
			       j.type != 'transcribe'
			       OR NOT EXISTS (
			            SELECT 1 FROM jobs AS t
			            WHERE t.type = 'transcribe' AND t.status = 'running'
			       )
			  )
			ORDER BY j.created_at
			LIMIT 1
		)
		RETURNING id, recording_id, type, status, attempt, max_retries,
		          COALESCE(error, ''), COALESCE(model, ''), created_at
	`, db.backoffSecondsPerAttempt)

	row := db.conn.QueryRow(query)

	var j Job
	var jobType, status, createdAt string

	err := row.Scan(
		&j.ID, &j.RecordingID, &jobType, &status,
		&j.Attempt, &j.MaxRetries, &j.Error, &j.Model, &createdAt,
	)
	if err == sql.ErrNoRows {
		return nil, ErrNoJob
	}
	if err != nil {
		return nil, fmt.Errorf("claiming job: %w", err)
	}

	j.Type = JobType(jobType)
	j.Status = JobStatus(status)
	j.CreatedAt, _ = time.Parse("2006-01-02 15:04:05", createdAt)
	return &j, nil
}

// MarkJobStarted records the real execution start time. Called by workers
// when they actually begin running a claimed job (not when it's queued).
func (db *DB) MarkJobStarted(id int64) error {
	_, err := db.conn.Exec(`
		UPDATE jobs
		SET started_at = datetime('now')
		WHERE id = ?`, id)
	return err
}

// MarkJobComplete transitions a job to complete status.
func (db *DB) MarkJobComplete(id int64) error {
	_, err := db.conn.Exec(`
		UPDATE jobs
		SET status = 'complete',
		    finished_at = datetime('now'),
		    error = NULL
		WHERE id = ?`, id)
	return err
}

// MarkJobFailed transitions a job to terminal failed status with an error
// message, and also cascade-fails any downstream pending jobs for the same
// recording so they don't sit in pending forever (the predecessor filter
// in ClaimNextPendingJob would refuse to claim them otherwise) or — under
// older versions of the dispatcher — burn their retry budget on
// "no transcript — transcribe first" style errors.
//
// Cascade scope: prep failure fails transcribe + summarize for the same
// recording; transcribe failure fails summarize for the same recording;
// summarize failure cascades to nothing. Only jobs in pending/running
// state are cascaded — jobs already complete or failed are left alone.
func (db *DB) MarkJobFailed(id int64, errMsg string) error {
	// First mark this job failed so callers always see the primary
	// state change even if the cascade query has an issue.
	if _, err := db.conn.Exec(`
		UPDATE jobs
		SET status = 'failed',
		    finished_at = datetime('now'),
		    error = ?
		WHERE id = ?`, errMsg, id); err != nil {
		return err
	}

	// Look up the just-failed job so we know its type and recording_id
	// without making the caller pass them.
	var failedType string
	var recordingID int64
	if err := db.conn.QueryRow(`
		SELECT type, recording_id FROM jobs WHERE id = ?`, id).Scan(&failedType, &recordingID); err != nil {
		// If this lookup fails we've still marked the primary job
		// failed, so return nil — the cascade is best-effort.
		return nil
	}

	successors, ok := successorTypes[JobType(failedType)]
	if !ok || len(successors) == 0 {
		return nil
	}

	// Build the successor IN (...) list inline. Go's database/sql doesn't
	// have first-class slice binding for sqlite, and the type list is
	// short + closed, so inline is fine and injection-safe.
	inList := "'" + string(successors[0]) + "'"
	for _, t := range successors[1:] {
		inList += ",'" + string(t) + "'"
	}

	cascadeMsg := fmt.Sprintf("cascade: predecessor %s failed for this recording", failedType)
	_, _ = db.conn.Exec(fmt.Sprintf(`
		UPDATE jobs
		SET status = 'failed',
		    finished_at = datetime('now'),
		    error = ?
		WHERE recording_id = ?
		  AND status IN ('pending', 'running')
		  AND type IN (%s)`, inList), cascadeMsg, recordingID)
	return nil
}

// MarkJobPendingRetry returns a job to pending status for retry. The attempt
// count was already incremented during ClaimNextPendingJob. Also sets
// finished_at to now so the backoff window can be calculated on next claim.
func (db *DB) MarkJobPendingRetry(id int64, errMsg string) error {
	_, err := db.conn.Exec(`
		UPDATE jobs
		SET status = 'pending',
		    finished_at = datetime('now'),
		    error = ?
		WHERE id = ?`, errMsg, id)
	return err
}

// MarkJobPendingCanceled returns a claimed-but-uncompleted job to pending
// state WITHOUT counting against its retry budget. Use this when a job was
// interrupted by a user-initiated cancellation (graceful daemon shutdown,
// `make reinstall-daemons`, etc.) rather than a genuine handler failure —
// the job didn't get a fair try, so it shouldn't burn an attempt.
//
// Unlike MarkJobPendingRetry, this decrements the attempt counter (which
// was incremented at claim time in ClaimNextPendingJob), so the next claim
// will treat this as if the previous one never happened. finished_at is
// deliberately left NULL so the retry backoff window doesn't kick in —
// the cancellation was our fault, not the job's, so the next claim should
// be immediately eligible.
//
// Evidence from 2026-04-11: the prior behaviour — treating graceful
// shutdowns like failures — permanently failed two transcribes during
// `make reinstall-daemons` that were at attempt 2/2 when the worker was
// stopped. Those jobs had done nothing wrong; they were just in flight
// when the user cycled the daemon.
func (db *DB) MarkJobPendingCanceled(id int64, errMsg string) error {
	_, err := db.conn.Exec(`
		UPDATE jobs
		SET status = 'pending',
		    attempt = CASE WHEN attempt > 0 THEN attempt - 1 ELSE 0 END,
		    finished_at = NULL,
		    error = ?
		WHERE id = ?`, errMsg, id)
	return err
}

// ResetStuckJobs finds jobs in 'running' state (orphaned from a crashed worker)
// and moves them back to 'pending' so they can be retried on worker restart.
// Returns the number of jobs reset.
func (db *DB) ResetStuckJobs() (int, error) {
	res, err := db.conn.Exec(`
		UPDATE jobs
		SET status = 'pending',
		    error = 'reset after crash recovery'
		WHERE status = 'running'`)
	if err != nil {
		return 0, fmt.Errorf("resetting stuck jobs: %w", err)
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// JobCounts returns the count of jobs by status.
type JobCounts struct {
	Pending  int
	Running  int
	Complete int
	Failed   int
}

// CountJobs returns job counts grouped by status.
func (db *DB) CountJobs() (JobCounts, error) {
	rows, err := db.conn.Query(`SELECT status, COUNT(*) FROM jobs GROUP BY status`)
	if err != nil {
		return JobCounts{}, fmt.Errorf("counting jobs: %w", err)
	}
	defer rows.Close()

	var counts JobCounts
	for rows.Next() {
		var status string
		var n int
		if err := rows.Scan(&status, &n); err != nil {
			return counts, err
		}
		switch JobStatus(status) {
		case StatusPending:
			counts.Pending = n
		case StatusRunning:
			counts.Running = n
		case StatusComplete:
			counts.Complete = n
		case StatusFailed:
			counts.Failed = n
		}
	}
	return counts, rows.Err()
}

// ListRecentJobs returns the most recent jobs across all statuses.
func (db *DB) ListRecentJobs(limit int) ([]Job, error) {
	rows, err := db.conn.Query(`
		SELECT id, recording_id, type, status, attempt, max_retries,
		       COALESCE(error, ''), COALESCE(model, ''), created_at,
		       COALESCE(started_at, ''), COALESCE(finished_at, '')
		FROM jobs
		ORDER BY id DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("listing jobs: %w", err)
	}
	defer rows.Close()

	var jobs []Job
	for rows.Next() {
		var j Job
		var jobType, status, createdAt, startedAt, finishedAt string

		if err := rows.Scan(&j.ID, &j.RecordingID, &jobType, &status,
			&j.Attempt, &j.MaxRetries, &j.Error, &j.Model,
			&createdAt, &startedAt, &finishedAt); err != nil {
			return nil, err
		}

		j.Type = JobType(jobType)
		j.Status = JobStatus(status)
		j.CreatedAt, _ = time.Parse("2006-01-02 15:04:05", createdAt)
		if startedAt != "" {
			t, _ := time.Parse("2006-01-02 15:04:05", startedAt)
			j.StartedAt = &t
		}
		if finishedAt != "" {
			t, _ := time.Parse("2006-01-02 15:04:05", finishedAt)
			j.FinishedAt = &t
		}
		jobs = append(jobs, j)
	}
	return jobs, rows.Err()
}
