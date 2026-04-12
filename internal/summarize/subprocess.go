package summarize

import (
	"errors"
	"syscall"
)

// syscallSysProcAttr returns a SysProcAttr that puts the child in its own
// process group. Platform-specific (unix only).
func syscallSysProcAttr() syscall.SysProcAttr {
	return syscall.SysProcAttr{Setpgid: true}
}

// killProcessGroup sends SIGKILL to the entire process group rooted at pid.
func killProcessGroup(pid int) error {
	if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
		return err
	}
	return nil
}
