package claudebridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// AdapterName 是基于 Claude Agent SDK 的适配器（bridges/claude-sdk）在 `--version`
// 输出里的名字。它的版本号与旧 Rust bridge 不在同一序列，能力不能按旧 bridge 的
// 版本门槛推断，必须读它自己用 `--capabilities` 声明的能力。
const AdapterName = "mimi-claude-adapter"

// AdapterCapabilities 是适配器 `--capabilities` 输出的能力声明。
type AdapterCapabilities struct {
	Methods    []string `json:"methods"`
	FullAccess bool     `json:"fullAccess"`
	// ClaudeCode.MinimumVersion 是适配器要求的 Claude Code 最低版本（#660 起声明，更早的适配器没有）。
	ClaudeCode struct {
		MinimumVersion string `json:"minimumVersion"`
	} `json:"claudeCode"`
}

// ReadAdapterCapabilities 运行适配器的 `--capabilities` 并解析能力声明。
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

// ClaudeCodeSupported 判断 Claude Code 版本是否满足适配器声明的下限；没有声明下限时视为满足，
// 版本无法比较（预发布或无法解析）时视为不满足。
func (c AdapterCapabilities) ClaudeCodeSupported(version string) bool {
	minimum := strings.TrimSpace(c.ClaudeCode.MinimumVersion)
	return minimum == "" || Compare(version, minimum) >= 0
}

// ClaudeCodeVersion 运行 `claude --version` 并解析三段式版本号。
func ClaudeCodeVersion(ctx context.Context, bin string, env []string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "--version")
	cmd.Env = env
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	version, ok := ParseVersion(string(output))
	if !ok {
		return "", errors.New("Claude Code 没有返回标准版本号")
	}
	return version, nil
}

// ClaudeCodeUpgradeMessage 是 Claude Code 低于适配器下限时给用户的提示。
func ClaudeCodeUpgradeMessage(version, minimum string) string {
	return fmt.Sprintf("Claude Code %s 过旧，Mimi Remote 需要 %s 或更新版本。请在终端运行 claude update 后重试。", version, minimum)
}

// IsAdapterVersionOutput 判断 `--version` 输出是否来自 SDK 适配器。
func IsAdapterVersionOutput(output string) bool {
	return strings.HasPrefix(strings.TrimSpace(output), AdapterName+" ")
}

// ParseAdapterCapabilities 解析能力声明；方法列表为空视为无效声明。
func ParseAdapterCapabilities(output []byte) (AdapterCapabilities, error) {
	var capabilities AdapterCapabilities
	if err := json.Unmarshal(output, &capabilities); err != nil {
		return AdapterCapabilities{}, err
	}
	if len(capabilities.Methods) == 0 {
		return AdapterCapabilities{}, errors.New("适配器没有声明任何方法")
	}
	return capabilities, nil
}

// Supports 判断适配器是否实现了某个方法。
func (c AdapterCapabilities) Supports(method string) bool {
	for _, declared := range c.Methods {
		if declared == method {
			return true
		}
	}
	return false
}
