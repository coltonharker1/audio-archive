package transcribe

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// waitDelay bounds how long Wait will block for pipe I/O after a transcribe
// subprocess has been terminated. Tests override this to a small value. 30s
// is plenty for production: whisper.cpp flushes output before exit, so the
// only case where the delay is *needed* is the grandchild-leak scenario
// this package defends against — which historically took down our overnight
// batch when faster-whisper's multiprocessing pool leaked semaphore holders.
var waitDelay = 30 * time.Second

// applySubprocessSafety configures an exec.Cmd so it cannot hang forever if
// the child (or a descendant) misbehaves on shutdown:
//
//  1. The child runs in its own process group so a SIGKILL can reach the
//     whole tree, not just the parent.
//  2. A custom Cancel sends SIGKILL to the process group when the context
//     is cancelled, so grandchildren spawned by multiprocessing pools,
//     threadpool helpers, etc. are terminated together.
//  3. WaitDelay forcibly closes I/O pipes after the child exits, so a
//     grandchild that somehow survives the group kill (setsid-detached,
//     new-session, etc.) can't keep the parent blocked on a pipe read
//     that will never see EOF.
//
// This is the shared implementation for every transcribe backend. The
// TestTranscribeSubprocessSafety_GrandchildDoesNotHang regression test in
// subprocess_test.go is the canary — if you refactor any of the three
// pieces, make sure that test still passes.
func applySubprocessSafety(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		// Negative PID signals the whole process group.
		if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
			return err
		}
		return os.ErrProcessDone
	}
	cmd.WaitDelay = waitDelay
}
