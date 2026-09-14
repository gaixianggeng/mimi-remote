//go:build !linux && !darwin

package appserver

import "os/exec"

func configureSharedLocalCommand(*exec.Cmd) {}

func residentLaunchCommand(bin string, args []string) (string, []string) {
	return bin, args
}
