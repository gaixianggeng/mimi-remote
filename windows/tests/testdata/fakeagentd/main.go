// fakeagentd exercises the real Windows host without touching user services.
package main

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"
)

func main() {
	if os.Getenv("MIMI_HOST_TEST_MODE") == "exit" {
		os.Exit(42)
	}
	commands := []*exec.Cmd{
		exec.Command("cmd.exe", "/c", "ping -n 60 127.0.0.1 >nul"),
		exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 60"),
		exec.Command("git.exe", "hash-object", "--stdin"),
		exec.Command("ping.exe", "-n", "60", "127.0.0.1"),
	}
	commands[3].SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x200}
	var inputs []io.WriteCloser
	var children []int
	for _, command := range commands {
		input, err := command.StdinPipe()
		if err != nil {
			panic(err)
		}
		inputs = append(inputs, input)
		if err := command.Start(); err != nil {
			panic(err)
		}
		children = append(children, command.Process.Pid)
	}
	console, _, _ := syscall.NewLazyDLL("kernel32.dll").NewProc("GetConsoleWindow").Call()
	report := struct {
		Args     []string
		PID      int
		Children []int
		Console  uintptr
	}{os.Args[1:], os.Getpid(), children, console}
	payload, _ := json.Marshal(report)
	if err := os.WriteFile(os.Getenv("MIMI_HOST_TEST_REPORT")+".tmp", payload, 0600); err != nil {
		panic(err)
	}
	if err := os.Rename(os.Getenv("MIMI_HOST_TEST_REPORT")+".tmp", os.Getenv("MIMI_HOST_TEST_REPORT")); err != nil {
		panic(err)
	}
	time.Sleep(time.Minute)
	for _, input := range inputs {
		_ = input.Close()
	}
}
