package transcribe

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// TestRun_GrandchildPipeHolderDoesNotHang reproduces the production hang we
// hit on the real overnight batch: faster-whisper's multiprocessing pool
// leaked a grandchild that kept the stdout pipe open after the python parent
// died, and Go's cmd.Wait blocked forever on a pipe read that would never
// EOF.
//
// The fake "python" script below spawns a setsid-detached grandchild that
// escapes the parent's process group and holds stdout open for longer than
// the test timeout, then the parent sleeps so the context cancel path fires
// (not a clean exit). Before the fix, Run would block forever. After the
// fix, the process-group SIGKILL ends the parent and WaitDelay forcibly
// closes the inherited pipe so Run returns bounded.
func TestRun_GrandchildPipeHolderDoesNotHang(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("process group semantics differ on windows; test is unix-only")
	}

	// Shrink WaitDelay so the test finishes in well under a second.
	orig := waitDelay
	waitDelay = 200 * time.Millisecond
	t.Cleanup(func() { waitDelay = orig })

	dir := t.TempDir()
	fakePython := filepath.Join(dir, "fake_python.sh")
	script := `#!/bin/sh
# Spawn a grandchild that (a) escapes our process group via setsid and
# (b) inherits stdout, keeping the pipe open. 10s is long enough to outlast
# the test but short enough that the zombie doesn't stick around after.
setsid sh -c 'sleep 10' &
# Block so that the context cancel path fires instead of a clean exit.
sleep 10
`
	if err := os.WriteFile(fakePython, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake python: %v", err)
	}

	// The worker path and audio path are passed as argv to the fake script;
	// it doesn't care about them. They just need to be non-empty.
	workerPath := filepath.Join(dir, "worker.py")
	audioPath := filepath.Join(dir, "audio.wav")

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := Run(ctx, fakePython, workerPath, audioPath, "base")
	elapsed := time.Since(start)

	// We expect an error (context deadline hit, pipes forcibly closed).
	if err == nil {
		t.Fatalf("expected error, got nil (elapsed=%s)", elapsed)
	}
	if !errors.Is(err, context.DeadlineExceeded) && !containsAny(err.Error(), "killed", "signal", "deadline", "wait") {
		t.Fatalf("unexpected error shape: %v", err)
	}

	// The whole call — deadline (300ms) + WaitDelay (200ms) + slop — must
	// return in well under the grandchild's 10s sleep. If it takes longer
	// than ~2s we've regressed to the blocking-forever behaviour.
	if elapsed > 2*time.Second {
		t.Fatalf("Run blocked too long on grandchild pipe holder: %s (expected <2s)", elapsed)
	}
}

// TestRun_CleanExitPropagatesError verifies that a normal non-zero exit from
// the subprocess still returns an error promptly (no regressions from the
// WaitDelay / process group changes).
func TestRun_CleanExitPropagatesError(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix-only")
	}

	dir := t.TempDir()
	fakePython := filepath.Join(dir, "fake_python.sh")
	script := `#!/bin/sh
echo "boom" >&2
exit 7
`
	if err := os.WriteFile(fakePython, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake python: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	start := time.Now()
	_, err := Run(ctx, fakePython, filepath.Join(dir, "w.py"), filepath.Join(dir, "a.wav"), "base")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected error from non-zero exit, got nil")
	}
	if !containsAny(err.Error(), "exit status 7", "boom") {
		t.Fatalf("error did not surface subprocess stderr / exit status: %v", err)
	}
	if elapsed > time.Second {
		t.Fatalf("clean-exit error path was slow: %s", elapsed)
	}
}

func containsAny(s string, needles ...string) bool {
	for _, n := range needles {
		if n == "" {
			continue
		}
		if idx := indexOf(s, n); idx >= 0 {
			return true
		}
	}
	return false
}

func indexOf(s, needle string) int {
	n := len(needle)
	if n == 0 || n > len(s) {
		return -1
	}
	for i := 0; i+n <= len(s); i++ {
		if s[i:i+n] == needle {
			return i
		}
	}
	return -1
}
