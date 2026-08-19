//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	// SharedDaemonLaunchAgentLabel 是 Mimi 安装的 LaunchAgent 标签。job 直接执行
	// OpenAI 签名的 node supervisor；Mimi/agentd 不进入 Browser 原生 peer 校验
	// 所读取的三级父链。
	SharedDaemonLaunchAgentLabel = "com.gaixianggeng.mimi.codex-shared-daemon"

	sharedDaemonLaunchAgentLogName         = "codex-shared-daemon.log"
	sharedDaemonMigrationFlagName          = "codex-shared-daemon-migration-required"
	sharedDaemonEnablePreparedFlagName     = "codex-shared-daemon-enable-prepared"
	sharedDaemonOperationLockName          = "codex-shared-daemon-operation.lock"
	sharedDaemonStartTimeout               = 20 * time.Second
	sharedDaemonStartTimeoutForLocalEnsure = sharedDaemonStartTimeout
	sharedDaemonStopTimeout                = 15 * time.Second
	sharedDaemonStoppedConfirmationWindow  = 500 * time.Millisecond
	sharedDaemonRunAtLoadGrace             = time.Second
	sharedDaemonSocketPollInterval         = 100 * time.Millisecond
	launchctlTimeout                       = 10 * time.Second
	sharedDaemonMaxLogBytes                = 1 << 20
	sharedDaemonLogDiagnosticBytes         = 64 << 10
	unmanagedSharedDaemonMessage           = "not managed by codex app-server daemon"
	codexDesktopBundleID                   = "com.openai.codex"
)

// SupportsStableSharedDaemonOwner 明确标识“完整共享架构”的平台边界。该
// 架构依赖 launchd LaunchAgent 与 macOS responsible-process/TCC 语义。
func SupportsStableSharedDaemonOwner() bool { return true }

type sharedDaemonListenerProcess struct {
	PID        int
	ParentPID  int
	UID        int
	StartSec   int64
	StartUsec  int32
	Command    string
	Executable string
}

type unmanagedSharedDaemonHooks struct {
	desktopRunning func(context.Context) (bool, error)
	inspect        func(context.Context, string) (sharedDaemonListenerProcess, error)
	signalTERM     func(int) error
	currentUID     func() int
}

// SysctlKinfoProc 在进程刚退出的极窄窗口里可能返回 EIO，而不是 ESRCH。
// 这里保留 seam 让退出复核能够覆盖该真实 Darwin 行为；signal 0 只用于确认
// PID 是否已经消失，不能替代启动时间与 UID 的完整身份校验。
var (
	sharedDaemonStoppedKinfoProc = unix.SysctlKinfoProc
	sharedDaemonSignalZero       = func(pid int) error { return unix.Kill(pid, 0) }
)

// SharedDaemonOwnerStatus 描述 Mimi 为共享 app-server 安装的稳定启动入口。它只
// 证明 launchd job 的安装状态；Browser/TCC 仍需对真实 socket peer 父链验收。
type SharedDaemonOwnerStatus struct {
	Supported         bool
	Installed         bool
	Loaded            bool
	Running           bool
	Secure            bool
	RunAtLoad         bool
	Changed           bool
	Created           bool
	MigrationRequired bool
	Path              string
	Label             string
	Rollback          *SharedDaemonOwnerRollback
}

// sharedDaemonStrippedEnvKeys 与 buildManagedEnv 的过滤集合保持一致：这些键只属于
// Codex Desktop 的 Electron 进程。LaunchAgent 会继承 launchd 用户域环境，而 Mac App
// 正是用 `launchctl setenv` 为 Desktop 写入它们，因此 job 必须显式以空值覆盖，
// 避免把 Desktop 的传输配置扩散给 daemon。
var sharedDaemonStrippedEnvKeys = []string{
	LocalDaemonEnvironmentKey,
	"CODEX_APP_SERVER_WS_URL",
	"MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH",
	// supervisor 通过 node -e 执行固定内联脚本。继承 NODE_OPTIONS/require
	// 等控制面会允许用户环境在脚本前加载额外代码，必须以空值覆盖。
	"NODE_OPTIONS",
	"NODE_PATH",
	"NODE_REPL_EXTERNAL_MODULE",
	"NODE_REDIRECT_WARNINGS",
	"NODE_V8_COVERAGE",
}

var sharedDaemonRequiredToolPaths = []string{
	"/opt/homebrew/bin",
	"/opt/homebrew/sbin",
	"/usr/local/bin",
	"/usr/bin",
	"/bin",
	"/usr/sbin",
	"/sbin",
}

// 测试只替换这一层，避免单元测试注册或卸载用户真实的 launchd job。
var sharedDaemonLaunchctl = runLaunchctl

// Desktop 存活检查使用固定 bundle id。显式迁移的 stop 与 kickstart 都在各自
// 最后副作用前重新读取；查询失败和 App 已重开一律 fail closed。
var sharedDaemonDesktopRunning = codexDesktopProcessRunning

// 删除路径单独留出测试 seam，验证 bootout 后删除/marker 失败会恢复完整 owner；
// 正式运行始终指向 os.Remove 与真实 marker 清理。
var (
	sharedDaemonRemoveLaunchAgentFile    = os.Remove
	sharedDaemonClearMigrationForRemoval = clearSharedDaemonMigrationFlag
)

// SharedDaemonLaunchAgentPath 返回 plist 的安装路径。
func SharedDaemonLaunchAgentPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("解析用户 Home 失败：%w", err)
	}
	return filepath.Join(home, "Library", "LaunchAgents", SharedDaemonLaunchAgentLabel+".plist"), nil
}

func sharedDaemonLaunchAgentLogPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("解析用户 Home 失败：%w", err)
	}
	return filepath.Join(home, "Library", "Logs", "mimi-remote", sharedDaemonLaunchAgentLogName), nil
}

func sharedDaemonMigrationFlagPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("解析用户 Home 失败：%w", err)
	}
	return filepath.Join(home, "Library", "Application Support", "mimi-remote", sharedDaemonMigrationFlagName), nil
}

func sharedDaemonEnablePreparedFlagPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("解析用户 Home 失败：%w", err)
	}
	return filepath.Join(home, "Library", "Application Support", "mimi-remote", sharedDaemonEnablePreparedFlagName), nil
}

func sharedDaemonOperationLockPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("解析用户 Home 失败：%w", err)
	}
	return filepath.Join(home, "Library", "Application Support", "mimi-remote", sharedDaemonOperationLockName), nil
}

// withSharedDaemonOperationLock 跨进程序列化启动、gateway 恢复与显式迁移。
// 仅靠 Router mutex 无法阻止独立 runtime CLI 在 stop/start 中间被另一进程插入。
func withSharedDaemonOperationLock(
	ctx context.Context,
	operation func() (LocalDaemonStatus, error),
) (LocalDaemonStatus, error) {
	path, err := sharedDaemonOperationLockPath()
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("创建共享 daemon 锁目录失败：%w", err)
	}
	if info, statErr := os.Lstat(path); statErr == nil {
		if !info.Mode().IsRegular() {
			return LocalDaemonStatus{}, fmt.Errorf("共享 daemon 操作锁必须是普通文件")
		}
	} else if !os.IsNotExist(statErr) {
		return LocalDaemonStatus{}, fmt.Errorf("检查共享 daemon 操作锁失败：%w", statErr)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("打开共享 daemon 操作锁失败：%w", err)
	}
	defer file.Close()
	if err := file.Chmod(0o600); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("收紧共享 daemon 操作锁权限失败：%w", err)
	}
	for {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN {
			return LocalDaemonStatus{}, fmt.Errorf("获取共享 daemon 操作锁失败：%w", err)
		}
		select {
		case <-ctx.Done():
			return LocalDaemonStatus{}, ctx.Err()
		case <-time.After(sharedDaemonSocketPollInterval):
		}
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	return operation()
}

// resolveSharedDaemonCodexBin 把配置里的 codex 路径解析成绝对路径。launchd 不做
// PATH 查找，相对路径会让 job 在登录后静默失败。
func resolveSharedDaemonCodexBin(configured string) (string, error) {
	bin := strings.TrimSpace(configured)
	if bin == "" {
		bin = "codex"
	}
	if !filepath.IsAbs(bin) {
		resolved, err := exec.LookPath(bin)
		if err != nil {
			return "", fmt.Errorf("未找到 codex 可执行文件：%w", err)
		}
		bin = resolved
	}
	absolute, err := filepath.Abs(bin)
	if err != nil {
		return "", fmt.Errorf("解析 codex 路径失败：%w", err)
	}
	canonical, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", fmt.Errorf("解析 codex 真实路径失败：%w", err)
	}
	canonical = filepath.Clean(canonical)
	info, err := os.Stat(canonical)
	if err != nil {
		return "", fmt.Errorf("检查 codex 可执行文件失败：%w", err)
	}
	if info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("codex 路径不是可执行文件：%s", canonical)
	}
	// plist 固定到已验证版本的真实路径，避免 `current`/用户 bin symlink 在
	// codesign 检查与 launchd 执行之间被换到另一份未验证程序。
	return canonical, nil
}

// renderSharedDaemonLaunchAgent 生成 plist。ProgramArguments 直接执行 Codex
// Desktop 内置的签名 node，不引入 shell 或 Mimi 可执行文件。node 作为持久
// supervisor 直接拉起 app-server；最终仍需以 socket peer 父链做运行态验收。
func renderSharedDaemonLaunchAgent(
	nodeBin string,
	codexBin string,
	env map[string]string,
	logPath string,
	runAtLoadOption ...bool,
) ([]byte, error) {
	if strings.TrimSpace(nodeBin) == "" || strings.TrimSpace(codexBin) == "" {
		return nil, fmt.Errorf("node supervisor 与 codex 路径不能为空")
	}
	arguments := sharedDaemonSupervisorProgramArguments(nodeBin, codexBin)
	runAtLoad := true
	if len(runAtLoadOption) > 0 {
		runAtLoad = runAtLoadOption[0]
	}

	var buf bytes.Buffer
	buf.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	buf.WriteString(`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` + "\n")
	buf.WriteString(`<plist version="1.0">` + "\n<dict>\n")
	writePlistString(&buf, "Label", SharedDaemonLaunchAgentLabel)
	buf.WriteString("\t<key>ProgramArguments</key>\n\t<array>\n")
	for _, argument := range arguments {
		buf.WriteString("\t\t<string>")
		escapePlistText(&buf, argument)
		buf.WriteString("</string>\n")
	}
	buf.WriteString("\t</array>\n")

	// launchd 用户域的默认 maxfiles 可能只有 256；daemon 需要为多路客户端和
	// MCP 连接预留余量，因此只把 soft limit 受控提升到 8192。不设置 hard limit，
	// 避免 plist 绕过系统策略获得无限制的文件描述符权限。
	buf.WriteString("\t<key>SoftResourceLimits</key>\n\t<dict>\n")
	fmt.Fprintf(&buf, "\t\t<key>NumberOfFiles</key>\n\t\t<integer>%d</integer>\n", sharedDaemonSoftFileLimit)
	buf.WriteString("\t</dict>\n")

	if values := sharedDaemonLaunchAgentEnv(env); len(values) > 0 {
		buf.WriteString("\t<key>EnvironmentVariables</key>\n\t<dict>\n")
		keys := make([]string, 0, len(values))
		for key := range values {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			buf.WriteString("\t\t<key>")
			escapePlistText(&buf, key)
			buf.WriteString("</key>\n\t\t<string>")
			escapePlistText(&buf, values[key])
			buf.WriteString("</string>\n")
		}
		buf.WriteString("\t</dict>\n")
	}

	// 正常 owner 在登录时冷启动；进入 pending 后持久化为 false，保证注销、登录
	// 或 Mac 重启都不能绕过用户再次确认。显式迁移成功后才提升回 true。
	buf.WriteString("\t<key>RunAtLoad</key>\n")
	if runAtLoad {
		buf.WriteString("\t<true/>\n")
	} else {
		buf.WriteString("\t<false/>\n")
	}
	// supervisor 随 app-server 一并退出；KeepAlive=false 禁止 launchd 在 socket
	// 冲突或 child 崩溃时形成无界重启风暴，恢复仍由现有 gateway 路径触发。
	buf.WriteString("\t<key>KeepAlive</key>\n\t<false/>\n")
	buf.WriteString("\t<key>ThrottleInterval</key>\n\t<integer>1</integer>\n")
	buf.WriteString("\t<key>ExitTimeOut</key>\n\t<integer>20</integer>\n")
	// 077 的十进制是 63；确保 launchd 创建的 stdout/stderr 日志仅当前用户可读。
	buf.WriteString("\t<key>Umask</key>\n\t<integer>63</integer>\n")
	if strings.TrimSpace(logPath) != "" {
		writePlistString(&buf, "StandardOutPath", logPath)
		writePlistString(&buf, "StandardErrorPath", logPath)
	}
	buf.WriteString("</dict>\n</plist>\n")
	return buf.Bytes(), nil
}

