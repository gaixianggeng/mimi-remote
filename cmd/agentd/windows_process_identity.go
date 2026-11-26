//go:build windows

package main

import (
	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
	"golang.org/x/sys/windows"
)

var windowsManagedPIDMatchesExecutable = managedPIDMatchesCurrentExecutable

func managedPIDMatchesCurrentExecutable(pid int) bool {
	if pid <= 0 {
		return false
	}
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(handle)
	return windowslan.SameExecutableIdentity(handle)
}
