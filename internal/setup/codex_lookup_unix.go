//go:build !windows

package setup

import "os/exec"

func lookupUsableExecutable(file string) (string, error) {
	return exec.LookPath(file)
}

func lookupUsableCodexExecutable(file string) (string, error) {
	return lookupUsableExecutable(file)
}
