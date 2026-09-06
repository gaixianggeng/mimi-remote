//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func validLinuxTerminalAction(action string) bool {
	switch action {
	case "status", "service", "pair-tailcat", "pair-tailscale", "pair-lan", "doctor", "logs", "start", "restart", "stop", "tailcat-enable", "tailcat-disable":
		return true
	}
	return false
}

func linuxTerminalCommand(executable, agent, action string, lookup func(string) (string, error)) (*exec.Cmd, error) {
	if !validLinuxTerminalAction(action) {
		return nil, errors.New("未知终端页面")
	}
	args := []string{executable, "--agent", agent, "--terminal", action}
	if terminal, err := lookup("xdg-terminal-exec"); err == nil {
		return exec.Command(terminal, append([]string{"--title=Mimi Remote", "--app-id=io.github.gaixianggeng.MimiRemote", "--"}, args...)...), nil
	}
	// Pass argv directly; user paths and environment values are never shell code.
	for _, name := range []string{"x-terminal-emulator", "foot", "kitty", "alacritty", "konsole", "gnome-terminal", "xterm"} {
		if terminal, err := lookup(name); err == nil {
			separator := "-e"
			if name == "gnome-terminal" {
				separator = "--"
			}
			return exec.Command(terminal, append([]string{separator}, args...)...), nil
		}
	}
	return nil, errors.New("未找到终端，请安装 xdg-terminal-exec 或常用终端模拟器")
}

func launchLinuxTerminal(agent, action string) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	cmd, err := linuxTerminalCommand(executable, agent, action, exec.LookPath)
	if err != nil {
		return err
	}
	cmd.Dir = filepath.Dir(agent)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// A terminal may stay attached to this process. Quitting the tray must not
	// close it, so there is deliberately no CommandContext or timed cancellation.
	if err = cmd.Start(); err != nil {
		return fmt.Errorf("打开终端失败：%w", err)
	}
	go func() {
		if err := cmd.Wait(); err != nil {
			fmt.Fprintln(os.Stderr, "终端已退出：", err)
		}
	}()
	return nil
}

// Separate terminal windows share an operation lock. Status polling stays
// read-only and does not block on a long-running diagnostic or pairing request.
func lockLinuxTrayOperation() (func(), error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return nil, err
	}
	if runtime := os.Getenv("XDG_RUNTIME_DIR"); runtime != "" {
		base = runtime
	}
	directory := filepath.Join(base, "mimi-remote-tray")
	if err = os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(directory, "operation.lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, errors.New("另一个 Mimi Remote 窗口正在执行操作，请稍后重试")
	}
	return func() { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN); _ = file.Close() }, nil
}