// sharedDaemonLaunchAgentEnv 只写入 daemon 真正需要的变量。CODEX_HOME 决定 socket
// 位置，必须与 agentd 和 Desktop 解析结果完全一致，否则会再次分裂成两个进程。
func sharedDaemonLaunchAgentEnv(env map[string]string) map[string]string {
	values := map[string]string{}
	for key, value := range env {
		key = strings.TrimSpace(key)
		if key == "" || isSharedDaemonStrippedEnvKey(key) {
			continue
		}
		values[key] = value
	}
	values["PATH"] = normalizedSharedDaemonToolingPath(values["PATH"], os.Getenv("PATH"))
	// EnvironmentVariables 会覆盖 launchctl setenv 的用户域值。直接 ProgramArguments
	// 因此无需借 shell 执行 unset，启动链固定为 launchd -> node supervisor。
	for _, key := range sharedDaemonStrippedEnvKeys {
		values[key] = ""
	}
	return values
}

// normalizedSharedDaemonToolingPath 与 Mac App 的 userTooling 规则保持一致：
// 固定受信任的 Homebrew/系统目录，再追加调用进程能看到的绝对工具目录。相对
// 路径（尤其是 .）会让 LaunchAgent 的工作目录影响可执行文件解析，必须丢弃。
func normalizedSharedDaemonToolingPath(configured string, inherited string) string {
	candidates := append([]string{}, sharedDaemonRequiredToolPaths...)
	if strings.TrimSpace(configured) != "" {
		candidates = append(candidates, strings.Split(configured, ":")...)
	} else {
		candidates = append(candidates, strings.Split(inherited, ":")...)
	}
	seen := map[string]struct{}{}
	paths := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" || !filepath.IsAbs(candidate) {
			continue
		}
		candidate = filepath.Clean(candidate)
		if _, exists := seen[candidate]; exists {
			continue
		}
		seen[candidate] = struct{}{}
		paths = append(paths, candidate)
	}
	return strings.Join(paths, ":")
}

func sharedDaemonPlistStringValue(content []byte, targetKey string) string {
	decoder := xml.NewDecoder(bytes.NewReader(content))
	lastKey := ""
	for {
		token, err := decoder.Token()
		if err != nil {
			return ""
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		switch start.Name.Local {
		case "key":
			var key string
			if err := decoder.DecodeElement(&key, &start); err != nil {
				return ""
			}
			lastKey = key
		case "string":
			var value string
			if err := decoder.DecodeElement(&value, &start); err != nil {
				return ""
			}
			if lastKey == targetKey {
				return value
			}
			lastKey = ""
		case "array", "dict":
			// 该读取器只用于本文件生成的标量 EnvironmentVariables；遇到
			// 容器就清除位置状态，不能把数组首项误认为某个 key 的值。
			lastKey = ""
		}
	}
}

func sharedDaemonPlistBoolValue(content []byte, targetKey string) (bool, bool) {
	decoder := xml.NewDecoder(bytes.NewReader(content))
	lastKey := ""
	for {
		token, err := decoder.Token()
		if err != nil {
			return false, false
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		switch start.Name.Local {
		case "key":
			var key string
			if err := decoder.DecodeElement(&key, &start); err != nil {
				return false, false
			}
			lastKey = key
		case "true", "false":
			if lastKey == targetKey {
				return start.Name.Local == "true", true
			}
			lastKey = ""
		case "array", "dict", "string", "integer":
			lastKey = ""
		}
	}
}

func isSharedDaemonStrippedEnvKey(key string) bool {
	for _, stripped := range sharedDaemonStrippedEnvKeys {
		if key == stripped {
			return true
		}
	}
	return false
}

func writePlistString(buf *bytes.Buffer, key string, value string) {
	buf.WriteString("\t<key>")
	escapePlistText(buf, key)
	buf.WriteString("</key>\n\t<string>")
	escapePlistText(buf, value)
	buf.WriteString("</string>\n")
}

func escapePlistText(buf *bytes.Buffer, value string) {
	_ = xml.EscapeText(buf, []byte(value))
}

type sharedDaemonLaunchAgentPlan struct {
	path            string
	existing        []byte
	existingPresent bool
	desired         []byte
}

func planSharedDaemonLaunchAgent(
	options LocalDaemonOptions,
	runAtLoad bool,
) (sharedDaemonLaunchAgentPlan, error) {
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		return sharedDaemonLaunchAgentPlan{}, err
	}
	codexBin, err := resolveSharedDaemonCodexBin(options.CodexBin)
	if err != nil {
		return sharedDaemonLaunchAgentPlan{}, err
	}
	nodeBin, err := sharedDaemonResolveSupervisorNode(codexBin)
	if err != nil {
		return sharedDaemonLaunchAgentPlan{}, err
	}
	if err := sharedDaemonValidateSupervisor(nodeBin, codexBin); err != nil {
		return sharedDaemonLaunchAgentPlan{}, err
	}
	logPath, err := sharedDaemonLaunchAgentLogPath()
	if err != nil {
		return sharedDaemonLaunchAgentPlan{}, err
	}
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		return sharedDaemonLaunchAgentPlan{}, fmt.Errorf("创建 Mimi 日志目录失败：%w", err)
	}
	if info, statErr := os.Lstat(logPath); statErr == nil {
		if !info.Mode().IsRegular() {
			return sharedDaemonLaunchAgentPlan{}, fmt.Errorf("共享 daemon 日志必须是普通文件")
		}
		if err := os.Chmod(logPath, 0o600); err != nil {
			return sharedDaemonLaunchAgentPlan{}, fmt.Errorf("收紧共享 daemon 日志权限失败：%w", err)
		}
		if info.Size() > sharedDaemonMaxLogBytes {
			if err := os.Truncate(logPath, 0); err != nil {
				return sharedDaemonLaunchAgentPlan{}, fmt.Errorf("收缩共享 daemon 日志失败：%w", err)
			}
		}
	} else if !os.IsNotExist(statErr) {
		return sharedDaemonLaunchAgentPlan{}, fmt.Errorf("检查共享 daemon 日志失败：%w", statErr)
	}
	// 不依赖 launchctl 用户域里可能残留的 CODEX_HOME。这里固定与 agentd 本次
	// 解析出的 socket 完全一致的有效目录，避免 daemon 在 B 目录启动、agentd
	// 却在 A 目录等待。LocalDaemonSocketPath 同时完成绝对路径和符号链接规范化。
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return sharedDaemonLaunchAgentPlan{}, err
	}
	effectiveEnv := make(map[string]string, len(options.Env)+1)
	for key, value := range options.Env {
		effectiveEnv[key] = value
	}
	effectiveEnv["CODEX_HOME"] = filepath.Dir(filepath.Dir(socketPath))
	var existing []byte
	existingPresent := false
	if info, statErr := os.Lstat(path); statErr == nil {
		if !info.Mode().IsRegular() {
			return sharedDaemonLaunchAgentPlan{}, fmt.Errorf("共享 daemon LaunchAgent 必须是普通文件")
		}
		existingPresent = true
		existing, err = os.ReadFile(path)
		if err != nil {
			return sharedDaemonLaunchAgentPlan{}, fmt.Errorf("读取共享 daemon LaunchAgent 失败：%w", err)
		}
		// 配置未显式指定 PATH 时，保留首次由 Mac App 捕获并规范化的用户工具
		// 路径。否则 resident agentd 的较窄 PATH 会在每次启动时反复改写 owner。
		if strings.TrimSpace(effectiveEnv["PATH"]) == "" {
			effectiveEnv["PATH"] = sharedDaemonPlistStringValue(existing, "PATH")
		}
	} else if !os.IsNotExist(statErr) {
		return sharedDaemonLaunchAgentPlan{}, fmt.Errorf("检查共享 daemon LaunchAgent 失败：%w", statErr)
	}
	desired, err := renderSharedDaemonLaunchAgent(nodeBin, codexBin, effectiveEnv, logPath, runAtLoad)
	if err != nil {
		return sharedDaemonLaunchAgentPlan{}, err
	}
	return sharedDaemonLaunchAgentPlan{
		path:            path,
		existing:        existing,
		existingPresent: existingPresent,
		desired:         desired,
	}, nil
}

func applySharedDaemonLaunchAgentPlan(plan sharedDaemonLaunchAgentPlan) (bool, error) {
	if plan.existingPresent && bytes.Equal(plan.existing, plan.desired) {
		// 兼容早期 Beta 写出的 0644 plist：内容无需 reload，但权限必须原地
		// 收紧，避免为了 chmod 打断已经加载的 job。
		if info, statErr := os.Lstat(plan.path); statErr == nil && info.Mode().IsRegular() && info.Mode().Perm() != 0o600 {
			if err := os.Chmod(plan.path, 0o600); err != nil {
				return false, fmt.Errorf("收紧 LaunchAgent 权限失败：%w", err)
			}
		}
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(plan.path), 0o755); err != nil {
		return false, fmt.Errorf("创建 LaunchAgents 目录失败：%w", err)
	}
	// 先写临时文件再 rename，避免 launchd 在登录时读到半截 plist。
	temp, err := os.CreateTemp(filepath.Dir(plan.path), ".codex-shared-daemon-*.plist")
	if err != nil {
		return false, fmt.Errorf("写入 LaunchAgent 失败：%w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write(plan.desired); err != nil {
		temp.Close()
		return false, fmt.Errorf("写入 LaunchAgent 失败：%w", err)
	}
	// 配置中的自定义 env 可能包含 MCP/API 凭据。LaunchAgent 只需当前用户和
	// launchd 读取，必须与 agentd 配置一样保持 0600，不能泄露给其他本地用户。
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return false, fmt.Errorf("设置 LaunchAgent 权限失败：%w", err)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return false, fmt.Errorf("同步 LaunchAgent 失败：%w", err)
	}
	if err := temp.Close(); err != nil {
		return false, fmt.Errorf("写入 LaunchAgent 失败：%w", err)
	}
	if err := os.Rename(tempPath, plan.path); err != nil {
		return false, fmt.Errorf("安装 LaunchAgent 失败：%w", err)
	}
	if err := syncSharedDaemonDirectory(filepath.Dir(plan.path)); err != nil {
		return false, fmt.Errorf("同步 LaunchAgent 目录失败：%w", err)
	}
	return true, nil
}

