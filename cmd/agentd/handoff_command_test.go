package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func stubHandoffResolvers(t *testing.T, cfg config.Config) {
	t.Helper()
	oldCodex, oldSocket, oldLook, oldLoad := handoffResolveCodexBin, handoffSharedSocketPath, handoffLookPath, handoffLoadConfig
	t.Cleanup(func() {
		handoffResolveCodexBin, handoffSharedSocketPath, handoffLookPath, handoffLoadConfig = oldCodex, oldSocket, oldLook, oldLoad
	})
	handoffResolveCodexBin = func(configured string) (string, error) { return "/opt/codex/bin/codex", nil }
	handoffSharedSocketPath = func(env map[string]string) (string, error) {
		home := env["CODEX_HOME"]
		if home == "" {
			home = "/Users/me/.codex"
		}
		return filepath.Join(home, "app-server-control", "app-server-control.sock"), nil
	}
	handoffLookPath = func(file string) (string, error) {
		if file == "/custom/claude" || file == "claude" {
			return file, nil
		}
		return "", errors.New("not found")
	}
	handoffLoadConfig = func(string) (config.Config, error) { return cfg, nil }
}

func runHandoffForTest(t *testing.T, args ...string) (handoffCommand, error) {
	t.Helper()
	var out bytes.Buffer
	err := runHandoffCommandWithWriter(append([]string{"handoff-command"}, args...), &out)
	if err != nil {
		return handoffCommand{}, err
	}
	var command handoffCommand
	if err := json.Unmarshal(out.Bytes(), &command); err != nil {
		t.Fatalf("output is not JSON: %q", out.String())
	}
	return command, nil
}

func TestHandoffCommandCodexAttachesToSharedService(t *testing.T) {
	cfg := config.Config{}
	cfg.Codex.Env = map[string]string{"CODEX_HOME": "/Users/me/codex-home"}
	stubHandoffResolvers(t, cfg)
	dir := t.TempDir()
	command, err := runHandoffForTest(t, "--runtime", "codex", "--thread", "0190aaaa-bbbb-7ccc-8ddd-ffffffffffff", "--cwd", dir)
	if runtime.GOOS == "windows" {
		// Windows 的 Codex 共用服务不是 Unix socket，终端接不进去，必须明确拒绝而不是给出接不上的命令。
		if err == nil {
			t.Fatalf("windows must refuse terminal handoff, got %+v", command)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"/opt/codex/bin/codex", "resume", "0190aaaa-bbbb-7ccc-8ddd-ffffffffffff", "--remote",
		"unix:///Users/me/codex-home/app-server-control/app-server-control.sock"}
	if strings.Join(command.Argv, "|") != strings.Join(want, "|") || command.CWD != dir {
		t.Fatalf("command = %+v", command)
	}
	if command.Env["CODEX_HOME"] != "/Users/me/codex-home" || len(command.Env) != 1 {
		t.Fatalf("env = %v, want only CODEX_HOME", command.Env)
	}
}

func TestHandoffCommandCodexRefusesRemoteSSHTransport(t *testing.T) {
	cfg := config.Config{}
	cfg.AppServer.Transport = "ssh"
	stubHandoffResolvers(t, cfg)
	if _, err := runHandoffForTest(t, "--runtime", "codex", "--thread", "0190aaaa-bbbb", "--cwd", t.TempDir()); err == nil {
		t.Fatal("remote SSH backends cannot be continued in a local terminal")
	}
}

func TestHandoffCommandClaudePrefersAdapterCLI(t *testing.T) {
	cfg := config.Config{}
	cfg.Claude.Env = map[string]string{"CLAUDE_BRIDGE_CLAUDE_BIN": "/custom/claude"}
	stubHandoffResolvers(t, cfg)
	dir := t.TempDir()
	command, err := runHandoffForTest(t, "--runtime", "claude", "--thread", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--cwd", dir)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(command.Argv, " ") != "/custom/claude --resume aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" {
		t.Fatalf("argv = %v", command.Argv)
	}
	if command.Env != nil {
		t.Fatalf("env = %v, want none when CLAUDE_CONFIG_DIR is unset", command.Env)
	}

	// 配置的路径失效时退回 PATH 里的 claude。
	cfg.Claude.Env["CLAUDE_BRIDGE_CLAUDE_BIN"] = "/gone/claude"
	stubHandoffResolvers(t, cfg)
	command, err = runHandoffForTest(t, "--runtime", "claude", "--thread", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--cwd", dir)
	if err != nil || command.Argv[0] != "claude" {
		t.Fatalf("fallback argv = %v err = %v", command.Argv, err)
	}
}

func TestHandoffCommandRejectsUnsafeInput(t *testing.T) {
	stubHandoffResolvers(t, config.Config{})
	dir := t.TempDir()
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	cases := [][]string{
		{"--runtime", "codex", "--thread", "abc; rm -rf ~", "--cwd", dir},
		{"--runtime", "codex", "--thread", "'$(id)'-0000", "--cwd", dir},
		{"--runtime", "codex", "--thread", "0190aaaa-bbbb", "--cwd", "relative/path"},
		{"--runtime", "codex", "--thread", "0190aaaa-bbbb", "--cwd", file},
		{"--runtime", "codex", "--thread", "0190aaaa-bbbb", "--cwd", filepath.Join(dir, "missing")},
		{"--runtime", "deepseek", "--thread", "0190aaaa-bbbb", "--cwd", dir},
	}
	for _, args := range cases {
		if _, err := runHandoffForTest(t, args...); err == nil {
			t.Errorf("expected rejection for %v", args)
		}
	}
}

// 适配器在 CLAUDE_CONFIG_DIR 下找会话；终端不带上它就会去默认目录，接不上这条会话。
func TestHandoffCommandCarriesSessionLocationOnly(t *testing.T) {
	cfg := config.Config{}
	cfg.Claude.Env = map[string]string{
		"CLAUDE_CONFIG_DIR":        "/srv/claude-config",
		"ANTHROPIC_API_KEY":        "secret",
		"CLAUDE_BRIDGE_CLAUDE_BIN": "/custom/claude",
	}
	stubHandoffResolvers(t, cfg)
	command, err := runHandoffForTest(t, "--runtime", "claude", "--thread", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--cwd", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(command.Env) != 1 || command.Env["CLAUDE_CONFIG_DIR"] != "/srv/claude-config" {
		t.Fatalf("env = %v, want only CLAUDE_CONFIG_DIR", command.Env)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}
	if got := handoffEnv("claude", map[string]string{"CLAUDE_CONFIG_DIR": "~/claude-alt"}); got["CLAUDE_CONFIG_DIR"] != filepath.Join(home, "claude-alt") {
		t.Fatalf("tilde not expanded: %v", got)
	}
}
