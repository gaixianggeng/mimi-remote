//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/xml"
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
	// SharedDaemonLaunchAgentLabel 是 Mimi 安装的 LaunchAgent 标签。它只负责“请
	// launchd 以官方 codex 身份创建共享 daemon”，不代表 Mimi 拥有该 daemon 的
	// 生命周期：job 本身执行完 `daemon start` 就退出，daemon 继续独立运行。
	SharedDaemonLaunchAgentLabel = "com.gaixianggeng.mimi.codex-shared-daemon"

	sharedDaemonLaunchAgentLogName         = "codex-shared-daemon.log"
	sharedDaemonMigrationFlagName          = "codex-shared-daemon-migration-required"
	sharedDaemonEnablePreparedFlagName     = "codex-shared-daemon-enable-prepared"
	sharedDaemonOperationLockName          = "codex-shared-daemon-operation.lock"
	sharedDaemonStartTimeout               = 20 * time.Second
	sharedDaemonStartTimeoutForLocalEnsure = sharedDaemonStartTimeout
	sharedDaemonStopTimeout                = 15 * time.Second
	sharedDaemonStoppedConfirmationWindow  = 500 * time.Millisecond
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

// SharedDaemonOwnerStatus 描述 Mimi 为官方 daemon 安装的稳定启动入口。它只证明
// launchd job 的安装状态；TCC 的最终责任主体仍需在真实签名 App 上做运行态验收。
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
	info, err := os.Stat(absolute)
	if err != nil {
		return "", fmt.Errorf("检查 codex 可执行文件失败：%w", err)
	}
	if info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("codex 路径不是可执行文件：%s", absolute)
	}
	return absolute, nil
}