func ensureSharedDaemonLaunchAgent(options LocalDaemonOptions, runAtLoad bool) (bool, error) {
	plan, err := planSharedDaemonLaunchAgent(options, runAtLoad)
	if err != nil {
		return false, err
	}
	return applySharedDaemonLaunchAgentPlan(plan)
}

// EnsureSharedDaemonLaunchAgent 安装正常冷启动 owner。进入人工迁移状态时必须
// 通过 ensureSharedDaemonOwner 写入 RunAtLoad=false，不能直接调用这个入口。
func EnsureSharedDaemonLaunchAgent(options LocalDaemonOptions) (bool, error) {
	return ensureSharedDaemonLaunchAgent(options, true)
}

func writeSharedDaemonPrivateFileAtomically(path string, content []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".mimi-shared-daemon-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write(content); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		return err
	}
	return syncSharedDaemonDirectory(filepath.Dir(path))
}

func syncSharedDaemonDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func syncSharedDaemonDirectoryIfPresent(path string) error {
	err := syncSharedDaemonDirectory(path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// SharedDaemonMigrationRequired 是提供给运行态状态接口的轻量读取；它不探测
// launchctl，也不触碰 daemon。标记若被替换为链接或公开文件则 fail closed。
func SharedDaemonMigrationRequired() (bool, error) {
	path, err := sharedDaemonMigrationFlagPath()
	if err != nil {
		return false, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("检查共享 daemon 迁移标记失败：%w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
		return false, fmt.Errorf("共享 daemon 迁移标记必须是当前用户私有的普通文件")
	}
	return true, nil
}

// SharedDaemonOwnerArtifactsPresent 是非 shared 启动路径的只读快路径；只有
// 真有 Mimi plist 或 marker 残留时才进入 launchctl 清理事务。
func SharedDaemonOwnerArtifactsPresent() (bool, error) {
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		return false, err
	}
	if info, statErr := os.Lstat(path); statErr == nil {
		if !info.Mode().IsRegular() {
			return false, fmt.Errorf("共享 daemon LaunchAgent 必须是普通文件")
		}
		return true, nil
	} else if !os.IsNotExist(statErr) {
		return false, statErr
	}
	if required, err := SharedDaemonMigrationRequired(); err != nil || required {
		return required, err
	}
	return sharedDaemonEnablePrepared()
}

func repairSharedDaemonMigrationFlagPermissions() error {
	path, err := sharedDaemonMigrationFlagPath()
	if err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("检查共享 daemon 迁移标记失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("共享 daemon 迁移标记必须是普通文件")
	}
	if info.Mode().Perm() != 0o600 {
		if err := os.Chmod(path, 0o600); err != nil {
			return fmt.Errorf("收紧共享 daemon 迁移标记权限失败：%w", err)
		}
	}
	return nil
}

// InspectSharedDaemonOwner 只读取 job/marker 状态，不启动或停止任何进程。
func InspectSharedDaemonOwner(ctx context.Context) (SharedDaemonOwnerStatus, error) {
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		return SharedDaemonOwnerStatus{}, err
	}
	status := SharedDaemonOwnerStatus{
		Supported: true,
		Path:      path,
		Label:     SharedDaemonLaunchAgentLabel,
	}
	info, statErr := os.Lstat(path)
	if statErr != nil {
		if !os.IsNotExist(statErr) {
			return status, fmt.Errorf("检查共享 daemon LaunchAgent 失败：%w", statErr)
		}
	} else {
		if !info.Mode().IsRegular() {
			return status, fmt.Errorf("共享 daemon LaunchAgent 必须是普通文件")
		}
		status.Installed = true
		status.Secure = info.Mode().Perm()&0o077 == 0
		content, readErr := os.ReadFile(path)
		if readErr != nil {
			return status, fmt.Errorf("读取共享 daemon LaunchAgent 失败：%w", readErr)
		}
		// 缺少 RunAtLoad 或 plist 无法解析时按 manual 处理；这是崩溃恢复的
		// fail-closed 方向，后续 ensure 会补回 marker，绝不猜成可自动启动。
		status.RunAtLoad, _ = sharedDaemonPlistBoolValue(content, "RunAtLoad")
	}
	status.Loaded, status.Running, err = inspectLaunchAgentState(ctx)
	if err != nil {
		return status, err
	}
	status.MigrationRequired, err = SharedDaemonMigrationRequired()
	if err != nil {
		return status, err
	}
	return status, nil
}

// EnsureSharedDaemonOwner 幂等安装并加载稳定 job。daemonPreexisting 表示调用前已有
// 可握手 socket；若本次同时改变了 owner，就写入持久迁移标记，等待用户明确点击
// “应用待处理设置”并确认后再切换，绝不在设置过程中静默中断原生 Codex。
func EnsureSharedDaemonOwner(
	ctx context.Context,
	options LocalDaemonOptions,
	daemonPreexisting bool,
) (SharedDaemonOwnerStatus, error) {
	return ensureSharedDaemonOwner(ctx, options, daemonPreexisting, false)
}

func ensureSharedDaemonOwner(
	ctx context.Context,
	options LocalDaemonOptions,
	daemonPreexisting bool,
	forcePending bool,
) (SharedDaemonOwnerStatus, error) {
	if err := repairSharedDaemonMigrationFlagPermissions(); err != nil {
		return SharedDaemonOwnerStatus{}, err
	}
	before, err := InspectSharedDaemonOwner(ctx)
	if err != nil {
		return SharedDaemonOwnerStatus{}, err
	}
	var previousPlist []byte
	if before.Installed {
		previousPlist, err = os.ReadFile(before.Path)
		if err != nil {
			return SharedDaemonOwnerStatus{}, fmt.Errorf("读取原共享 daemon LaunchAgent 失败：%w", err)
		}
	}
	// manual plist 本身就是持久 pending 证据。若进程在“写 manual plist → 写
	// marker”之间崩溃，下一次 ensure 必须先补回 marker，再做任何 launchctl 操作。
	pendingStateBefore := before.MigrationRequired || (before.Installed && !before.RunAtLoad)
	markerRepaired := false
	if before.Installed && !before.RunAtLoad && !before.MigrationRequired {
		if err := writeSharedDaemonMigrationFlag(); err != nil {
			return SharedDaemonOwnerStatus{}, fmt.Errorf("恢复待迁移标记失败：%w", err)
		}
		before.MigrationRequired = true
		markerRepaired = true
	}

	autoPlan, err := planSharedDaemonLaunchAgent(options, true)
	if err != nil {
		return SharedDaemonOwnerStatus{}, err
	}
	autoChanged := !autoPlan.existingPresent || !bytes.Equal(autoPlan.existing, autoPlan.desired)
	manualDesired, err := sharedDaemonManualPlist(autoPlan.desired)
	if err != nil {
		return SharedDaemonOwnerStatus{}, err
	}
	pending := before.MigrationRequired || forcePending ||
		(daemonPreexisting && (autoChanged || !before.Loaded))
	plan := autoPlan
	if pending {
		// node/codex 的完整 Developer ID 校验最昂贵，也会 fork codesign。manual
		// 与 auto 只差 RunAtLoad，直接从同一份已验证 plan 派生，避免同次 ensure
		// 重复 6 个签名/metadata 子进程并扩大 socket 竞态窗口。
		plan.desired = manualDesired
	}
	fileChanged, err := applySharedDaemonLaunchAgentPlan(plan)
	if err != nil {
		return SharedDaemonOwnerStatus{}, err
	}
	created := !before.Installed
	launchctlChanged := false
	rollback := func(cause error) (SharedDaemonOwnerStatus, error) {
		rollbackCtx, cancel := context.WithTimeout(context.Background(), 2*launchctlTimeout)
		defer cancel()
		var rollbackErr error
		if launchctlChanged && !sharedDaemonSocketAcceptsConnectionMust(options) {
			rollbackErr = restoreSharedDaemonOwner(rollbackCtx, before, previousPlist)
		} else {
			rollbackErr = restoreSharedDaemonOwnerFilesOnly(before, previousPlist)
		}
		if rollbackErr != nil {
			return SharedDaemonOwnerStatus{}, fmt.Errorf("%w；恢复原 daemon owner 也失败：%v", cause, rollbackErr)
		}
		return SharedDaemonOwnerStatus{}, fmt.Errorf("%w；已恢复原 daemon owner", cause)
	}
	markerPresent := before.MigrationRequired
	ensurePendingMarker := func() error {
		if !pending || markerPresent {
			return nil
		}
		if err := writeSharedDaemonMigrationFlag(); err != nil {
			return err
		}
		markerPresent = true
		return nil
	}
	// 入口探测到“无 listener”不构成跨越 codesign/落盘窗口的租约。每个
	// launchctl 副作用前重新探测；一旦 socket 已出现，就把刚写的 auto plist
	// 收敛为 manual+marker，并保留当前 loaded job，绝不 bootout 活跃 coalition。
	stagePendingIfListenerAppeared := func() (bool, error) {
		if !sharedDaemonSocketAcceptsConnectionMust(options) {
			return false, nil
		}
		if !pending {
			manualPlan := autoPlan
			manualPlan.desired = manualDesired
			changed, applyErr := applySharedDaemonLaunchAgentPlan(manualPlan)
			if applyErr != nil {
				return true, applyErr
			}
			fileChanged = fileChanged || changed
			pending = true
		}
		if err := ensurePendingMarker(); err != nil {
			return true, err
		}
		return true, nil
	}
	if err := ensurePendingMarker(); err != nil {
		return rollback(err)
	}
	loaded := before.Loaded
	listenerActive := daemonPreexisting
	if fileChanged || !loaded {
		observedActive, stageErr := stagePendingIfListenerAppeared()
		if stageErr != nil {
			return rollback(stageErr)
		}
		listenerActive = listenerActive || observedActive
	}
	// 已有 listener 时只 stage 新的 manual plist + marker，不能在用户确认前
	// bootout 当前 job。虽然旧官方 daemon 通常已经 detached，launchd 仍可能按
	// service coalition 回收后代；显式迁移会在 socket 完全停止后再 reload。
	deferReloadUntilMigration := fileChanged && loaded && (daemonPreexisting || listenerActive)
	if fileChanged && loaded && !deferReloadUntilMigration {
		listenerActive, err = stagePendingIfListenerAppeared()
		if err != nil {
			return rollback(err)
		}
		deferReloadUntilMigration = listenerActive
	}
	if fileChanged && loaded && !deferReloadUntilMigration {
		if _, bootoutErr := sharedDaemonLaunchctl(ctx, "bootout", launchAgentServiceTarget()); bootoutErr != nil &&
			!isLaunchctlNotLoaded(bootoutErr) {
			return rollback(bootoutErr)
		}
		loaded = false
		launchctlChanged = true
	}
	if !loaded {
		if _, stageErr := stagePendingIfListenerAppeared(); stageErr != nil {
			return rollback(stageErr)
		}
		path, pathErr := SharedDaemonLaunchAgentPath()
		if pathErr != nil {
			return rollback(pathErr)
		}
		// 正常 owner 的 RunAtLoad 会在 bootstrap 时执行一次幂等 start；pending
		// owner 为 false，只注册显式迁移稍后可 kickstart 的入口，不会启动 daemon。
		if _, bootstrapErr := sharedDaemonLaunchctl(ctx, "bootstrap", launchAgentDomainTarget(), path); bootstrapErr != nil {
			return rollback(bootstrapErr)
		}
		launchctlChanged = true
	}
	changed := fileChanged || !before.Loaded || markerRepaired
	status, err := InspectSharedDaemonOwner(ctx)
	if err != nil {
		return rollback(err)
	}
	if !status.Installed || !status.Loaded || !status.Secure {
		return rollback(fmt.Errorf("共享 daemon LaunchAgent 安装后状态不完整"))
	}
	if status.RunAtLoad == pending {
		return rollback(fmt.Errorf("共享 daemon LaunchAgent 自动启动状态与迁移状态不一致"))
	}
	status.Changed = changed
	status.Created = created
	// 已经处于 pending 的 owner 修复属于安全状态收敛，不提供把它回滚回
	// RunAtLoad=true 的令牌。只有本次配置动作新引入的 owner 变更才可回滚。
	if changed && !pendingStateBefore {
		appliedPlist, readErr := os.ReadFile(status.Path)
		if readErr != nil {
			return rollback(fmt.Errorf("读取已应用 LaunchAgent 失败：%w", readErr))
		}
		appliedLoaded := status.Loaded
		appliedMigrationRequired := status.MigrationRequired
		status.Rollback = &SharedDaemonOwnerRollback{
			rollbackUnlocked: func(rollbackCtx context.Context) error {
				current, currentErr := os.ReadFile(status.Path)
				if currentErr != nil || !bytes.Equal(current, appliedPlist) {
					return fmt.Errorf("共享 daemon owner 已被其他进程修改，拒绝覆盖")
				}
				currentStatus, inspectErr := InspectSharedDaemonOwner(rollbackCtx)
				if inspectErr != nil {
					return fmt.Errorf("确认共享 daemon owner 回滚边界失败：%w", inspectErr)
				}
				if currentStatus.Loaded != appliedLoaded ||
					currentStatus.RunAtLoad != status.RunAtLoad ||
					currentStatus.MigrationRequired != appliedMigrationRequired {
					return fmt.Errorf("共享 daemon owner 状态已被其他进程修改，拒绝覆盖")
				}
				if launchctlChanged && !sharedDaemonSocketAcceptsConnectionMust(options) {
					return restoreSharedDaemonOwner(rollbackCtx, before, previousPlist)
				}
				return restoreSharedDaemonOwnerFilesOnly(before, previousPlist)
			},
		}
	}
	return status, nil
}

// RollbackSharedDaemonOwnerChange 供配置事务在落盘前失败时恢复 owner。文件锁
// 覆盖校验与恢复全程，且令牌会拒绝覆盖其他进程在此期间写入的新 owner。
func RollbackSharedDaemonOwnerChange(ctx context.Context, rollback *SharedDaemonOwnerRollback) error {
	if rollback == nil {
		return nil
	}
	_, err := withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		return LocalDaemonStatus{}, rollbackSharedDaemonOwnerChangeUnlocked(ctx, rollback)
	})
	return err
}

