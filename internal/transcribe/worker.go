package transcribe

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// waitDelay bounds how long Wait will block for pipe I/O after the subprocess
// has been terminated. Tests override this to a small value. 30s is plenty for
// production: faster-whisper flushes stdout in one final JSON blob, so the
// only case where 30s is "needed" is the grandchild-leak bug this defends
// against.
var waitDelay = 30 * time.Second

// Segment represents a timed transcript segment.
type Segment struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	Text  string  `json:"text"`
}

// Result holds the complete transcription output from the Python worker.
type Result struct {
	Language            string    `json:"language"`
	LanguageProbability float64   `json:"language_probability"`
	Duration            float64   `json:"duration"`
	Segments            []Segment `json:"segments"`
	FullText            string    `json:"full_text"`
}

// Run invokes the Python transcription worker and returns the parsed result.
// pythonPath should point to the venv's python binary.
// workerPath should point to worker/transcribe.py.
//
// The subprocess is placed in its own process group so that on context cancel
// (or a hard timeout), SIGKILL propagates to any grandchildren spawned by
// faster-whisper's multiprocessing pool. Without this, orphaned grandchildren
// can hold the stdout pipe open and deadlock Go's cmd.Wait forever.
//
// WaitDelay is the belt-and-suspenders: even if grandchildren survive the
// group kill, Wait will forcibly close the pipes and return after the delay
// rather than blocking indefinitely on a pipe read that will never EOF.
func Run(ctx context.Context, pythonPath, workerPath, audioPath, modelSize string) (*Result, error) {
	cmd := exec.CommandContext(ctx, pythonPath, workerPath, audioPath, modelSize)

	// New process group so we can signal the whole tree, not just the parent.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// Override the default cancel (which just kills the direct child) with
	// one that SIGKILLs the entire process group.
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		// Negative PID = process group.
		if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
			return err
		}
		return os.ErrProcessDone
	}

	// After the process is killed (by Cancel or naturally), wait at most 30s
	// for the I/O pipes to drain before forcibly closing them. This is the
	// fix for the multiprocessing-orphan pipe-deadlock we hit on the real
	// overnight batch: faster-whisper's resource_tracker would leak
	// semaphores and hold stdout open, so Wait blocked forever.
	cmd.WaitDelay = waitDelay

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("transcription worker failed: %w\nstderr: %s", err, stderr.String())
	}

	var result Result
	if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
		return nil, fmt.Errorf("parsing transcript JSON: %w\nraw output: %s", err, stdout.String())
	}

	return &result, nil
}
