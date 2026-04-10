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

// Job is a single unit of work in the queue.
type Job struct {
	ID          int64
	RecordingID int64
	Type        JobType
	Status      JobStatus
	Attempt     int
	MaxRetries  int
	Error       string
	CreatedAt   time.Time
	StartedAt   *time.Time
	FinishedAt  *time.Time
}

// ErrNoJob is returned by ClaimNextPendingJob when no work is available.
var ErrNoJob = errors.New("no pending jobs")

// EnqueueJob inserts a new pending job for the given recording.
func (db *DB) EnqueueJob(recordingID int64, jobType JobType) (int64, error) {
	maxRetries, ok := defaultMaxRetries[jobType]
	if !ok {
		maxRetries = 3
	}

	res, err := db.conn.Exec(`
		INSERT INTO jobs (recording_id, type, status, max_retries)
		VALUES (?, ?, 'pending', ?)`,
		recordingID, string(jobType), maxRetries,
	)
	if err != nil {
		return 0, fmt.Errorf("enqueuing job: %w", err)
	}
	return res.LastInsertId()
}

// ClaimNextPendingJob atomically fetches the oldest pending job and marks
// it as running, returning the claimed job. It skips jobs that have been
// updated recently (for retry backoff). Returns ErrNoJob if nothing is ready.
//
// The atomic fetch-and-update prevents two workers from claiming the same job.
func (db *DB) ClaimNextPendingJob() (*Job, error) {
	// Backoff: jobs that failed recently should wait before retry.
	// We compute the earliest eligible time as now() - (attempt * 30s).
	// A job is eligible if status='pending' AND started_at IS NULL OR
	// started_at older than the backoff threshold.
	row := db.conn.QueryRow(`
		UPDATE jobs
		SET status = 'running',
		    started_at = datetime('now'),
		    attempt = attempt + 1
		WHERE id = (
			SELECT id FROM jobs
			WHERE status = 'pending'
			  AND (started_at IS NULL
			       OR datetime(started_at, '+' || (attempt * 30) || ' seconds') <= datetime('now'))
			ORDER BY created_at
			LIMIT 1
		)
		RETURNING id, recording_id, type, status, attempt, max_retries,
		          COALESCE(error, ''), created_at
	`)

	var j Job
	var jobType, status, createdAt string

	err := row.Scan(
		&j.ID, &j.RecordingID, &jobType, &status,
		&j.Attempt, &j.MaxRetries, &j.Error, &createdAt,
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

// MarkJobFailed transitions a job to terminal failed status with an error message.
func (db *DB) MarkJobFailed(id int64, errMsg string) error {
	_, err := db.conn.Exec(`
		UPDATE jobs
		SET status = 'failed',
		    finished_at = datetime('now'),
		    error = ?
		WHERE id = ?`, errMsg, id)
	return err
}

// MarkJobPendingRetry returns a job to pending status for retry. The attempt
// count was already incremented during ClaimNextPendingJob.
func (db *DB) MarkJobPendingRetry(id int64, errMsg string) error {
	_, err := db.conn.Exec(`
		UPDATE jobs
		SET status = 'pending',
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
		       COALESCE(error, ''), created_at,
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
			&j.Attempt, &j.MaxRetries, &j.Error,
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