// restoreSharedDaemonOwner 把 plist、launchd 加载状态和迁移标记一起恢复到调用前。
// 只允许用于本事务已在“无既有 listener”条件下修改过 launchctl 的路径；已有
// listener 的 stage/rollback 必须走 files-only，不能依赖 bootout 的 coalition 行为。
func restoreSharedDaemonOwner(
	ctx context.Context,
	before SharedDaemonOwnerStatus,
	previousPlist []byte,
) error {
	loaded, _, inspectErr := inspectLaunchAgentState(ctx)
	if inspectErr != nil {
		return inspectErr
	}
	if loaded {
		if _, err := sharedDaemonLaunchctl(ctx, "bootout", launchAgentServiceTarget()); err != nil &&
			!isLaunchctlNotLoaded(err) {
			return err
		}
	}
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		return err
	}
	if before.Installed {
		if err := writeSharedDaemonPrivateFileAtomically(path, previousPlist); err != nil {
			return fmt.Errorf("恢复原 LaunchAgent 文件失败：%w", err)
		}
		if before.Loaded {
			if _, err := sharedDaemonLaunchctl(ctx, "bootstrap", launchAgentDomainTarget(), path); err != nil {
				return err
			}
		}
	} else if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("删除本次新建 LaunchAgent 失败：%w", err)
	}
	if before.MigrationRequired {
		return writeSharedDaemonMigrationFlag()
	}
	return clearSharedDaemonMigrationFlag()
}

// restoreSharedDaemonOwnerFilesOnly 用于只 stage 了磁盘 plist/marker、尚未触碰
// launchctl 的事务回滚。此路径绝不能为了恢复文件而 bootout 仍在服务的旧 job。
func restoreSharedDaemonOwnerFilesOnly(
	before SharedDaemonOwnerStatus,
	previousPlist []byte,
) error {
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		return err
	}
	if before.Installed {
		if err := writeSharedDaemonPrivateFileAtomically(path, previousPlist); err != nil {
			return fmt.Errorf("恢复原 LaunchAgent 文件失败：%w", err)
		}
	} else if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("删除本次新建 LaunchAgent 失败：%w", err)
	}
	if before.MigrationRequired {
		return writeSharedDaemonMigrationFlag()
	}
	return clearSharedDaemonMigrationFlag()
}

func writeSharedDaemonMigrationFlag() error {
	path, err := sharedDaemonMigrationFlagPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("创建共享 daemon 状态目录失败：%w", err)
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".codex-daemon-migration-*")
	if err != nil {
		return fmt.Errorf("记录共享 daemon 迁移状态失败：%w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write([]byte("restart-required\n")); err != nil {
		temp.Close()
		return fmt.Errorf("记录共享 daemon 迁移状态失败：%w", err)
	}
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return fmt.Errorf("设置共享 daemon 迁移状态权限失败：%w", err)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return fmt.Errorf("同步共享 daemon 迁移状态失败：%w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("记录共享 daemon 迁移状态失败：%w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("记录共享 daemon 迁移状态失败：%w", err)
	}
	if err := syncSharedDaemonDirectory(filepath.Dir(path)); err != nil {
		return fmt.Errorf("同步共享 daemon 状态目录失败：%w", err)
	}
	return nil
}

func markSharedDaemonEnablePrepared() error {
	path, err := sharedDaemonEnablePreparedFlagPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("创建共享 daemon 状态目录失败：%w", err)
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".codex-daemon-enable-prepared-*")
	if err != nil {
		return fmt.Errorf("记录共享 daemon 启用事务失败：%w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write([]byte("enable-prepared\n")); err != nil {
		_ = temp.Close()
		return fmt.Errorf("记录共享 daemon 启用事务失败：%w", err)
	}
	if err := temp.Chmod(0o600); err != nil {
		_ = temp.Close()
		return fmt.Errorf("设置共享 daemon 启用事务权限失败：%w", err)
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return fmt.Errorf("同步共享 daemon 启用事务失败：%w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("记录共享 daemon 启用事务失败：%w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("记录共享 daemon 启用事务失败：%w", err)
	}
	if err := syncSharedDaemonDirectory(filepath.Dir(path)); err != nil {
		return fmt.Errorf("同步共享 daemon 状态目录失败：%w", err)
	}
	return nil
}

func sharedDaemonEnablePrepared() (bool, error) {
	path, err := sharedDaemonEnablePreparedFlagPath()
	if err != nil {
		return false, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("检查共享 daemon 启用事务失败：%w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
		return false, fmt.Errorf("共享 daemon 启用事务必须是当前用户私有的普通文件")
	}
	return true, nil
}

func clearSharedDaemonEnablePrepared() error {
	path, err := sharedDaemonEnablePreparedFlagPath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("清除共享 daemon 启用事务失败：%w", err)
	}
	if err := syncSharedDaemonDirectoryIfPresent(filepath.Dir(path)); err != nil {
		return fmt.Errorf("同步共享 daemon 启用事务删除失败：%w", err)
	}
	return nil
}

func markSharedDaemonMigrationRequired() error {
	return writeSharedDaemonMigrationFlag()
}

func clearSharedDaemonMigrationFlag() error {
	path, err := sharedDaemonMigrationFlagPath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("清除共享 daemon 迁移状态失败：%w", err)
	}
	if err := syncSharedDaemonDirectoryIfPresent(filepath.Dir(path)); err != nil {
		return fmt.Errorf("同步共享 daemon 迁移状态删除失败：%w", err)
	}
	return nil
}

// RemoveSharedDaemonLaunchAgent 关闭共享时只删除未来登录的启动入口。当前 job
// 可能仍通过 launchd coalition 关联着 listener；bootout 没有“不影响服务进程”
// 的系统契约，因此本会话保留已加载且 KeepAlive=false 的定义。
func RemoveSharedDaemonLaunchAgent(ctx context.Context) error {
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		return err
	}
	if err := sharedDaemonRemoveLaunchAgentFile(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("删除 LaunchAgent 失败：%w", err)
	}
	if err := syncSharedDaemonDirectoryIfPresent(filepath.Dir(path)); err != nil {
		return fmt.Errorf("同步 LaunchAgent 删除失败：%w", err)
	}
	return nil
}

// RemoveSharedDaemonOwner 只移除 Mimi 安装的未来启动入口和迁移标记，不停止当前
// daemon；关闭共享时 Desktop 可能仍在完成退出，直接 stop 会破坏原生流程。
func RemoveSharedDaemonOwner(ctx context.Context) error {
	_, err := withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		return LocalDaemonStatus{}, removeSharedDaemonOwnerUnlocked(ctx)
	})
	return err
}

func disableSharedDaemonAfterDesktopExit(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
	commit func() error,
) error {
	_, err := withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		return disableSharedDaemonAfterDesktopExitUnlocked(ctx, options, validate, commit)
	})
	return err
}

type confirmedSharedDaemonDisableHooks struct {
	requireDesktopStopped func(context.Context, string) error
	// desktopRunning 只供独立模式启动复核使用：它需要区分“Desktop 在跑”和
	// “探测失败”，前者是正常的等待态，后者必须 fail closed。
	desktopRunning func(context.Context) (bool, error)
	// validateListenerOwnership 证明当前 listener 确实由 Mimi 的签名 node
	// supervisor 启动。独立模式启动复核用它区分 Mimi daemon 与外部 app-server。
	validateListenerOwnership func(context.Context, LocalDaemonOptions, string) error
	inspectOwner              func(context.Context) (SharedDaemonOwnerStatus, error)
	socketAccepts             func(string) bool
	stageOwner                func(SharedDaemonOwnerStatus) error
	inspectListener           func(context.Context, string) (sharedDaemonListenerProcess, error)
	stopDaemon                func(context.Context, LocalDaemonOptions, SharedDaemonOwnerStatus) error
	waitForStopped            func(context.Context, string, ...sharedDaemonListenerProcess) error
	launchctl                 func(context.Context, ...string) (string, error)
	removeLaunchAgent         func(context.Context) error
	clearEnablePrepared       func() error
	clearMigration            func() error
	enablePrepared            func() (bool, error)
}

func defaultConfirmedSharedDaemonDisableHooks() confirmedSharedDaemonDisableHooks {
	return confirmedSharedDaemonDisableHooks{
		requireDesktopStopped: requireCodexDesktopStopped,
		desktopRunning:        sharedDaemonDesktopRunning,
		validateListenerOwnership: func(ctx context.Context, options LocalDaemonOptions, socketPath string) error {
			return sharedDaemonValidateSignedRuntime(ctx, options, socketPath)
		},
		inspectOwner:        InspectSharedDaemonOwner,
		socketAccepts:       sharedDaemonSocketAcceptsConnection,
		stageOwner:          stageSharedDaemonOwnerForConfirmedDisable,
		inspectListener:     inspectSharedDaemonListenerProcess,
		stopDaemon:          stopSharedDaemonForConfirmedDisable,
		waitForStopped:      waitForSharedDaemonStopped,
		launchctl:           sharedDaemonLaunchctl,
		removeLaunchAgent:   RemoveSharedDaemonLaunchAgent,
		clearEnablePrepared: clearSharedDaemonEnablePrepared,
		clearMigration:      clearSharedDaemonMigrationFlag,
		enablePrepared:      sharedDaemonEnablePrepared,
	}
}

