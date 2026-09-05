//go:build !linux

package appserver

import "os/exec"

func configureSharedLocalCommand(*exec.Cmd) {}
