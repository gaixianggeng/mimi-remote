package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

// handoffCommand 是在本机终端继续一条会话所需的命令（#991）。电脑端 App 拿它生成终端脚本；
// 这里只读配置、不启动任何进程，路径解析与服务端保持一致。
type handoffCommand struct {
	CWD  string   `json:"cwd"`
	Argv []string `json:"argv"`
	// Env 是终端里必须与 Mimi 保持一致的环境变量，否则会去另一个目录找会话。
	Env map[string]string `json:"env,omitempty"`
}

// 只透传决定会话存放位置的变量；其余配置（代理、令牌等）不进终端脚本。
var handoffEnvKeys = map[string][]string{
	"codex":  {"CODEX_HOME"},
	"claude": {"CLAUDE_CONFIG_DIR"},
}

func handoffEnv(runtimeID string, env map[string]string) map[string]string {
	out := map[string]string{}
	for _, key := range handoffEnvKeys[runtimeID] {
		value := strings.TrimSpace(env[key])
		if value == "" {
			continue
		}
		if value == "~" || strings.HasPrefix(value, "~/") {
			if home, err := os.UserHomeDir(); err == nil {
				value = filepath.Join(home, strings.TrimPrefix(value, "~"))
			}
		}
		out[key] = value
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// 会话 ID 只允许字母、数字和连字符：它会进入终端脚本的参数。
var handoffThreadIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{7,63}$`)

// 测试替换点。
var (
	handoffResolveCodexBin  = agentsetup.ResolveCodexBin
	handoffSharedSocketPath = appserver.SharedLocalSocketPath
	handoffLookPath         = exec.LookPath
	handoffLoadConfig       = config.LoadForDoctor
)

func runHandoffCommand(args []string) error {
	return runHandoffCommandWithWriter(args, os.Stdout)
}

func runHandoffCommandWithWriter(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("handoff-command", flag.ContinueOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	runtimeID := fs.String("runtime", "", "codex 或 claude")
	threadID := fs.String("thread", "", "会话 ID")
	cwd := fs.String("cwd", "", "会话的工作目录（绝对路径）")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if !handoffThreadIDPattern.MatchString(*threadID) {
		return errors.New("handoff-command --thread 不是有效的会话 ID")
	}
	dir := filepath.Clean(strings.TrimSpace(*cwd))
	if !filepath.IsAbs(dir) {
		return errors.New("handoff-command --cwd 必须是绝对路径")
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return fmt.Errorf("会话的工作目录不存在：%s", dir)
	}
	cfg, err := handoffLoadConfig(*configPath)
	if err != nil {
		return err
	}
	command, err := buildHandoffCommand(cfg, strings.TrimSpace(*runtimeID), *threadID, dir)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(out)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(command)
}

func buildHandoffCommand(cfg config.Config, runtimeID, threadID, cwd string) (handoffCommand, error) {
	switch runtimeID {
	case "codex":
		// 终端接入与 Mimi 相同的共用服务，两边可以同时使用，不产生写入冲突。
		if !appserver.SupportsSharedLocalTransport() {
			return handoffCommand{}, errors.New("这台电脑不支持在终端接入共用的 Codex 服务")
		}
		if strings.EqualFold(strings.TrimSpace(cfg.AppServer.Transport), "ssh") {
			return handoffCommand{}, errors.New("Codex 服务在另一台主机上，不能在这台电脑的终端里继续")
		}
		bin, err := handoffResolveCodexBin(cfg.Codex.Bin)
		if err != nil {
			return handoffCommand{}, fmt.Errorf("找不到 Codex CLI：%w", err)
		}
		socket, err := handoffSharedSocketPath(cfg.Codex.Env)
		if err != nil {
			return handoffCommand{}, err
		}
		return handoffCommand{
			CWD:  cwd,
			Argv: []string{bin, "resume", threadID, "--remote", "unix://" + socket},
			Env:  handoffEnv("codex", cfg.Codex.Env),
		}, nil
	case "claude":
		// Mimi 的适配器发现终端里的 claude 接手后会自动让出（#658）。
		bin, err := handoffClaudeBin(cfg)
		if err != nil {
			return handoffCommand{}, err
		}
		return handoffCommand{CWD: cwd, Argv: []string{bin, "--resume", threadID}, Env: handoffEnv("claude", cfg.Claude.Env)}, nil
	default:
		return handoffCommand{}, errors.New("handoff-command --runtime 只能是 codex 或 claude")
	}
}

// handoffClaudeBin 优先用适配器实际使用的 CLI，保证终端与 Mimi 是同一个版本。
func handoffClaudeBin(cfg config.Config) (string, error) {
	if configured := strings.TrimSpace(cfg.Claude.Env["CLAUDE_BRIDGE_CLAUDE_BIN"]); configured != "" {
		if resolved, err := handoffLookPath(configured); err == nil {
			return resolved, nil
		}
	}
	if resolved, err := handoffLookPath("claude"); err == nil {
		return resolved, nil
	}
	if home, err := os.UserHomeDir(); err == nil {
		if resolved, err := handoffLookPath(filepath.Join(home, ".local", "bin", "claude")); err == nil {
			return resolved, nil
		}
	}
	return "", errors.New("找不到 Claude Code CLI")
}
