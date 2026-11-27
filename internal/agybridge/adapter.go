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
	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
)

const (
	AgyBinaryEnvKey     = "AGY_ADAPTER_AGY_BIN"
	AgyGeminiDirEnvKey  = "AGY_ADAPTER_GEMINI_DIR"
	AgyAppDataDirEnvKey = "AGY_ADAPTER_APP_DATA_DIR"
)

type AgyAuthState string

const (
	AgyAuthSignedIn  AgyAuthState = "signed_in"
	AgyAuthSignedOut AgyAuthState = "signed_out"
	AgyAuthUnknown   AgyAuthState = "unknown"
)

type AdapterCapabilities struct {
	Name                      string   `json:"name"`
	Version                   string   `json:"version"`
	Methods                   []string `json:"methods"`
	FullAccess                bool     `json:"fullAccess"`
	PreserveThreadPermissions bool     `json:"preserveThreadPermissions,omitempty"`
	Agy                       struct {
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
	output, err := cliinspect.Stdout(ctx, path, env, append(append([]string{}, args...), "--capabilities")...)
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
	output, err := cliinspect.Run(ctx, bin, env, "--version")
	if err != nil {
		return "", err
	}
	version, ok := ParseVersion(string(output))
	if !ok {
		return "", errors.New("agy 没有返回标准语义化版本号")
	}
	return version, nil
}

func envLookup(env []string, key string) string {
	prefix := key + "="
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(entry, prefix))
		}
	}
	return ""
}

// AgyAccountArgs 返回真实 `agy` CLI 全局支持的账号/数据目录参数（B11）：
// 实测 `agy 1.5.14` 仅在根命令层级接受下划线全局参数 `--gemini_dir` / `--app_data_dir`
// （子命令 `agy models --gemini-dir ...` 会触发 Usage 错误）；
// 当配置了隔离目录时必须置于 `models` 子命令之前，使登录探测与真实 ACP 账户一致。
func AgyAccountArgs(env []string) []string {
	var args []string
	if geminiDir := envLookup(env, AgyGeminiDirEnvKey); geminiDir != "" && geminiDir != ".gemini" {
		args = append(args, "--gemini_dir", geminiDir)
	}
	if appDataDir := envLookup(env, AgyAppDataDirEnvKey); appDataDir != "" && appDataDir != "antigravity-cli" {
		args = append(args, "--app_data_dir", appDataDir)
	}
	return args
}

// AgyModelsArgs 构造 `agy [--gemini_dir ...] [--app_data_dir ...] models` 参数序列。
func AgyModelsArgs(env []string) []string {
	return append(AgyAccountArgs(env), "models")
}

// AgyAuthCacheKey 返回用于缓存登录探测结果的账户隔离键（包含 HOME 与隔离目录参数）。
func AgyAuthCacheKey(env []string) string {
	parts := append([]string{"HOME=" + envLookup(env, "HOME")}, AgyAccountArgs(env)...)
	return strings.Join(parts, "\x00")
}

// CheckAgySignedIn 执行无副作用的 `agy [global flags] models` 探测登录态：
// 实测未登录时返回非零退出码并提示 "Please sign in to view available models"；
// 冷启动首次拉取远端模型列表约需 7-10 秒，因此默认预留 15 秒超时。
func CheckAgySignedIn(ctx context.Context, bin string, env []string) (bool, string) {
	state, msg := CheckAgyAuthStatus(ctx, bin, env)
	return state == AgyAuthSignedIn, msg
}

// CheckAgyAuthStatus 区分已登录（signed_in）、明确未登录（signed_out）与探测未知（unknown，例如超时或参数/网络故障），
// 并以 `agy 1.5.14+` 实际支持的全局参数位置传入与真实 ACP 一致的账户目录配置（B11）。
// 未知状态不得当成已就绪缓存，也不得在启用入口被误归为未登录。
func CheckAgyAuthStatus(ctx context.Context, bin string, env []string) (AgyAuthState, string) {
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
	}
	args := AgyModelsArgs(env)
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = env
	output, err := cmd.CombinedOutput()
	if err == nil {
		return AgyAuthSignedIn, ""
	}
	text := strings.TrimSpace(string(output))
	if IsAgySignedOutOutput(text) {
		return AgyAuthSignedOut, "Antigravity CLI 尚未登录，请在终端运行 agy 完成登录"
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return AgyAuthUnknown, "Antigravity CLI 登录状态探测超时，正在重试确认"
	}
	return AgyAuthUnknown, firstLineOrFallback(text, "无法确认 Antigravity CLI 登录状态，正在重试确认")
}

// CheckAgySignedOut 仅在 `agy models` 明确输出未登录/需认证提示时返回 signedOut=true。
func CheckAgySignedOut(ctx context.Context, bin string, env []string) (bool, string) {
	state, msg := CheckAgyAuthStatus(ctx, bin, env)
	if state == AgyAuthSignedOut {
		return true, msg
	}
	return false, ""
}

func IsAgySignedOutOutput(raw string) bool {
	lower := strings.ToLower(strings.TrimSpace(raw))
	return strings.Contains(lower, "sign in") ||
		strings.Contains(lower, "login") ||
		strings.Contains(lower, "authenticate") ||
		strings.Contains(lower, "authentication required")
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
