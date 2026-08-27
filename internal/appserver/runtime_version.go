package appserver

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const MinimumIndependentWriterVersion = "0.147.0"

var ErrIndependentWriterCapabilityUnavailable = errors.New("Codex single-writer capability unavailable")

var codexCLIVersionPattern = regexp.MustCompile(`(?m)^codex-cli[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\s*$`)

type CodexRuntimeVersionInfo struct {
	Path    string
	Version string
}

// ValidateIndependentCodexRuntime verifies the minimum Codex release that
// enforces the per-thread writer lock used by independent Desktop and Mimi
// app-server processes. Callers decide which platforms require this gate.
func ValidateIndependentCodexRuntime(ctx context.Context, bin string) (CodexRuntimeVersionInfo, error) {
	info, err := inspectCodexRuntimeVersion(ctx, bin)
	if err != nil {
		return CodexRuntimeVersionInfo{}, err
	}
	if !codexVersionAtLeast(info.Version, MinimumIndependentWriterVersion) {
		return CodexRuntimeVersionInfo{}, fmt.Errorf(
			"%w：%s 版本为 %s，需要 >= %s",
			ErrIndependentWriterCapabilityUnavailable,
			info.Path,
			info.Version,
			MinimumIndependentWriterVersion,
		)
	}
	return info, nil
}

func inspectCodexRuntimeVersion(ctx context.Context, bin string) (CodexRuntimeVersionInfo, error) {
	bin = strings.TrimSpace(bin)
	if bin == "" {
		bin = "codex"
	}
	resolved, err := exec.LookPath(bin)
	if err != nil {
		return CodexRuntimeVersionInfo{}, err
	}
	absolute, err := filepath.Abs(resolved)
	if err != nil {
		return CodexRuntimeVersionInfo{}, err
	}
	absolute = filepath.Clean(absolute)
	output, err := exec.CommandContext(ctx, absolute, "--version").CombinedOutput()
	if err != nil {
		return CodexRuntimeVersionInfo{}, fmt.Errorf("执行 Codex 版本检查失败：%w", err)
	}
	match := codexCLIVersionPattern.FindStringSubmatch(strings.TrimSpace(string(output)))
	if len(match) != 2 {
		return CodexRuntimeVersionInfo{}, fmt.Errorf(
			"%w：无法识别 %s 的版本输出",
			ErrIndependentWriterCapabilityUnavailable,
			absolute,
		)
	}
	return CodexRuntimeVersionInfo{Path: absolute, Version: match[1]}, nil
}

func codexVersionAtLeast(version string, minimum string) bool {
	left, leftPre, leftOK := daemonVersionParts(version)
	right, rightPre, rightOK := daemonVersionParts(minimum)
	if !leftOK || !rightOK {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return left[index] > right[index]
		}
	}
	if leftPre == rightPre {
		return true
	}
	return rightPre || !leftPre
}

func daemonVersionParts(version string) ([3]int, bool, bool) {
	var result [3]int
	base, suffix, _ := strings.Cut(strings.TrimSpace(version), "-")
	parts := strings.Split(base, ".")
	if len(parts) != len(result) {
		return result, suffix != "", false
	}
	for index, part := range parts {
		value, err := strconv.Atoi(part)
		if err != nil || value < 0 {
			return result, suffix != "", false
		}
		result[index] = value
	}
	return result, suffix != "", true
}