func disableSharedDaemonAfterDesktopExitUnlocked(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
	commit func() error,
) (LocalDaemonStatus, error) {
	return disableSharedDaemonAfterDesktopExitWithHooks(
		ctx,
		options,
		validate,
		commit,
		defaultConfirmedSharedDaemonDisableHooks(),
	)
}

func disableSharedDaemonAfterDesktopExitWithHooks(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
	commit func() error,
	hooks confirmedSharedDaemonDisableHooks,
) (LocalDaemonStatus, error) {
	if validate == nil {
		return LocalDaemonStatus{}, fmt.Errorf("提交共享配置前的复核回调不能为空")
	}
	if commit == nil {
		return LocalDaemonStatus{}, fmt.Errorf("提交共享配置的回调不能为空")
	}
	if err := validateStableOwnerLease(options); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := validate(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享配置快照已变化：%w", err)
	}
	if err := hooks.requireDesktopStopped(ctx, "关闭共享 daemon 前"); err != nil {
		return LocalDaemonStatus{}, err
	}
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	owner, err := hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	if owner.Installed && !owner.Secure {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon LaunchAgent 权限不安全，拒绝关闭")
	}
	if hooks.socketAccepts(socketPath) && !sharedDaemonLoadedOwnerEvidence(owner) {
		return LocalDaemonStatus{}, fmt.Errorf("当前 Codex Unix backend 没有可确认的 Mimi stable owner，拒绝停止外部 daemon")
	}
	// 先把磁盘入口降为 manual 并保留 marker。后续任一停止、bootout、清理或
	// 配置 CAS 失败，都不能留下会在下次登录自动启动的旧 owner。
	if err := hooks.stageOwner(owner); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := validate(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享配置快照已变化：%w", err)
	}
	if err := hooks.requireDesktopStopped(ctx, "停止共享 daemon 前"); err != nil {
		return LocalDaemonStatus{}, err
	}

	// stage 与停止之间 launchd 仍可能让已加载的旧 job 建立 socket，因此必须
	// 重新读取 owner 与 listener，而不能复用入口快照。
	owner, err = hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	if owner.Installed && !owner.Secure {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon LaunchAgent 权限在关闭前发生变化")
	}
	var stoppedIdentities []sharedDaemonListenerProcess
	if hooks.socketAccepts(socketPath) {
		if !sharedDaemonLoadedOwnerEvidence(owner) {
			return LocalDaemonStatus{}, fmt.Errorf("当前 Codex Unix backend 没有可确认的 Mimi stable owner，拒绝停止外部 daemon")
		}
		identity, inspectErr := hooks.inspectListener(ctx, socketPath)
		if inspectErr != nil {
			return LocalDaemonStatus{}, fmt.Errorf("记录待关闭共享 daemon 身份失败：%w", inspectErr)
		}
		stoppedIdentities = append(stoppedIdentities, identity)
		if err := hooks.stopDaemon(ctx, options, owner); err != nil {
			return LocalDaemonStatus{}, err
		}
	}
	// 即使入口探测时没有 listener，也要经过稳定确认窗口。这样 loaded job 在
	// 检查后才建立 socket 时不会被直接 bootout 或与新 WS 配置并存。
	if err := hooks.waitForStopped(ctx, socketPath, stoppedIdentities...); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := hooks.requireDesktopStopped(ctx, "卸载共享 daemon owner 前"); err != nil {
		return LocalDaemonStatus{}, err
	}
	if hooks.socketAccepts(socketPath) {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon socket 在卸载 owner 前重新出现")
	}
	owner, err = hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	if owner.Loaded {
		if !sharedDaemonLoadedOwnerEvidence(owner) {
			return LocalDaemonStatus{}, fmt.Errorf("已加载的共享 daemon owner 身份无法确认，拒绝卸载")
		}
		if _, bootoutErr := hooks.launchctl(ctx, "bootout", launchAgentServiceTarget()); bootoutErr != nil &&
			!isLaunchctlNotLoaded(bootoutErr) {
			return LocalDaemonStatus{}, fmt.Errorf("卸载共享 daemon owner 失败：%w", bootoutErr)
		}
	}
	confirmed, err := hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("复核共享 daemon owner 卸载状态失败：%w", err)
	}
	if confirmed.Loaded {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon owner 在 bootout 后仍处于 loaded 状态")
	}
	if err := hooks.removeLaunchAgent(ctx); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := hooks.clearEnablePrepared(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("清理共享 daemon 启用事务失败：%w", err)
	}
	if err := hooks.clearMigration(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("清理共享 daemon 迁移状态失败：%w", err)
	}

	// 最后一跳同时复核配置恢复权、Desktop、socket 与 owner。只有这些状态仍
	// 一致，才允许调用方把 shared Unix 原子替换为保存的独立 WS 配置。
	if err := validateStableOwnerLease(options); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := validate(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享配置快照已变化：%w", err)
	}
	if err := hooks.requireDesktopStopped(ctx, "提交独立 App Server 配置前"); err != nil {
		return LocalDaemonStatus{}, err
	}
	if hooks.socketAccepts(socketPath) {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon socket 在配置提交前重新出现")
	}
	confirmed, err = hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("提交配置前复核共享 daemon owner 失败：%w", err)
	}
	prepared, err := hooks.enablePrepared()
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("提交配置前复核共享 daemon 启用事务失败：%w", err)
	}
	if confirmed.Installed || confirmed.Loaded || confirmed.MigrationRequired || prepared {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon owner 未完全清理，拒绝提交独立 App Server 配置")
	}
	if err := commit(); err != nil {
		return LocalDaemonStatus{}, err
	}
	return LocalDaemonStatus{SocketPath: socketPath}, nil
}

func reconcileRunningSharedDaemonForIndependentMode(
	ctx context.Context,
	options LocalDaemonOptions,
) (SharedDaemonReconcileOutcome, error) {
	outcome := SharedDaemonReconcileNoop
	_, err := withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		var runErr error
		outcome, runErr = reconcileRunningSharedDaemonForIndependentModeWithHooks(
			ctx,
			options,
			defaultConfirmedSharedDaemonDisableHooks(),
		)
		return LocalDaemonStatus{}, runErr
	})
	if err != nil {
		return "", err
	}
	return outcome, nil
}

func reconcileRunningSharedDaemonForIndependentModeWithHooks(
	ctx context.Context,
	options LocalDaemonOptions,
	hooks confirmedSharedDaemonDisableHooks,
) (SharedDaemonReconcileOutcome, error) {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return "", err
	}
	if !hooks.socketAccepts(socketPath) {
		return SharedDaemonReconcileNoop, nil
	}
	owner, err := hooks.inspectOwner(ctx)
	if err != nil {
		return "", err
	}
	// Codex Desktop 自己拉起的 app-server 监听同一个 well-known socket。没有
	// stable owner 证据就绝不停止：那等于替用户杀掉 Desktop 的后端。权限不安全
	// 的 plist 同样不构成证据，会一并落到这里保持原样。
	if !sharedDaemonLoadedOwnerEvidence(owner) {
		return SharedDaemonReconcileForeign, nil
	}
	// launchd 入口归属不等于 listener 归属：Mimi 的 job 可能仍 loaded，而真正
	// 占着 well-known socket 的是 Codex Desktop 自己拉起的 app-server。必须先
	// 拿到签名 node supervisor 父链证据，才能进入任何会改动 owner 的步骤。
	if err := hooks.validateListenerOwnership(ctx, options, socketPath); err != nil {
		return "", fmt.Errorf("无法确认残留共享 daemon listener 归属，已保持原样：%w", err)
	}
	// 先只读判断 Desktop 是否在跑。stopDaemon 内部还会再次 fail-closed 复核；
	// 这里提前返回是为了在 Desktop 仍连着 daemon 时一个字节都不改，让调用方
	// 把“需要重启 Codex Desktop”原样告诉用户。
	desktopRunning, err := hooks.desktopRunning(ctx)
	if err != nil {
		return "", fmt.Errorf("确认 Codex Desktop 是否在运行失败：%w", err)
	}
	if desktopRunning {
		return SharedDaemonReconcilePendingDesktopExit, nil
	}
	// 入口降为 manual 必须先于停止：后面任一步失败都不能留下会在下次登录
	// 自动拉起、并重新抢走 writer lock 的 owner。
	if err := hooks.stageOwner(owner); err != nil {
		return "", err
	}
	identity, err := hooks.inspectListener(ctx, socketPath)
	if err != nil {
		return "", fmt.Errorf("记录残留共享 daemon 身份失败：%w", err)
	}
	if err := hooks.stopDaemon(ctx, options, owner); err != nil {
		return "", err
	}
	if err := hooks.waitForStopped(ctx, socketPath, identity); err != nil {
		return "", err
	}
	// wait 返回只证明原 listener 已退出。Desktop 或其他进程可能在确认窗口后
	// 重新绑定 well-known socket；bootout 前必须再次同时确认 Desktop 和 socket。
	if err := hooks.requireDesktopStopped(ctx, "卸载残留共享 daemon owner 前"); err != nil {
		return "", err
	}
	if hooks.socketAccepts(socketPath) {
		return "", fmt.Errorf("共享 daemon socket 在卸载残留 owner 前重新出现")
	}
	confirmed, err := hooks.inspectOwner(ctx)
	if err != nil {
		return "", fmt.Errorf("停止后复核共享 daemon owner 失败：%w", err)
	}
	if confirmed.Loaded {
		if !sharedDaemonLoadedOwnerEvidence(confirmed) {
			return "", fmt.Errorf("已加载的残留共享 daemon owner 身份无法确认，拒绝卸载")
		}
		if _, bootoutErr := hooks.launchctl(ctx, "bootout", launchAgentServiceTarget()); bootoutErr != nil &&
			!isLaunchctlNotLoaded(bootoutErr) {
			return "", fmt.Errorf("卸载残留共享 daemon owner 失败：%w", bootoutErr)
		}
		if confirmed, err = hooks.inspectOwner(ctx); err != nil {
			return "", fmt.Errorf("复核残留共享 daemon owner 卸载状态失败：%w", err)
		}
		if confirmed.Loaded {
			return "", fmt.Errorf("残留共享 daemon owner 在 bootout 后仍处于 loaded 状态")
		}
	}
	if err := hooks.removeLaunchAgent(ctx); err != nil {
		return "", err
	}
	if err := hooks.clearEnablePrepared(); err != nil {
		return "", fmt.Errorf("清理共享 daemon 启用事务失败：%w", err)
	}
	if err := hooks.clearMigration(); err != nil {
		return "", fmt.Errorf("清理共享 daemon 迁移状态失败：%w", err)
	}
	return SharedDaemonReconcileStopped, nil
}

func sharedDaemonLoadedOwnerEvidence(owner SharedDaemonOwnerStatus) bool {
	if !owner.Loaded || owner.Label != SharedDaemonLaunchAgentLabel {
		return false
	}
	// plist 缺失正是 orphan loaded job 的目标场景；精确 label 仍提供 owner
	// 证据。若 plist 存在，则权限必须安全，不能把可被其他用户修改的定义
	// 当成 Mimi stable owner。
	return !owner.Installed || owner.Secure
}

