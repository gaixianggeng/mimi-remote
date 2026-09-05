//go:build linux

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestLinuxTerminalPTYNavigation(t *testing.T) {
	if agent := os.Getenv("MIMI_TRAY_TEST_AGENT"); agent != "" {
		if err := runLinuxTerminal(agent, "status"); err != nil {
			os.Exit(2)
		}
		return
	}
	dir := t.TempDir()
	agent := filepath.Join(dir, "agentd")
	script := `#!/bin/sh
if [ "$1" = tailcat ]; then
  echo '{"enabled":false,"running":false,"paired_device_count":0}'
else
  echo '{"version":"fixture","process_ok":true,"service_ok":true,"doctor_ok":true}'
fi
`
	if err := os.WriteFile(agent, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestLinuxTerminalPTYNavigation$")
	cmd.Env = append(os.Environ(), "MIMI_TRAY_TEST_AGENT="+agent)
	terminal, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 45, Cols: 120})
	if err != nil {
		t.Fatal(err)
	}
	defer terminal.Close()
	defer cmd.Process.Kill()
	chunks := make(chan string, 16)
	go func() {
		defer close(chunks)
		data := make([]byte, 4096)
		for {
			n, err := terminal.Read(data)
			if n > 0 {
				chunks <- string(data[:n])
			}
			if err != nil {
				return
			}
		}
	}()
	readUntil := func(want string) {
		t.Helper()
		timer := time.NewTimer(5 * time.Second)
		defer timer.Stop()
		var text strings.Builder
		for {
			select {
			case chunk, ok := <-chunks:
				if !ok {
					t.Fatalf("terminal exited before %q: %s", want, text.String())
				}
				text.WriteString(chunk)
				if strings.Contains(text.String(), want) {
					return
				}
			case <-timer.C:
				t.Fatalf("terminal did not show %q: %s", want, text.String())
			}
		}
	}
	readUntil("选择后按 Enter")
	_, _ = terminal.Write([]byte("1\n"))
	readUntil("输入 enable 确认")
	_, _ = terminal.Write([]byte("no\n"))
	readUntil("已取消")
	_, _ = terminal.Write([]byte("q\n"))
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("terminal did not quit")
	}
}
