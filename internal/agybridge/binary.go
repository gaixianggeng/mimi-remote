package agybridge

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	AdapterName    = "mimi-agy-adapter"
	MinimumVersion = "0.1.0"
	InstallHint    = "重新安装或升级 Mimi Remote，或在 config.json 配置 agy.adapter_bin"
)

// ResolveBinary 解析实际要运行的 mimi-agy-adapter：
//   - Mac App 固定使用随包 Resources 下的 mimi-agy-adapter；
//   - 普通 CLI 优先显式非默认路径，其次与运行中 agentd 同目录的随包文件，最后查 PATH。
func ResolveBinary(command string) (string, bool) {
	return resolveBinary(command, runningExecutablePath())
}

// BundledAvailable 报告运行中 agentd 同目录是否随包提供了 mimi-agy-adapter。
func BundledAvailable() bool {
	_, ok := resolveExecutable(siblingPath(runningExecutablePath(), AdapterBinaryName))
	return ok
}

func resolveBinary(command, executable string) (string, bool) {
	bundled := siblingPath(executable, AdapterBinaryName)
	if isMacAppAgentdPath(executable) {
		if path, ok := resolveExecutable(bundled); ok {
			return path, true
		}
	}
	if explicitAdapterCommand(command) {
		if path, ok := resolveExecutable(command); ok {
			return path, true
		}
	}
	for _, candidate := range []string{bundled, command} {
		if path, ok := resolveExecutable(candidate); ok {
			return path, true
		}
	}
	return strings.TrimSpace(command), false
}

func explicitAdapterCommand(command string) bool {
	command = strings.TrimSpace(command)
	if command == "" {
		return false
	}
	base := strings.ToLower(filepath.Base(strings.ReplaceAll(command, `\`, "/")))
	return strings.TrimSuffix(base, ".exe") != AdapterName
}

func runningExecutablePath() string {
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	return executable
}

func siblingPath(executable, name string) string {
	if strings.TrimSpace(executable) == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(executable), name)
}

func isMacAppAgentdPath(executable string) bool {
	clean := filepath.Clean(strings.TrimSpace(executable))
	if clean == "." || filepath.Base(clean) != "agentd" {
		return false
	}
	resources := filepath.Dir(clean)
	if filepath.Base(resources) != "Resources" {
		return false
	}
	contents := filepath.Dir(resources)
	if filepath.Base(contents) != "Contents" {
		return false
	}
	return strings.HasSuffix(filepath.Base(filepath.Dir(contents)), ".app")
}

func resolveExecutable(command string) (string, bool) {
	command = strings.TrimSpace(command)
	if command == "" {
		return "", false
	}
	if filepath.IsAbs(command) || strings.ContainsAny(command, `/\`) {
		info, err := os.Stat(command)
		if err != nil || !isExecutableFile(command, info) {
			return command, false
		}
		return command, true
	}
	path, err := exec.LookPath(command)
	if err != nil {
		return command, false
	}
	return path, true
}