func stageSharedDaemonOwnerForConfirmedDisable(owner SharedDaemonOwnerStatus) error {
	if !owner.Installed {
		return nil
	}
	content, err := os.ReadFile(owner.Path)
	if err != nil {
		return fmt.Errorf("读取共享 daemon LaunchAgent 失败：%w", err)
	}
	if owner.RunAtLoad {
		manual, manualErr := sharedDaemonManualPlist(content)
		if manualErr != nil {
			return manualErr
		}
		if err := writeSharedDaemonPrivateFileAtomically(owner.Path, manual); err != nil {
			return fmt.Errorf("把共享 daemon owner 降为 manual 失败：%w", err)
		}
	}
	if !owner.MigrationRequired {
		if err := writeSharedDaemonMigrationFlag(); err != nil {
			return fmt.Errorf("记录共享 daemon manual 状态失败：%w", err)
		}
	}
	return nil
}

func stopSharedDaemonForConfirmedDisable(
	ctx context.Context,
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
) error {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return err
	}
	lifecycle, err := InspectLocalDaemonLifecycle(ctx, options)
	if err != nil {
		return err
	}
	if lifecycle.Backend != nil {
		if err := sharedDaemonValidateSignedRuntime(ctx, options, socketPath); err != nil {
			return fmt.Errorf("共享 daemon listener 缺少签名 supervisor 父链：%w", err)
		}
		listener, inspectErr := inspectSharedDaemonListenerProcess(ctx, socketPath)
		if inspectErr != nil {
			return fmt.Errorf("识别共享 daemon listener 失败：%w", inspectErr)
		}
		if err := validateManagedSharedDaemonListenerIdentity(lifecycle, listener, listener); err != nil {
			return err
		}
		return stopSharedDaemonWithExpectedIdentity(ctx, options, owner, &listener)
	}
	if !sharedDaemonLoadedOwnerEvidence(owner) {
		return fmt.Errorf("非 daemon 管理的 Codex app-server 没有已确认的 Mimi stable owner，拒绝停止")
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancelProbe()
	if err != nil {
		return fmt.Errorf("无法确认待关闭的 Codex app-server：%w", err)
	}
	if err := ValidateLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
		return err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
		return err
	}
	if err := sharedDaemonValidateSignedRuntime(ctx, options, socketPath); err != nil {
		return fmt.Errorf("共享 daemon listener 缺少签名 supervisor 父链：%w", err)
	}
	listener, err := inspectSharedDaemonListenerProcess(ctx, socketPath)
	if err != nil {
		return fmt.Errorf("识别共享 daemon listener 失败：%w", err)
	}
	if err := sharedDaemonValidateSignedRuntime(ctx, options, socketPath); err != nil {
		return fmt.Errorf("再次确认共享 daemon listener 身份失败：%w", err)
	}
	confirmed, err := inspectSharedDaemonListenerProcess(ctx, socketPath)
	if err != nil {
		return fmt.Errorf("再次确认共享 daemon owner 失败：%w", err)
	}
	if confirmed != listener {
		return fmt.Errorf("共享 daemon owner 在正常关闭前发生变化，已停止关闭")
	}
	if err := requireCodexDesktopStopped(ctx, "正常终止共享 daemon 前"); err != nil {
		return err
	}
	expectedCodexPath, err := resolveSharedDaemonCodexBin(options.CodexBin)
	if err != nil {
		return fmt.Errorf("解析共享 daemon Codex 可执行文件失败：%w", err)
	}
	return stopUnmanagedSharedDaemonWithExpectedIdentity(
		ctx,
		socketPath,
		expectedCodexPath,
		&confirmed,
		unmanagedSharedDaemonHooks{
			desktopRunning: sharedDaemonDesktopRunning,
			inspect:        inspectSharedDaemonListenerProcess,
			signalTERM:     signalSharedDaemonProcessTERM,
			currentUID:     os.Getuid,
		},
	)
}

func removeSharedDaemonOwnerUnlocked(ctx context.Context) error {
	_, err := removeSharedDaemonOwnerForTransactionUnlocked(ctx)
	return err
}

// removeSharedDaemonOwnerForTransactionUnlocked 在调用方持有 operation lock 时
// 移除 owner。先把磁盘 plist 降为 manual，再删除未来登录入口；当前会话里已
// 加载的定义保留到注销，避免 bootout 误伤 coalition 中的 listener。
// 返回值保留兼容签名，但禁用事务不再恢复 auto owner：配置可能已被锁外编辑器
// 改成 WS，恢复会越权。
func removeSharedDaemonOwnerForTransactionUnlocked(
	ctx context.Context,
) (func(context.Context) error, error) {
	before, err := InspectSharedDaemonOwner(ctx)
	if err != nil {
		return nil, err
	}
	var previousPlist []byte
	if before.Installed {
		previousPlist, err = os.ReadFile(before.Path)
		if err != nil {
			return nil, fmt.Errorf("读取待移除的共享 daemon LaunchAgent 失败：%w", err)
		}
	}
	if before.Installed && before.RunAtLoad {
		manual, manualErr := sharedDaemonManualPlist(previousPlist)
		if manualErr != nil {
			return nil, manualErr
		}
		if writeErr := writeSharedDaemonPrivateFileAtomically(before.Path, manual); writeErr != nil {
			return nil, fmt.Errorf("把共享 daemon owner 降为 manual 失败：%w", writeErr)
		}
	}
	if before.Installed && !before.MigrationRequired {
		// manual plist 本身已经 fail closed；marker 若写失败，下一次 ensure
		// 会从 RunAtLoad=false 自动修复，不能因此把 auto plist 恢复回来。
		if markerErr := writeSharedDaemonMigrationFlag(); markerErr != nil {
			return nil, fmt.Errorf("记录共享 daemon manual 状态失败：%w", markerErr)
		}
	}
	if err := RemoveSharedDaemonLaunchAgent(ctx); err != nil {
		return nil, fmt.Errorf("移除共享 daemon owner 失败；已保留 manual 安全状态：%w", err)
	}
	if err := clearSharedDaemonEnablePrepared(); err != nil {
		return nil, fmt.Errorf("清理共享 daemon 启用事务失败；自动启动入口已移除：%w", err)
	}
	if err := sharedDaemonClearMigrationForRemoval(); err != nil {
		return nil, fmt.Errorf("清理共享 daemon marker 失败；自动启动入口已移除：%w", err)
	}
	return func(context.Context) error { return nil }, nil
}

func sharedDaemonManualPlist(content []byte) ([]byte, error) {
	if runAtLoad, ok := sharedDaemonPlistBoolValue(content, "RunAtLoad"); !ok {
		return nil, fmt.Errorf("共享 daemon LaunchAgent 缺少 RunAtLoad，拒绝修改")
	} else if !runAtLoad {
		return append([]byte(nil), content...), nil
	}
	needle := []byte("<key>RunAtLoad</key>\n\t<true/>")
	if bytes.Count(content, needle) != 1 {
		return nil, fmt.Errorf("共享 daemon LaunchAgent 的 RunAtLoad 格式未知，拒绝修改")
	}
	return bytes.Replace(content, needle, []byte("<key>RunAtLoad</key>\n\t<false/>"), 1), nil
}

// startLocalDaemonWithStableOwner 请 launchd 创建 daemon：spawn 发生在 launchd
// 上下文，agentd 完全不进入责任链。这里没有“launchctl 失败就自己 exec”的兜底，
// 因为那正是 MIM-157 的错误归因来源。
func startLocalDaemonWithStableOwner(ctx context.Context, options LocalDaemonOptions) error {
	_, err := startLocalDaemonWithStableOwnerTracked(ctx, options)
	return err
}

// startLocalDaemonWithStableOwnerTracked 只有本次实际执行了 launchd kickstart 才
// 返回 true。轻量 socket 短路或等待既有 running job 都不能作为 TCC owner 已迁移
// 的证据，避免错误清除 migration marker。
func startLocalDaemonWithStableOwnerTracked(
	ctx context.Context,
	options LocalDaemonOptions,
) (bool, error) {
	logOffset := sharedDaemonLaunchAgentLogSize()
	owner, err := EnsureSharedDaemonOwner(ctx, options, false)
	if err != nil {
		return false, err
	}
	if sharedDaemonSocketAcceptsConnectionMust(options) {
		return false, nil
	}
	if owner.MigrationRequired {
		return false, ErrSharedDaemonMigrationPending
	}
	if owner.Running {
		// 登录或 bootstrap 的 RunAtLoad 可能仍在执行官方 start；不能在同一个
		// job 尚未退出时再 kickstart，直接等待本次启动完成。
		return false, waitForSharedDaemonSocket(ctx, options, logOffset)
	}
	if owner.RunAtLoad {
		// 登录时 launchd 的 running 状态与 app-server socket 建立并非原子更新。
		// 先给既有 supervisor 一个短窗口，避免立即 kickstart 第二套；真正崩溃
		// 的恢复最多只增加这一秒。
		graceCtx, cancelGrace := context.WithTimeout(ctx, sharedDaemonRunAtLoadGrace)
		graceErr := waitForSharedDaemonSocket(graceCtx, options, logOffset)
		cancelGrace()
		if graceErr == nil {
			return false, nil
		}
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
		if sharedDaemonSocketAcceptsConnectionMust(options) {
			return false, nil
		}
	}
	// job 已注册：显式 kickstart 一次，不依赖刚才 bootstrap 的异步 RunAtLoad。
	if _, kickErr := sharedDaemonLaunchctl(ctx, "kickstart", launchAgentServiceTarget()); kickErr != nil {
		return false, kickErr
	}
	return true, waitForSharedDaemonSocket(ctx, options, logOffset)
}

// startPreparedSharedDaemonWithStableOwnerTracked 只用于配置提交前的 manual
// owner。调用方已经确认准备前没有 listener，因此这里允许显式 kickstart 一次
// 做冷启动校验；plist 仍是 RunAtLoad=false，进程崩溃也不会变成登录自启。
func startPreparedSharedDaemonWithStableOwnerTracked(
	ctx context.Context,
	options LocalDaemonOptions,
) (bool, error) {
	owner, err := InspectSharedDaemonOwner(ctx)
	if err != nil {
		return false, err
	}
	if !owner.Installed || !owner.Loaded || owner.RunAtLoad || !owner.MigrationRequired {
		return false, fmt.Errorf("共享 daemon 两阶段准备缺少 manual owner")
	}
	if sharedDaemonSocketAcceptsConnectionMust(options) {
		return false, nil
	}
	logOffset := sharedDaemonLaunchAgentLogSize()
	if owner.Running {
		return false, waitForSharedDaemonSocket(ctx, options, logOffset)
	}
	if _, err := sharedDaemonLaunchctl(ctx, "kickstart", launchAgentServiceTarget()); err != nil {
		return false, err
	}
	return true, waitForSharedDaemonSocket(ctx, options, logOffset)
}

// startPreparedSharedDaemonAfterConfigCommit 只在配置已经提交为 shared 后启动
// manual owner。这样进程若在启动/握手中退出，磁盘也是 shared+manual，而不会
// 在 WS 配置下遗留一个无人管理的 Unix daemon。
func startPreparedSharedDaemonAfterConfigCommit(
	ctx context.Context,
	options LocalDaemonOptions,
) (LocalDaemonStatus, error) {
	// 配置提交后仍只允许 manual job 显式 kickstart。即使完整握手成功也不在
	// 这里提升 auto：kickstart 与 socket 建立之间无法原子证明是谁赢得 listener，
	// 因而必须保留 marker，由用户在 Desktop 已退出后走唯一迁移入口提交。
	startedByOwner := false
	var err error
	if !sharedDaemonSocketAcceptsConnectionMust(options) {
		startedByOwner, err = startPreparedSharedDaemonWithStableOwnerTracked(ctx, options)
		if err != nil {
			return LocalDaemonStatus{}, err
		}
	}
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancel()
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon 启动后协议握手失败：%w", err)
	}
	lifecycle, err := InspectLocalDaemonLifecycle(ctx, options)
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon 启动后生命周期检查失败：%w", err)
	}
	if err := ValidateLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := sharedDaemonValidateSignedRuntime(ctx, options, socketPath); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon 启动后签名父链检查失败：%w", err)
	}
	status := localDaemonStatus(socketPath, startedByOwner, probe.Version, os.Stat)
	status.StartedByStableOwner = startedByOwner
	status.OwnerInstalled = true
	status.OwnerMigrationRequired = true
	status.LifecycleValidated = true
	// durable intent 只授权“配置已提交但首次 manual 冷启动尚未完成”的恢复。
	// 一旦完整 managed 校验通过就立即消费；marker/manual 继续要求用户确认。
	// 否则显式迁移在 stop 后失败时，普通 gateway recovery 会误用旧 intent
	// 静默再次 kickstart。
	if err := clearSharedDaemonEnablePrepared(); err != nil {
		return LocalDaemonStatus{}, err
	}
	return status, nil
}

