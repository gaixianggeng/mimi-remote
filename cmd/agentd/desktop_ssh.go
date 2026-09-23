package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/sshbridge"
)

type sshCommandExit struct{ code int }

func (e *sshCommandExit) Error() string { return fmt.Sprintf("SSH command exited: %d", e.code) }

func runSSHBridge(args []string) error {
	fs := flag.NewFlagSet("ssh-bridge", flag.ContinueOnError)
	path := fs.String("config", config.DefaultPath(), "现有配置文件路径")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 0 || runtime.GOOS != "darwin" {
		return fmt.Errorf("ssh-bridge 仅供 macOS 专用 SSH 密钥的 forced command 使用")
	}
	command := os.Getenv("SSH_ORIGINAL_COMMAND")
	if command == "" || os.Getenv("SSH_CONNECTION") == "" {
		return fmt.Errorf("请通过 Mimi 专用 SSH 密钥发起 exec 命令；此入口不支持交互式登录")
	}
	cfg, err := config.LoadForDoctor(*path)
	if err != nil {
		return err
	}
	if !cfg.DesktopSSH.Enabled || cfg.AppServer.Transport != "local" {
		return fmt.Errorf("请先在 Mimi 配置中启用 desktop_ssh.enabled，并使用本机共享 Codex")
	}
	socket, err := sshbridge.SocketPath(config.ExpandPath(*path))
	if err != nil {
		return err
	}
	code, err := sshbridge.Run(context.Background(), socket, command, os.Stdin, os.Stdout, os.Stderr)
	if err != nil {
		return err
	}
	if code != 0 {
		return &sshCommandExit{code}
	}
	return nil
}

func startDesktopSSHBridge(cfg config.Config, configPath string) (*sshbridge.Server, error) {
	if !cfg.DesktopSSH.Enabled {
		return nil, nil
	}
	if runtime.GOOS != "darwin" || cfg.AppServer.Transport != "local" {
		return nil, fmt.Errorf("专用 Desktop SSH 入口要求 macOS 本机 local transport")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	manager, err := exec.CommandContext(ctx, "/bin/launchctl", "managername").Output()
	if err != nil || strings.TrimSpace(string(manager)) != "Aqua" {
		return nil, fmt.Errorf("专用 Desktop SSH 入口必须由已登录的 Mimi Remote Mac 启动")
	}
	socket, err := sshbridge.SocketPath(config.ExpandPath(configPath))
	if err != nil {
		return nil, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	shell := os.Getenv("SHELL")
	if !filepath.IsAbs(shell) {
		shell = "/bin/zsh"
	}
	env := os.Environ()
	// 与 Mimi 共享同一个显式 CODEX_HOME；不复制登录凭据，也不把 SSH 的
	// Background 环境整包带入 GUI 命令。其余登录环境由用户自己的 shell 加载。
	if codexHome := cfg.Codex.Env["CODEX_HOME"]; codexHome != "" {
		env = append(env, "CODEX_HOME="+codexHome)
	}
	server, err := sshbridge.Listen(socket, sshbridge.Options{Shell: shell, Home: home, Env: env})
	if err == nil {
		log.Print("Mimi Desktop SSH command bridge ready")
	}
	return server, err
}
