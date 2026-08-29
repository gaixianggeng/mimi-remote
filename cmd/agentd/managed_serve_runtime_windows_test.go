//go:build windows

package main

import (
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func TestManagedServeLifetimeJobKillsProcessesOnClose(t *testing.T) {
	job, err := createManagedServeLifetimeJob()
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(job)

	var info windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	if err := windows.QueryInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info)),
		nil,
	); err != nil {
		t.Fatal(err)
	}
	if info.BasicLimitInformation.LimitFlags&windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE == 0 {
		t.Fatalf("job flags = %#x, want KILL_ON_JOB_CLOSE", info.BasicLimitInformation.LimitFlags)
	}
}