func sharedDaemonSocketAcceptsConnectionMust(options LocalDaemonOptions) bool {
	path, err := LocalDaemonSocketPath(options.Env)
	return err == nil && sharedDaemonSocketAcceptsConnection(path)
}

// RestartSharedDaemonWithStableOwner 是唯一允许迁移既有 daemon 的入口。调用方必须
// 先取得用户明确确认；它先用官方 stop 正常退出，再由 launchd job 拉起，绝不回退
// 到 agentd 直接 spawn。成功完成协议握手后才清除 migration marker。
func RestartSharedDaemonWithStableOwner(
	ctx context.Context,
	options LocalDaemonOptions,
) (LocalDaemonStatus, error) {
	return withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		return restartSharedDaemonWithStableOwner(ctx, options)
	})
}

func restartSharedDaemonWithStableOwner(
	ctx context.Context,
	options LocalDaemonOptions,
) (LocalDaemonStatus, error) {
	if err := validateStableOwnerLease(options); err != nil {
		return LocalDaemonStatus{}, err
	}
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, localDaemonProbeTimeout)
	_, preexistingErr := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancelProbe()
	owner, err := EnsureSharedDaemonOwner(
		ctx,
		options,
		localDaemonWasPreexisting(preexistingErr, sharedDaemonSocketAcceptsConnectionMust(options)),
	)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	if !owner.Installed || !owner.Loaded {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon LaunchAgent 未正确加载")
	}
	// 显式入口一旦开始就消费 fresh-enable 恢复权。之后任一 stop/start/校验
	// 失败都只能保留 manual marker 等用户再次确认，普通 Ensure 不能重试。
	if err := clearSharedDaemonEnablePrepared(); err != nil {
		return LocalDaemonStatus{}, err
	}
	// 上一次显式迁移可能已经启动并完整验证了新 supervisor，却在清 marker 前
	// 崩溃。若当前 socket 仍能从真实 peer 证明就是目标签名父链，直接提交 auto；
	// 不为了修复持久状态再中断一次健康会话。
	if owner.MigrationRequired && preexistingErr == nil {
		probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
		probe, probeErr := ProbeLocalDaemonInfo(probeCtx, socketPath)
		cancel()
		if probeErr == nil {
			lifecycle, lifecycleErr := InspectLocalDaemonLifecycle(ctx, options)
			if lifecycleErr == nil &&
				ValidateLocalDaemonLifecycle(lifecycle, socketPath) == nil &&
				ValidateLocalDaemonProbeVersion(lifecycle, probe.Version) == nil &&
				sharedDaemonValidateSignedRuntime(ctx, options, socketPath) == nil {
				if err := commitSharedDaemonMigration(options); err != nil {
					return LocalDaemonStatus{}, err
				}
				status := localDaemonStatus(socketPath, false, probe.Version, os.Stat)
				status.OwnerInstalled = true
				status.LifecycleValidated = true
				return status, nil
			}
		}
	}
	if !owner.MigrationRequired {
		probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
		probe, probeErr := ProbeLocalDaemonInfo(probeCtx, socketPath)
		cancel()
		if probeErr == nil {
			lifecycle, lifecycleErr := InspectLocalDaemonLifecycle(ctx, options)
			if lifecycleErr != nil {
				return LocalDaemonStatus{}, fmt.Errorf("确认现有共享 daemon 生命周期失败：%w", lifecycleErr)
			}
			if lifecycleErr := ValidateLocalDaemonLifecycle(lifecycle, socketPath); lifecycleErr != nil {
				return LocalDaemonStatus{}, lifecycleErr
			}
			if identityErr := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); identityErr != nil {
				return LocalDaemonStatus{}, identityErr
			}
			if identityErr := sharedDaemonValidateSignedRuntime(ctx, options, socketPath); identityErr != nil {
				return LocalDaemonStatus{}, fmt.Errorf("现有共享 daemon 缺少签名 supervisor 父链：%w", identityErr)
			}
			status := localDaemonStatus(socketPath, false, probe.Version, os.Stat)
			status.OwnerInstalled = true
			return status, nil
		}
	}
	var listenerBeforeStop *sharedDaemonListenerProcess
	if sharedDaemonSocketAcceptsConnection(socketPath) {
		identity, identityErr := inspectSharedDaemonListenerProcess(ctx, socketPath)
		if identityErr != nil {
			return LocalDaemonStatus{}, fmt.Errorf("记录旧共享 daemon 身份失败：%w", identityErr)
		}
		listenerBeforeStop = &identity
	}
	if err := stopSharedDaemon(ctx, options, owner); err != nil {
		return LocalDaemonStatus{}, err
	}
	var stoppedIdentities []sharedDaemonListenerProcess
	if listenerBeforeStop != nil {
		stoppedIdentities = append(stoppedIdentities, *listenerBeforeStop)
	}
	if err := waitForSharedDaemonStopped(ctx, socketPath, stoppedIdentities...); err != nil {
		return LocalDaemonStatus{}, err
	}
	// 已有 listener 时 Ensure 只把新 plist stage 到磁盘，launchd 内仍可能
	// 注册着旧的 `daemon start` 定义。只有用户明确确认、旧 socket 已稳定断开
	// 后，才把当前 manual plist 重新加载；否则随后 kickstart 仍会拉起旧拓扑。
	if owner.MigrationRequired {
		if err := reloadSharedDaemonLaunchAgentForMigration(ctx); err != nil {
			return LocalDaemonStatus{}, err
		}
	}
	logOffset := sharedDaemonLaunchAgentLogSize()
	if err := kickstartSharedDaemon(ctx); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := waitForSharedDaemonSocket(ctx, options, logOffset); err != nil {
		return LocalDaemonStatus{}, err
	}
	probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancel()
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon 重启后协议握手失败：%w", err)
	}
	lifecycle, err := InspectLocalDaemonLifecycle(ctx, options)
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon 重启后生命周期检查失败：%w", err)
	}
	if err := ValidateLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := sharedDaemonValidateSignedRuntime(ctx, options, socketPath); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon 重启后签名父链检查失败：%w", err)
	}
	if err := commitSharedDaemonMigration(options); err != nil {
		return LocalDaemonStatus{}, err
	}
	status := localDaemonStatus(socketPath, true, probe.Version, os.Stat)
	status.OwnerInstalled = true
	return status, nil
}

func reloadSharedDaemonLaunchAgentForMigration(ctx context.Context) error {
	if err := requireCodexDesktopStopped(ctx, "重新加载共享 daemon owner 前"); err != nil {
		return err
	}
	owner, err := InspectSharedDaemonOwner(ctx)
	if err != nil {
		return fmt.Errorf("确认待迁移共享 daemon owner 失败：%w", err)
	}
	if !owner.Installed || !owner.Secure || owner.RunAtLoad || !owner.MigrationRequired {
		return fmt.Errorf("待迁移共享 daemon owner 不是安全的 manual 状态")
	}
	if owner.Loaded {
		if _, err := sharedDaemonLaunchctl(ctx, "bootout", launchAgentServiceTarget()); err != nil &&
			!isLaunchctlNotLoaded(err) {
			return fmt.Errorf("卸载旧共享 daemon owner 失败：%w", err)
		}
	}
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		return err
	}
	if _, err := sharedDaemonLaunchctl(ctx, "bootstrap", launchAgentDomainTarget(), path); err != nil {
		return fmt.Errorf("加载新共享 daemon owner 失败：%w", err)
	}
	confirmed, err := InspectSharedDaemonOwner(ctx)
	if err != nil {
		return fmt.Errorf("复核新共享 daemon owner 失败：%w", err)
	}
	if !confirmed.Installed || !confirmed.Loaded || confirmed.Running || !confirmed.Secure ||
		confirmed.RunAtLoad || !confirmed.MigrationRequired {
		return fmt.Errorf("新共享 daemon owner 未保持可显式启动的 manual 状态")
	}
	return nil
}

func kickstartSharedDaemon(ctx context.Context) error {
	if err := requireCodexDesktopStopped(ctx, "启动新 Codex daemon 前"); err != nil {
		return err
	}
	_, err := sharedDaemonLaunchctl(ctx, "kickstart", launchAgentServiceTarget())
	return err
}

func commitSharedDaemonMigration(options LocalDaemonOptions) error {
	// intent 只说明 fresh enable 尚未由用户确认。完整验证已在调用方完成；先
	// 清 intent 再提交 auto，崩溃在两者之间仍是 manual+marker，可安全重试。
	if err := clearSharedDaemonEnablePrepared(); err != nil {
		return err
	}
	if err := clearSharedDaemonMigrationFlag(); err != nil {
		return err
	}
	// marker 是禁止自动启动的提交门。先清 marker，再把磁盘 plist 提升回
	// RunAtLoad=true；若提升失败立刻补回 marker。若进程恰在两步间崩溃，
	// 下一次 ensure 会从 manual plist 识别并恢复 pending，仍然 fail closed。
	if _, err := ensureSharedDaemonLaunchAgent(options, true); err != nil {
		if markerErr := writeSharedDaemonMigrationFlag(); markerErr != nil {
			return fmt.Errorf("共享 daemon 已验证，但恢复自动启动失败：%w；重新记录待迁移状态也失败：%v", err, markerErr)
		}
		return fmt.Errorf("共享 daemon 已验证，但恢复自动启动失败：%w", err)
	}
	return nil
}

