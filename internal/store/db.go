package store

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

// DB wraps the SQLite database connection.
type DB struct {
	conn *sql.DB
	// backoffSecondsPerAttempt is used by ClaimNextPendingJob when computing
	// how long a failed job must wait before retry. Multiplied by the job's
	// attempt count — so after attempt 1 fails, the wait is 1*N; attempt 2, 2*N.
	// Defaults to 30; tests override via SetBackoffSeconds.
	backoffSecondsPerAttempt int
}

// Open opens (or creates) a SQLite database at the given path and runs migrations.
func Open(dbPath string) (*DB, error) {
	conn, err := sql.Open("sqlite", dbPath+"?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=on")
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}

	// SQLite has one writer at a time. Serializing all access through a
	// single connection eliminates SQLITE_BUSY errors when multiple
	// goroutines (dispatcher + workers) hit the DB concurrently. WAL mode
	// still allows readers to not block the writer.
	conn.SetMaxOpenConns(1)

	db := &DB{
		conn:                     conn,
		backoffSecondsPerAttempt: 30,
	}
	if err := db.migrate(); err != nil {
		return nil, fmt.Errorf("running migrations: %w", err)
	}

	return db, nil
}

// SetBackoffSeconds overrides the retry backoff multiplier. Used by tests
// to run the retry/backoff logic without waiting real seconds.
func (db *DB) SetBackoffSeconds(seconds int) {
	db.backoffSecondsPerAttempt = seconds
}

// Close closes the database connection.
func (db *DB) Close() error {
	return db.conn.Close()
}