// renderSharedDaemonLaunchAgent 生成 plist。ProgramArguments 直接执行官方 codex，
// 不引入 shell 责任主体；Desktop 专属变量由 job 环境中的空值覆盖。TCC 最终归因
// 仍必须由签名 App 做运行态验收，不能由 plist 结构或单元测试代替。
func renderSharedDaemonLaunchAgent(
	codexBin string,
	env map[string]string,
	logPath string,
	runAtLoadOption ...bool,
) ([]byte, error) {
	if strings.TrimSpace(codexBin) == "" {
		return nil, fmt.Errorf("codex 路径不能为空")
	}
	arguments := []string{
		codexBin,
		"app-server",
		"daemon",
		"start",
	}
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
	// job 是一次性控制命令，退出属于正常结束，不能让 launchd 反复重启。
	buf.WriteString("\t<key>KeepAlive</key>\n\t<false/>\n")
	buf.WriteString("\t<key>ThrottleInterval</key>\n\t<integer>1</integer>\n")
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
	// 因此无需借 shell 执行 unset，进程树固定为 launchd -> codex。
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
	desired, err := renderSharedDaemonLaunchAgent(codexBin, effectiveEnv, logPath, runAtLoad)
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
	pending := before.MigrationRequired || forcePending ||
		(daemonPreexisting && (autoChanged || !before.Loaded))
	plan := autoPlan
	if pending {
		plan, err = planSharedDaemonLaunchAgent(options, false)
		if err != nil {
			return SharedDaemonOwnerStatus{}, err
		}
	}
	fileChanged, err := applySharedDaemonLaunchAgentPlan(plan)
	if err != nil {
		return SharedDaemonOwnerStatus{}, err
	}
	created := !before.Installed
	rollback := func(cause error) (SharedDaemonOwnerStatus, error) {
		rollbackCtx, cancel := context.WithTimeout(context.Background(), 2*launchctlTimeout)
		defer cancel()
		if rollbackErr := restoreSharedDaemonOwner(rollbackCtx, before, previousPlist); rollbackErr != nil {
			return SharedDaemonOwnerStatus{}, fmt.Errorf("%w；恢复原 daemon owner 也失败：%v", cause, rollbackErr)
		}
		return SharedDaemonOwnerStatus{}, fmt.Errorf("%w；已恢复原 daemon owner", cause)
	}
	if pending && !before.MigrationRequired {
		if err := writeSharedDaemonMigrationFlag(); err != nil {
			return rollback(err)
		}
	}
	loaded := before.Loaded
	if fileChanged && loaded {
		if _, bootoutErr := sharedDaemonLaunchctl(ctx, "bootout", launchAgentServiceTarget()); bootoutErr != nil &&
			!isLaunchctlNotLoaded(bootoutErr) {
			return rollback(bootoutErr)
		}
		loaded = false
	}
	if !loaded {
		path, pathErr := SharedDaemonLaunchAgentPath()
		if pathErr != nil {
			return rollback(pathErr)
		}
		// 正常 owner 的 RunAtLoad 会在 bootstrap 时执行一次幂等 start；pending
		// owner 为 false，只注册显式迁移稍后可 kickstart 的入口，不会启动 daemon。
		if _, bootstrapErr := sharedDaemonLaunchctl(ctx, "bootstrap", launchAgentDomainTarget(), path); bootstrapErr != nil {
			return rollback(bootstrapErr)
		}
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
				return restoreSharedDaemonOwner(rollbackCtx, before, previousPlist)
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
// job 是一次性官方控制命令，回滚不会 stop 已运行的 app-server daemon。
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

// RemoveSharedDaemonLaunchAgent 关闭共享时卸载 job 并删除 plist。不停止已经在运行
// 的 daemon：那会打断仍在使用它的 Desktop 或移动端任务。
func RemoveSharedDaemonLaunchAgent(ctx context.Context) error {
	path, err := SharedDaemonLaunchAgentPath()
	if err != nil {
		return err
	}
	loaded, _, inspectErr := inspectLaunchAgentState(ctx)
	if inspectErr != nil {
		return inspectErr
	}
	if loaded {
		if _, bootoutErr := sharedDaemonLaunchctl(ctx, "bootout", launchAgentServiceTarget()); bootoutErr != nil &&
			!isLaunchctlNotLoaded(bootoutErr) {
			return bootoutErr
		}
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

func removeSharedDaemonOwnerUnlocked(ctx context.Context) error {
	_, err := removeSharedDaemonOwnerForTransactionUnlocked(ctx)
	return err
}

// removeSharedDaemonOwnerForTransactionUnlocked 在调用方持有 operation lock 时
// 移除 owner。先把磁盘 plist 降为 manual，再 bootout/delete；因此删除任一步
// 失败也不会留下可在下次登录自动启动的 owner。返回值保留兼容签名，但禁用
// 事务不再恢复 auto owner：配置可能已被锁外编辑器改成 WS，恢复会越权。
func removeSharedDaemonOwnerForTransactionUnlocked(
	ctx context.Context,
) (func(context.Context) error, error) {
	before, err := InspectSharedDaemonOwner(ctx)
	if err != nil {
		return nil, err
	}
	if before.Loaded && !before.Installed {
		// 没有磁盘 plist 就无法在失败时重新 bootstrap 同一个 job。先于 bootout
		// 拒绝这种外部/残缺状态，保证后面的删除事务始终可完整回滚。
		return nil, fmt.Errorf("共享 daemon LaunchAgent 已加载但磁盘 plist 缺失，拒绝卸载")
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
	if err := ValidateManagedLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
		return LocalDaemonStatus{}, err
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
	if !owner.MigrationRequired {
		probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
		probe, probeErr := ProbeLocalDaemonInfo(probeCtx, socketPath)
		cancel()
		if probeErr == nil {
			lifecycle, lifecycleErr := InspectLocalDaemonLifecycle(ctx, options)
			if lifecycleErr != nil {
				return LocalDaemonStatus{}, fmt.Errorf("确认现有共享 daemon 生命周期失败：%w", lifecycleErr)
			}
			if lifecycleErr := ValidateManagedLocalDaemonLifecycle(lifecycle, socketPath); lifecycleErr != nil {
				return LocalDaemonStatus{}, lifecycleErr
			}
			if identityErr := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); identityErr != nil {
				return LocalDaemonStatus{}, identityErr
			}
			status := localDaemonStatus(socketPath, false, probe.Version, os.Stat)
			status.OwnerInstalled = true
			return status, nil
		}
	}
	if err := stopSharedDaemon(ctx, options, owner); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := waitForSharedDaemonStopped(ctx, socketPath); err != nil {
		return LocalDaemonStatus{}, err
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
	if err := ValidateManagedLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := commitSharedDaemonMigration(options); err != nil {
		return LocalDaemonStatus{}, err
	}
	status := localDaemonStatus(socketPath, true, probe.Version, os.Stat)
	status.OwnerInstalled = true
	return status, nil
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

func waitForSharedDaemonStopped(ctx context.Context, socketPath string) error {
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
			return nil
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

func stopSharedDaemon(
	ctx context.Context,
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
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
	if err := requireCodexDesktopStopped(ctx, "停止官方 Codex daemon 前"); err != nil {
		return err
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

func stopUnmanagedSharedDaemon(
	ctx context.Context,
	options LocalDaemonOptions,
	lifecycle LocalDaemonLifecycleStatus,
) error {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return err
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancelProbe()
	if err != nil {
		return fmt.Errorf("无法确认待接管的 Codex app-server：%w", err)
	}
	if err := ValidateLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
		return err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
		return err
	}
	if err := validatePrivateSharedDaemonSocket(socketPath, os.Getuid()); err != nil {
		return err
	}

	return stopUnmanagedSharedDaemonWithHooks(
		ctx,
		socketPath,
		lifecycle.ManagedCodexPath,
		unmanagedSharedDaemonHooks{
			desktopRunning: sharedDaemonDesktopRunning,
			inspect:        inspectSharedDaemonListenerProcess,
			signalTERM:     signalSharedDaemonProcessTERM,
			currentUID:     os.Getuid,
		},
	)
}

func stopUnmanagedSharedDaemonWithHooks(
	ctx context.Context,
	socketPath string,
	managedCodexPath string,
	hooks unmanagedSharedDaemonHooks,
) error {
	running, err := hooks.desktopRunning(ctx)
	if err != nil {
		return fmt.Errorf("确认 Codex Desktop 已退出失败：%w", err)
	}
	if running {
		return fmt.Errorf("Codex Desktop 仍在运行，拒绝接管非 daemon 管理的 app-server")
	}

	listener, err := hooks.inspect(ctx, socketPath)
	if err != nil {
		return fmt.Errorf("识别非 daemon 管理的 Codex app-server 失败：%w", err)
	}
	if err := validateSharedDaemonListenerProcess(listener, hooks.currentUID(), managedCodexPath); err != nil {
		return err
	}
	// PID 可能在检查命令行期间退出并被复用。发送信号前再次从 socket
	// 反查 owner；PID、UID、命令与可执行文件任一变化都停止迁移。
	confirmed, err := hooks.inspect(ctx, socketPath)
	if err != nil {
		return fmt.Errorf("再次确认 Codex app-server owner 失败：%w", err)
	}
	if confirmed != listener {
		return fmt.Errorf("Codex app-server owner 在接管前发生变化，已停止迁移")
	}
	// 用户可能在首次检查后从 Dock 重新打开 Desktop。信号前必须
	// 再按 bundle id 查一次；读取失败也 fail closed，不能凭旧快照
	// 终止已经被新 Desktop 重新使用的 backend。
	running, err = hooks.desktopRunning(ctx)
	if err != nil {
		return fmt.Errorf("信号前再次确认 Codex Desktop 已退出失败：%w", err)
	}
	if running {
		return fmt.Errorf("Codex Desktop 在迁移前被重新打开，已停止接管")
	}
	if err := hooks.signalTERM(listener.PID); err != nil {
		return fmt.Errorf("正常终止旧 Codex app-server 失败：%w", err)
	}
	return nil
}

func validateSharedDaemonListenerProcess(
	process sharedDaemonListenerProcess,
	currentUID int,
	managedCodexPath string,
) error {
	if process.PID <= 1 {
		return fmt.Errorf("Codex app-server socket owner PID 无效")
	}
	if process.UID != currentUID {
		return fmt.Errorf("Codex app-server socket owner 不属于当前用户，拒绝接管")
	}
	if strings.TrimSpace(process.Executable) == "" ||
		!sameCanonicalPath(process.Executable, managedCodexPath) {
		return fmt.Errorf("Codex app-server socket owner 不是官方 managed standalone，拒绝接管")
	}
	if !isDirectUnixAppServerCommand(process.Command) {
		return fmt.Errorf("Codex app-server socket owner 命令行不符合原生 SSH 启动模式，拒绝接管")
	}
	return nil
}

func isDirectUnixAppServerCommand(command string) bool {
	var fields []string
	if strings.Contains(command, "\x00") {
		for _, field := range strings.Split(command, "\x00") {
			if field != "" {
				fields = append(fields, field)
			}
		}
	} else {
		fields = strings.Fields(strings.TrimSpace(command))
	}
	if len(fields) < 3 {
		return false
	}
	appServerIndex := -1
	for index, field := range fields {
		if field == "app-server" {
			appServerIndex = index
			break
		}
	}
	if appServerIndex < 0 {
		return false
	}
	// `app-server daemon ...` 与 `app-server proxy ...` 都是另一种官方
	// 责任链，不能当成 SSH bootstrap 的直接 listener 接管。
	for _, field := range fields[appServerIndex+1:] {
		if field == "daemon" || field == "proxy" {
			return false
		}
	}
	for index := appServerIndex + 1; index < len(fields); index++ {
		switch {
		case fields[index] == "--listen" && index+1 < len(fields):
			return fields[index+1] == "unix://"
		case strings.HasPrefix(fields[index], "--listen="):
			return strings.TrimPrefix(fields[index], "--listen=") == "unix://"
		}
	}
	return false
}

func codexDesktopProcessRunning(ctx context.Context) (bool, error) {
	// Desktop 的当前 App 名与可执行文件名是 ChatGPT，历史名称却是
	// Codex。进程名不是稳定契约；LaunchServices bundle id 与 Swift 端
	// NSWorkspace 的识别方式一致，也能覆盖同 bundle 的多个实例。
	cmd := exec.CommandContext(ctx, "/usr/bin/lsappinfo", "find", "bundleid="+codexDesktopBundleID)
	configureManagedCommand(cmd)
	output, err := cmd.Output()
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(output)) != "", nil
}

func inspectSharedDaemonListenerProcess(
	ctx context.Context,
	socketPath string,
) (sharedDaemonListenerProcess, error) {
	pid, peerUID, err := sharedDaemonSocketPeer(ctx, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, err
	}
	kinfo, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || int(kinfo.Proc.P_pid) != pid {
		return sharedDaemonListenerProcess{}, fmt.Errorf("读取 socket owner 进程身份失败")
	}
	if int(kinfo.Eproc.Ucred.Uid) != peerUID {
		return sharedDaemonListenerProcess{}, fmt.Errorf("socket peer UID 与进程 UID 不一致")
	}
	executable, arguments, err := sharedDaemonProcessArguments(pid)
	if err != nil {
		return sharedDaemonListenerProcess{}, err
	}
	return sharedDaemonListenerProcess{
		PID:        pid,
		UID:        peerUID,
		StartSec:   kinfo.Proc.P_starttime.Sec,
		StartUsec:  kinfo.Proc.P_starttime.Usec,
		Command:    strings.Join(arguments, "\x00"),
		Executable: executable,
	}, nil
}

func sharedDaemonSocketPeer(ctx context.Context, socketPath string) (int, int, error) {
	dialer := net.Dialer{Timeout: localDaemonProbeTimeout}
	conn, err := dialer.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return 0, 0, fmt.Errorf("连接 Codex app-server socket 失败：%w", err)
	}
	defer conn.Close()
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, 0, fmt.Errorf("Codex app-server socket 不是 UnixConn")
	}
	raw, err := unixConn.SyscallConn()
	if err != nil {
		return 0, 0, fmt.Errorf("读取 Codex app-server socket fd 失败：%w", err)
	}
	var peerPID int
	var peerUID int
	var controlErr error
	if err := raw.Control(func(fd uintptr) {
		peerPID, controlErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
		if controlErr != nil {
			return
		}
		credentials, credentialsErr := unix.GetsockoptXucred(
			int(fd),
			unix.SOL_LOCAL,
			unix.LOCAL_PEERCRED,
		)
		if credentialsErr != nil {
			controlErr = credentialsErr
			return
		}
		peerUID = int(credentials.Uid)
	}); err != nil {
		return 0, 0, fmt.Errorf("读取 Codex app-server socket peer 失败：%w", err)
	}
	if controlErr != nil {
		return 0, 0, fmt.Errorf("读取 Codex app-server socket peer 身份失败：%w", controlErr)
	}
	if peerPID <= 1 || peerUID < 0 {
		return 0, 0, fmt.Errorf("Codex app-server socket peer 身份无效")
	}
	return peerPID, peerUID, nil
}

func sharedDaemonProcessArguments(pid int) (string, []string, error) {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", nil, fmt.Errorf("读取 socket owner 进程参数失败：%w", err)
	}
	if len(raw) < 5 {
		return "", nil, fmt.Errorf("socket owner 进程参数过短")
	}
	argc := int(binary.LittleEndian.Uint32(raw[:4]))
	if argc <= 0 || argc > 4096 {
		return "", nil, fmt.Errorf("socket owner argc 无效")
	}
	cursor := raw[4:]
	executableEnd := bytes.IndexByte(cursor, 0)
	if executableEnd <= 0 {
		return "", nil, fmt.Errorf("socket owner 缺少 executable path")
	}
	executable := string(cursor[:executableEnd])
	if !filepath.IsAbs(executable) {
		return "", nil, fmt.Errorf("socket owner executable path 不是绝对路径")
	}
	cursor = cursor[executableEnd+1:]
	for len(cursor) > 0 && cursor[0] == 0 {
		cursor = cursor[1:]
	}
	arguments := make([]string, 0, argc)
	for len(arguments) < argc {
		argumentEnd := bytes.IndexByte(cursor, 0)
		if argumentEnd < 0 {
			return "", nil, fmt.Errorf("socket owner argv 未完整终止")
		}
		arguments = append(arguments, string(cursor[:argumentEnd]))
		cursor = cursor[argumentEnd+1:]
	}
	return executable, arguments, nil
}

func validatePrivateSharedDaemonSocket(socketPath string, currentUID int) error {
	info, err := os.Lstat(socketPath)
	if err != nil {
		return fmt.Errorf("检查 Codex app-server socket 失败：%w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("Codex app-server 路径不是 Unix socket")
	}
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("Codex app-server socket 权限不是 0600，拒绝接管")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != currentUID {
		return fmt.Errorf("Codex app-server socket 不属于当前用户，拒绝接管")
	}
	return nil
}

func signalSharedDaemonProcessTERM(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(syscall.SIGTERM)
}

// waitForSharedDaemonSocket 把 launchd 的异步启动重新变成同步语义：官方
// `daemon start` 原本是阻塞的，调用方依赖“返回即已就绪”。
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