func waitForSharedDaemonStopped(
	ctx context.Context,
	socketPath string,
	identities ...sharedDaemonListenerProcess,
) error {
	deadline := time.Now().Add(sharedDaemonStopTimeout)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	var disconnectedSince time.Time
	for {
		now := time.Now()
		if sharedDaemonSocketAcceptsConnection(socketPath) {
			disconnectedSince = time.Time{}
		} else if disconnectedSince.IsZero() {
			disconnectedSince = now
		} else if now.Sub(disconnectedSince) >= sharedDaemonStoppedConfirmationWindow {
			allExited := true
			for _, identity := range identities {
				alive, identityErr := sharedDaemonProcessIdentityStillAlive(identity)
				if identityErr != nil {
					return identityErr
				}
				if alive {
					allExited = false
					break
				}
			}
			if allExited {
				return nil
			}
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if now.After(deadline) {
			return fmt.Errorf("旧 Codex local daemon 在 stop 后仍未退出")
		}
		time.Sleep(sharedDaemonSocketPollInterval)
	}
}

func sharedDaemonProcessIdentityStillAlive(identity sharedDaemonListenerProcess) (bool, error) {
	if identity.PID <= 1 {
		return false, fmt.Errorf("旧共享 daemon PID 无效")
	}
	kinfo, err := sharedDaemonStoppedKinfoProc("kern.proc.pid", identity.PID)
	if err != nil {
		if errors.Is(err, unix.ESRCH) || errors.Is(err, unix.ENOENT) {
			return false, nil
		}
		if errors.Is(err, unix.EIO) {
			// Darwin 可能在进程退出但 kinfo 尚未稳定的瞬间返回 EIO。只有
			// kill(pid, 0)=ESRCH 才足以证明旧 PID 已消失；PID 仍存在时
			// 返回 alive 让外层继续轮询，无法判断时仍 fail closed。
			signalErr := sharedDaemonSignalZero(identity.PID)
			if errors.Is(signalErr, unix.ESRCH) {
				return false, nil
			}
			if signalErr == nil {
				return true, nil
			}
			return false, fmt.Errorf("复核旧共享 daemon 是否退出失败：%w（signal 0：%v）", err, signalErr)
		}
		return false, fmt.Errorf("复核旧共享 daemon 是否退出失败：%w", err)
	}
	if int(kinfo.Proc.P_pid) != identity.PID || int(kinfo.Eproc.Ucred.Uid) != identity.UID {
		return false, nil
	}
	return kinfo.Proc.P_starttime.Sec == identity.StartSec &&
		kinfo.Proc.P_starttime.Usec == identity.StartUsec, nil
}

func stopSharedDaemon(
	ctx context.Context,
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
) error {
	return stopSharedDaemonWithExpectedIdentity(ctx, options, owner, nil)
}

func stopSharedDaemonWithExpectedIdentity(
	ctx context.Context,
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
	expected *sharedDaemonListenerProcess,
) error {
	socketPath, pathErr := LocalDaemonSocketPath(options.Env)
	if pathErr != nil {
		return pathErr
	}
	// 上一次显式迁移可能已发出唯一次 SIGTERM，但旧
	// server 在等待超时后才完成优雅退出。用户稍后重试时，
	// socket 已不可连就是“无需再 stop”；外层还会要求它持续
	// 不可连一个确认窗口后才 kickstart，不会重复发信号。
	if !sharedDaemonSocketAcceptsConnection(socketPath) {
		return nil
	}
	lifecycle, lifecycleErr := InspectLocalDaemonLifecycle(ctx, options)
	if lifecycleErr != nil {
		return lifecycleErr
	}
	if lifecycle.Backend == nil {
		if !owner.Installed || !owner.Loaded || !owner.Secure || !owner.MigrationRequired {
			return fmt.Errorf("非 daemon 管理的 Codex app-server 缺少已确认的稳定 owner 迁移状态，拒绝接管")
		}
		return stopUnmanagedSharedDaemon(ctx, options, lifecycle)
	}
	backend := strings.ToLower(strings.TrimSpace(*lifecycle.Backend))
	if backend != "pid" {
		return fmt.Errorf("Codex app-server 使用未知 lifecycle backend %q，拒绝迁移", *lifecycle.Backend)
	}
	if expected != nil {
		if err := sharedDaemonValidateSignedRuntime(ctx, options, socketPath); err != nil {
			return fmt.Errorf("停止官方 Codex daemon 前签名父链复核失败：%w", err)
		}
		current, inspectErr := inspectSharedDaemonListenerProcess(ctx, socketPath)
		if inspectErr != nil {
			return fmt.Errorf("停止官方 Codex daemon 前识别 listener 失败：%w", inspectErr)
		}
		if err := validateManagedSharedDaemonListenerIdentity(lifecycle, *expected, current); err != nil {
			return err
		}
	}
	if err := requireCodexDesktopStopped(ctx, "停止官方 Codex daemon 前"); err != nil {
		return err
	}
	if expected != nil {
		// Desktop 探测本身也会产生调度窗口。执行官方 stop 前再绑定一次 PID、
		// 启动时间和签名父链，避免停止刚替换进来的 listener。
		if err := sharedDaemonValidateSignedRuntime(ctx, options, socketPath); err != nil {
			return fmt.Errorf("执行官方 stop 前签名父链复核失败：%w", err)
		}
		current, inspectErr := inspectSharedDaemonListenerProcess(ctx, socketPath)
		if inspectErr != nil {
			return fmt.Errorf("执行官方 stop 前识别 listener 失败：%w", inspectErr)
		}
		if err := validateManagedSharedDaemonListenerIdentity(lifecycle, *expected, current); err != nil {
			return err
		}
	}

	bin := strings.TrimSpace(options.CodexBin)
	if bin == "" {
		bin = "codex"
	}
	cmd := exec.CommandContext(ctx, bin, "app-server", "daemon", "stop")
	configureManagedCommand(cmd)
	cmd.Env = buildManagedEnv(options.Env)
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	message := sanitizeDiagnostic(string(output))
	lower := strings.ToLower(message)
	if strings.Contains(lower, "not running") || strings.Contains(lower, "no running") {
		return nil
	}
	if strings.Contains(lower, unmanagedSharedDaemonMessage) {
		return fmt.Errorf("官方 lifecycle 报告 pid backend，但 stop 拒绝管理该进程，已停止迁移")
	}
	if message == "" {
		return fmt.Errorf("停止旧 Codex local daemon 失败：%w", err)
	}
	return fmt.Errorf("停止旧 Codex local daemon 失败：%s", message)
}

func validateManagedSharedDaemonListenerIdentity(
	lifecycle LocalDaemonLifecycleStatus,
	expected sharedDaemonListenerProcess,
	current sharedDaemonListenerProcess,
) error {
	if lifecycle.PID == nil {
		return fmt.Errorf("官方 Codex daemon 未报告 pid backend 身份，拒绝停止")
	}
	if int(*lifecycle.PID) != expected.PID {
		return fmt.Errorf("官方 Codex daemon PID 与已确认 listener 不一致，拒绝停止")
	}
	if current != expected {
		return fmt.Errorf("共享 daemon listener 在官方 stop 前发生变化，拒绝停止")
	}
	return nil
}

func requireCodexDesktopStopped(ctx context.Context, stage string) error {
	running, err := sharedDaemonDesktopRunning(ctx)
	if err != nil {
		return fmt.Errorf("%s确认 Codex Desktop 已退出失败：%w", stage, err)
	}
	if running {
		return fmt.Errorf("%s Codex Desktop 已重新打开，已停止迁移", stage)
	}
	return nil
}

// waitForSharedDaemonSocket 把 launchd/node supervisor 的异步启动重新变成同步
// 语义，调用方依赖“返回即已就绪”。
func waitForSharedDaemonSocket(ctx context.Context, options LocalDaemonOptions, logOffset int64) error {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return err
	}
	deadline := time.Now().Add(sharedDaemonStartTimeout)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	for {
		// 只判断 socket 文件存在是不够的：官方 `daemon stop` 不会删除 socket 文件，
		// 上一个 daemon 退出后它会一直留在磁盘上。必须真正 connect 一次，才能区分
		// “新 daemon 已在监听”和“stale socket 仍在、启动其实失败了”。
		if sharedDaemonSocketAcceptsConnection(socketPath) {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if time.Now().After(deadline) {
			return sharedDaemonStartupError(logOffset)
		}
		time.Sleep(sharedDaemonSocketPollInterval)
	}
}

// sharedDaemonSocketAcceptsConnection 只做一次连通性判断，完整的 initialize 握手
// 和版本校验仍由调用方的 probe 负责，避免这里重复实现协议判断。
func sharedDaemonSocketAcceptsConnection(socketPath string) bool {
	info, err := os.Lstat(socketPath)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return false
	}
	conn, err := net.DialTimeout("unix", socketPath, localDaemonProbeTimeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// sharedDaemonStartupError 从 job 日志还原失败原因。daemon 由 launchd 创建后，
// 官方 CLI 的报错只会落在 StandardErrorPath，不再经过 agentd 的 stdout。
func sharedDaemonStartupError(logOffset int64) error {
	tail := sharedDaemonLaunchAgentLogTail(logOffset)
	lower := strings.ToLower(tail)
	if strings.Contains(lower, "managed standalone codex install not found") ||
		strings.Contains(lower, "requires the standalone install") {
		return fmt.Errorf("%w；请先使用 Codex 官方安装器安装命令行工具，再重启 Mimi Remote", ErrLocalDaemonStandaloneMissing)
	}
	if tail == "" {
		return fmt.Errorf("Codex local daemon 未在预期时间内就绪；请检查 %s", SharedDaemonLaunchAgentLabel)
	}
	return fmt.Errorf("Codex local daemon 未在预期时间内就绪：%s", sanitizeDiagnostic(tail))
}

func sharedDaemonLaunchAgentLogSize() int64 {
	path, err := sharedDaemonLaunchAgentLogPath()
	if err != nil {
		return 0
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return 0
	}
	return info.Size()
}

func sharedDaemonLaunchAgentLogTail(offset int64) string {
	path, err := sharedDaemonLaunchAgentLogPath()
	if err != nil {
		return ""
	}
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return ""
	}
	size := info.Size()
	if offset < 0 || offset > size {
		offset = 0
	}
	if size-offset > sharedDaemonLogDiagnosticBytes {
		offset = size - sharedDaemonLogDiagnosticBytes
	}
	if _, err := file.Seek(offset, 0); err != nil {
		return ""
	}
	content, err := io.ReadAll(io.LimitReader(file, sharedDaemonLogDiagnosticBytes))
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) > 5 {
		lines = lines[len(lines)-5:]
	}
	return strings.TrimSpace(strings.Join(lines, "; "))
}

func launchAgentDomainTarget() string {
	return fmt.Sprintf("gui/%d", os.Getuid())
}

func launchAgentServiceTarget() string {
	return launchAgentDomainTarget() + "/" + SharedDaemonLaunchAgentLabel
}

func inspectLaunchAgentState(ctx context.Context) (bool, bool, error) {
	output, err := sharedDaemonLaunchctl(ctx, "print", launchAgentServiceTarget())
	if err != nil {
		if isLaunchctlNotLoaded(err) {
			return false, false, nil
		}
		return false, false, fmt.Errorf("检查共享 daemon LaunchAgent 加载状态失败：%w", err)
	}
	for _, line := range strings.Split(output, "\n") {
		if strings.EqualFold(strings.TrimSpace(line), "state = running") {
			return true, true, nil
		}
	}
	return true, false, nil
}

type launchctlError struct {
	subcommand string
	output     string
	err        error
}

func (e *launchctlError) Error() string {
	if e.output != "" {
		return fmt.Sprintf("launchctl %s 失败：%s", e.subcommand, sanitizeDiagnostic(e.output))
	}
	return fmt.Sprintf("launchctl %s 失败：%v", e.subcommand, e.err)
}

func (e *launchctlError) Unwrap() error { return e.err }

func runLaunchctl(ctx context.Context, arguments ...string) (string, error) {
	if len(arguments) == 0 {
		return "", fmt.Errorf("launchctl 参数不能为空")
	}
	commandCtx := ctx
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		commandCtx, cancel = context.WithTimeout(ctx, launchctlTimeout)
		defer cancel()
	}
	cmd := exec.CommandContext(commandCtx, "/bin/launchctl", arguments...)
	output, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(output))
	if err != nil {
		return text, &launchctlError{subcommand: arguments[0], output: text, err: err}
	}
	return text, nil
}

// isLaunchctlNotLoaded 区分“本来就没注册”和真正的 bootout 失败。
func isLaunchctlNotLoaded(err error) bool {
	if err == nil {
		return false
	}
	lower := strings.ToLower(err.Error())
	return strings.Contains(lower, "no such process") ||
		strings.Contains(lower, "no such service") ||
		strings.Contains(lower, "could not find specified service") ||
		strings.Contains(lower, "not find") ||
		strings.Contains(lower, "not loaded")
}
