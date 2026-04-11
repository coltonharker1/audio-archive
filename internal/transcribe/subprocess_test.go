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

// TestTranscribeSubprocessSafety_GrandchildDoesNotHang is the regression
// guard for the production hang we hit on 2026-04-10: when a transcribe
// subprocess (historically faster-whisper with its multiprocessing pool,
// but the class of bug applies to any engine) leaks a grandchild that
// escapes the process group and holds a stderr/stdout pipe open, Go's
// cmd.Wait can block forever on a pipe-copy goroutine that will never
// see EOF.
//
// The fake "whisper-cli" below spawns a setsid-detached grandchild that
// inherits stderr and holds it open for longer than the test context,
// then the parent blocks so context cancel triggers the safety path
// (not a clean exit). Before the Setpgid + Cancel + WaitDelay fix, the
// test blocks until the grandchild self-terminates. With the fix, the
// whole call returns bounded by context-deadline + WaitDelay.
//
// We exercise this through RunWhisperCpp rather than a direct
// applySubprocessSafety call so the test proves the safety helper is
// actually wired into the live transcribe backend.
func TestTranscribeSubprocessSafety_GrandchildDoesNotHang(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("process group semantics differ on windows; unix-only regression test")
	}

	// Shrink WaitDelay so the test finishes in well under a second.
	orig := waitDelay
	waitDelay = 200 * time.Millisecond
	t.Cleanup(func() { waitDelay = orig })

	dir := t.TempDir()

	// Fake whisper-cli that mimics the pathological faster-whisper
	// shutdown sequence: spawn a setsid-detached grandchild that inherits
	// stderr and holds the pipe open, then block so the context-cancel
	// path fires.
	fakeBin := filepath.Join(dir, "fake-whisper-cli.sh")
	script := `#!/bin/sh
# Grandchild escapes our process group (setsid → new session) and inherits
# stderr, keeping the pipe fd open. 10s outlasts the test context but not
# by so much that it leaves zombies around.
setsid sh -c 'sleep 10' &
# Block so the context cancel path runs instead of a clean exit.
sleep 10
`
	if err := os.WriteFile(fakeBin, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake whisper-cli: %v", err)
	}

	// RunWhisperCpp's Stat checks need these files to exist.
	modelPath := filepath.Join(dir, "ggml-base.en.bin")
	audioPath := filepath.Join(dir, "audio.wav")
	for _, p := range []string{modelPath, audioPath} {
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatalf("write %s: %v", p, err)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := RunWhisperCpp(ctx, fakeBin, modelPath, "", audioPath)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("expected error from cancelled subprocess, got nil (elapsed=%s)", elapsed)
	}
	// We expect some shape of cancellation / deadline / signal / wait error.
	// Be permissive on the exact wording since Go's wrapping changes over
	// versions.
	if !errors.Is(err, context.DeadlineExceeded) && !strContainsAny(err.Error(), "killed", "signal", "deadline", "wait", "cancel") {
		t.Fatalf("unexpected error shape: %v", err)
	}

	// The whole call — deadline (300ms) + WaitDelay (200ms) + slop — must
	// return in well under the grandchild's 10s sleep. If it blocks past
	// 2s we've regressed to the hang behaviour.
	if elapsed > 2*time.Second {
		t.Fatalf("RunWhisperCpp blocked too long on grandchild pipe holder: %s (expected <2s)", elapsed)
	}
}

// strContainsAny is a tiny helper to keep the error-shape assertion
// readable without reaching for strings.Contains N times.
func strContainsAny(s string, needles ...string) bool {
	for _, n := range needles {
		if n == "" {
			continue
		}
		for i := 0; i+len(n) <= len(s); i++ {
			if s[i:i+len(n)] == n {
				return true
			}
		}
	}
	return false
}
