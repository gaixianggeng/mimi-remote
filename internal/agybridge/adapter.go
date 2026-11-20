package agybridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/claudeenv"
)

const AgyBinaryEnvKey = "AGY_ADAPTER_AGY_BIN"

type AdapterCapabilities struct {
	Name       string   `json:"name"`
	Version    string   `json:"version"`
	Methods    []string `json:"methods"`
	FullAccess bool     `json:"fullAccess"`
	Agy        struct {
		MinimumVersion string `json:"minimumVersion"`
	} `json:"agy"`
}

func ParseVersion(raw string) (string, bool) {
	return claudebridge.ParseVersion(raw)
}

func IsSupported(version string) bool {
	return claudebridge.Compare(version, MinimumVersion) >= 0
}

func UpgradeMessage(version string) string {
	if strings.TrimSpace(version) == "" {
		return fmt.Sprintf("未检测到有效的 Antigravity 适配器版本（需要 >= %s）", MinimumVersion)
	}
	return fmt.Sprintf("Antigravity 适配器 %s 过旧（需要 >= %s），请升级 Mimi Remote", version, MinimumVersion)
}

func AgyUpgradeMessage(version, minimum string) string {
	return fmt.Sprintf("Antigravity CLI %s 过旧，Mimi Remote 需要 %s 或更新版本。请升级 agy 后重试。", version, minimum)
}

func (c AdapterCapabilities) AgySupported(version string) bool {
	minimum := strings.TrimSpace(c.Agy.MinimumVersion)
	return minimum == "" || claudebridge.Compare(version, minimum) >= 0
}

func (c AdapterCapabilities) Supports(method string) bool {
	for _, declared := range c.Methods {
		if declared == method {
			return true
		}
	}
	return false
}

func ReadAdapterCapabilities(ctx context.Context, path string, args []string, env []string) (AdapterCapabilities, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, append(append([]string{}, args...), "--capabilities")...)
	cmd.Env = env
	output, err := cmd.Output()
	if err != nil {
		return AdapterCapabilities{}, err
	}
	return ParseAdapterCapabilities(bytes.TrimSpace(output))
}

func ParseAdapterCapabilities(output []byte) (AdapterCapabilities, error) {
	var capabilities AdapterCapabilities
	if err := json.Unmarshal(output, &capabilities); err != nil {
		return AdapterCapabilities{}, err
	}
	if len(capabilities.Methods) == 0 {
		return AdapterCapabilities{}, errors.New("Antigravity 适配器没有声明任何方法")
	}
	return capabilities, nil
}

// BuildEnv 构造受控适配器运行环境，并剥离宿主可能残留的 ANTIGRAVITY_* 与 __CFBundleIdentifier，
// 确保 agy 始终读写 CLI 会话目录（~/.gemini/antigravity-cli）而非桌面版目录。
func BuildEnv(custom map[string]string) []string {
	base := claudeenv.Build(custom)
	out := make([]string, 0, len(base))
	for _, entry := range base {
		key, _, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		if key == "__CFBundleIdentifier" || strings.HasPrefix(key, "ANTIGRAVITY_") {
			continue
		}
		out = append(out, entry)
	}
	return out
}

func BuildEnvMap(custom map[string]string) map[string]string {
	out := make(map[string]string, len(custom))
	for k, v := range custom {
		if k == "__CFBundleIdentifier" || strings.HasPrefix(k, "ANTIGRAVITY_") {
			continue
		}
		out[k] = v
	}
	return out
}

func AgyVersion(ctx context.Context, bin string, env []string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "--version")
	cmd.Env = env
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", err
	}
	version, ok := ParseVersion(string(output))
	if !ok {
		return "", errors.New("agy 没有返回标准语义化版本号")
	}
	return version, nil
}

// CheckAgySignedIn 执行无副作用的 `agy models` 探测登录态：
// 实测未登录时返回非零退出码并提示 "Please sign in to view available models"；
// 冷启动首次拉取远端模型列表约需 7-10 秒，因此预留 15 秒超时。
func CheckAgySignedIn(ctx context.Context, bin string, env []string) (bool, string) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "models")
	cmd.Env = env
	output, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(output))
	lower := strings.ToLower(text)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return false, "探测 Antigravity CLI 登录状态超时（agy models 未在 15 秒内返回）"
		}
		if strings.Contains(lower, "sign in") || strings.Contains(lower, "login") || strings.Contains(lower, "authenticate") {
			return false, "Antigravity CLI 尚未登录，请在终端运行 agy 完成登录"
		}
		return false, firstLineOrFallback(text, "无法确认 Antigravity CLI 登录状态")
	}
	return true, ""
}

func firstLineOrFallback(raw, fallback string) string {
	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			return trimmed
		}
	}
	return fallback
}
