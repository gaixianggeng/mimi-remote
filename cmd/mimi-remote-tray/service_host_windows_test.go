//go:build windows

package main

import (
	"reflect"
	"testing"
)

func TestManagedServiceHostCommandStartsAgentWithoutConsoleWindow(t *testing.T) {
	agentPath := `C:\Program Files\Mimi Remote\agentd.exe`
	logPath := `C:\Users\tester\AppData\Local\Mimi Remote\logs\agentd.log`

	command, err := managedServiceHostCommand(agentPath, logPath)
	if err != nil {
		t.Fatalf("managedServiceHostCommand returned error: %v", err)
	}
	if command.Path != agentPath {
		t.Fatalf("command path = %q, want %q", command.Path, agentPath)
	}
	wantArgs := []string{agentPath, "serve", "--managed-service", "--log-file", logPath}
	if !reflect.DeepEqual(command.Args, wantArgs) {
		t.Fatalf("command args = %#v, want %#v", command.Args, wantArgs)
	}
	if command.SysProcAttr == nil || !command.SysProcAttr.HideWindow {
		t.Fatalf("managed agentd must hide its Windows process: %#v", command.SysProcAttr)
	}
	if command.SysProcAttr.CreationFlags&createNoWindow == 0 {
		t.Fatalf("creation flags = %#x, want CREATE_NO_WINDOW", command.SysProcAttr.CreationFlags)
	}
}

func TestManagedServiceHostCommandRequiresPaths(t *testing.T) {
	for _, testCase := range []struct {
		name      string
		agentPath string
		logPath   string
	}{
		{name: "missing agent", logPath: `C:\logs\agentd.log`},
		{name: "missing log", agentPath: `C:\Mimi Remote\agentd.exe`},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if _, err := managedServiceHostCommand(testCase.agentPath, testCase.logPath); err == nil {
				t.Fatal("missing managed-service path must fail")
			}
		})
	}
}
