package claudebridge

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ResolveBinary 解析实际要运行的 Claude bridge。默认是随包的 SDK 适配器（#660）；legacy 是保留
// 一个版本周期的回退开关，打开时改用旧 Rust bridge。
//   - 完整 Mac App 固定使用随包文件，避免外置版本覆盖 App 自带的兼容运行时。
//   - 普通 CLI：配置明确指向别的程序（例如开发时自己构建的适配器）时照用；配置是旧 bridge 的
//     默认名或安装路径时，按开关选随包文件。没有随包适配器的安装（Homebrew、Linux 发布包）
//     继续用旧 bridge。
//
// Gateway、配置校验、Setup 和 Doctor 必须共用这条规则，否则会出现状态分裂。
func ResolveBinary(command string, legacy bool) (string, bool) {
	return resolveBinary(command, runningExecutablePath(), legacy)
}

// BundledAvailable 报告运行中 agentd 同目录是否随包提供了适配器或旧 bridge。
func BundledAvailable() bool {
	executable := runningExecutablePath()
	_, adapter := resolveExecutable(siblingPath(executable, AdapterBinaryName))
	_, bridge := resolveExecutable(siblingPath(executable, BinaryName))
	return adapter || bridge
}

// BundledSiblingPath 返回运行中 agentd 同目录的旧 bridge 路径；无法取得当前可执行文件路径时
// 返回空字符串。
func BundledSiblingPath() string {
	return siblingPath(runningExecutablePath(), BinaryName)
}

// resolveBinary 接收可注入的 agentd 路径，保证选择逻辑可在不读取用户真实配置、也不依赖当前
// 测试进程位置的情况下确定性验证。
func resolveBinary(command, executable string, legacy bool) (string, bool) {
	adapter := siblingPath(executable, AdapterBinaryName)
	bundledBridge := siblingPath(executable, BinaryName)
	if isMacAppAgentdPath(executable) {
		// Mac App 的 Resources 与 agentd 同包发布，固定用随包文件；回退开关要求的文件不在
		// 包里时用另一份，仍不去 PATH 里找外置版本。
		pinned := []string{adapter, bundledBridge}
		if legacy {
			pinned = []string{bundledBridge, adapter}
		}
		for _, candidate := range pinned {
			if path, ok := resolveExecutable(candidate); ok {
				return path, true
			}
		}
	}
	if explicitBridgeCommand(command) {
		if path, ok := resolveExecutable(command); ok {
			return path, true
		}
	}
	candidates := []string{adapter, command, bundledBridge}
	if legacy {
		candidates = []string{command, bundledBridge, adapter}
	}
	for _, candidate := range candidates {
		if path, ok := resolveExecutable(candidate); ok {
			return path, true
		}
	}
	return strings.TrimSpace(command), false
}

// explicitBridgeCommand 判断配置是否明确指向别的程序。空值、旧 bridge 的默认名或它的安装路径
// 是旧版本写下的默认配置，不代表要固定旧实现；切回旧实现用回退开关。
func explicitBridgeCommand(command string) bool {
	command = strings.TrimSpace(command)
	if command == "" {
		return false
	}
	base := strings.ToLower(filepath.Base(strings.ReplaceAll(command, `\`, "/")))
	return strings.TrimSuffix(base, ".exe") != "alleycat-claude-bridge"
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
