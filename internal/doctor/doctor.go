package doctor

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

type Checker struct {
	version                    string
	cfg                        config.Config
	registry                   *projects.Registry
	configPath                 string
	sharedDaemonDiagnostics    func(context.Context, appserver.LocalDaemonOptions) (appserver.SharedDaemonDiagnostics, error)
	fileAccessMu               sync.RWMutex
	fileAccessPreflightStarted bool
	fileAccessPreflight        Check
}

type Results struct {
	OK      bool    `json:"ok"`
	Version string  `json:"version"`
	Listen  string  `json:"listen"`
	Checks  []Check `json:"checks"`
}

type Check struct {
	Name       string `json:"name"`
	OK         bool   `json:"ok"`
	Level      string `json:"level"`
	Message    string `json:"message"`
	Fix        string `json:"fix,omitempty"`
	Capability string `json:"capability,omitempty"`
	State      string `json:"state,omitempty"`
	Reason     string `json:"reason,omitempty"`
}

func NewChecker(version string, cfg config.Config, registry *projects.Registry, configPath ...string) *Checker {
	checker := &Checker{
		version:                 version,
		cfg:                     cfg,
		registry:                registry,
		sharedDaemonDiagnostics: appserver.InspectSharedDaemonDiagnostics,
	}
	// variadic 参数保持现有嵌入方兼容；CLI 传入真实路径后才启用配置文件权限检查。
	if len(configPath) > 0 {
		checker.configPath = expandConfigPath(configPath[0])
	}
	return checker
}

// ConfigPath 返回启动时已解析的真实配置路径，供同一进程中的长期恢复任务
// 在执行持久化动作前重新验证配置所有权。空值表示调用方未注入路径。
func (c *Checker) ConfigPath() string {
	if c == nil {
		return ""
	}
	return c.configPath
}

func (c *Checker) Run(ctx context.Context, checkPort bool) Results {
	projectsCount := len(c.registry.List())
	tokenOK := c.cfg.DevInsecure || c.cfg.Auth.Token != ""
	tokenMessage := "Token 已配置"
	if !tokenOK {
		tokenMessage = "Token 未配置"
	}
	codexOK := commandExists(c.cfg.Codex.Bin)
	codexMessage := "Codex CLI 可执行"
	if !codexOK {
		codexMessage = "未找到 Codex CLI"
	}
	checks := []Check{
		{Name: "token", OK: tokenOK, Message: tokenMessage, Fix: "执行 agentd setup 生成随机 token，或设置 AGENTD_TOKEN"},
		{Name: "projects", OK: projectsCount > 0, Message: fmt.Sprintf("已加载 %d 个项目", projectsCount), Fix: "在 config.json 配置 projects，或设置 AGENTD_PROJECTS=/path/a,/path/b"},
		{Name: "codex", OK: codexOK, Message: codexMessage, Fix: "安装 Codex CLI 并确认 codex 在 PATH 中；Homebrew service 推荐先运行 agentd setup 记录绝对路径"},
		c.runtimeCheck(),
		{Name: "tailscale", OK: commandExists("tailscale"), Message: "检测到 Tailscale 命令", Fix: "安装并登录 Tailscale：https://tailscale.com/download"},
	}
	if check := macOSCodeSigningCheck(ctx); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.fileAccessPreflightCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.configFileCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.windowsLANCheck(ctx); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.appServerTokenFileCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if c.needsCodexAppServerCheck() {
		checks = append(checks, c.codexAppServerCheck(ctx))
	}
	if check := c.localDaemonLifecycleCheck(ctx); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.sharedDaemonOwnerCheck(ctx); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.sharedDaemonRuntimeCheck(ctx); check.Name != "" {
		checks = append(checks, check)
	}
	checks = append(checks, c.claudeBridgeCheck(ctx))
	if check := c.appServerGatewayCheck(ctx); check.Name != "" {
		checks = append(checks, check)
	}
	if checkPort {
		checks = append(checks, c.portChecks(ctx)...)
	}
	return c.results(checks)
}

// RunReadiness 只执行能够直接判断当前 HTTP/gateway 是否可承接移动端请求的本地检查。
// codesign、CLI --help、bridge --version 等外部进程属于完整诊断；把它们放进高频 readyz
// 会在主机高负载时制造假离线，并让 status 子进程超过 macOS App 的执行上限。
func (c *Checker) RunReadiness(ctx context.Context) Results {
	projectsCount := len(c.registry.List())
	tokenOK := c.cfg.DevInsecure || c.cfg.Auth.Token != ""
	tokenMessage := "Token 已配置"
	if !tokenOK {
		tokenMessage = "Token 未配置"
	}
	checks := []Check{
		{Name: "token", OK: tokenOK, Message: tokenMessage, Fix: "执行 agentd setup 生成随机 token，或设置 AGENTD_TOKEN"},
		{Name: "projects", OK: projectsCount > 0, Message: fmt.Sprintf("已加载 %d 个项目", projectsCount), Fix: "在 config.json 配置 projects，或设置 AGENTD_PROJECTS=/path/a,/path/b"},
		c.runtimeCheck(),
	}
	if check := c.configFileCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.appServerTokenFileCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.appServerGatewayCheck(ctx); check.Name != "" {
		checks = append(checks, check)
	}
	return c.results(checks)
}

func (c *Checker) results(checks []Check) Results {
	ok := true
	for i := range checks {
		if checks[i].OK {
			checks[i].Level = "ok"
			continue
		}
		if strings.EqualFold(strings.TrimSpace(checks[i].Level), "warning") || isWarningOnlyCheck(checks[i].Name) {
			if checks[i].Name == "tailscale" {
				checks[i].Message = "未检测到 Tailscale 命令，本机访问仍可使用"
			}
			checks[i].Level = "warning"
			continue
		}
		checks[i].Level = "error"
		ok = false
	}
	return Results{OK: ok, Version: c.version, Listen: c.cfg.Listen, Checks: checks}
}

func isWarningOnlyCheck(name string) bool {
	switch name {
	case "tailscale", "macos-code-signing", "file-access-preflight", "codex-daemon-lifecycle-external":
		return true
	default:
		return false
	}
}

func macOSCodeSigningCheck(ctx context.Context) Check {
	if runtime.GOOS != "darwin" {
		return Check{}
	}
	executable, err := os.Executable()
	if err != nil {
		return unstableMacOSCodeSigningCheck("无法确定当前 agentd 可执行文件")
	}
	runCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	output, err := exec.CommandContext(runCtx, "/usr/bin/codesign", "-d", "-r-", executable).CombinedOutput()
	if err != nil {
		return unstableMacOSCodeSigningCheck("agentd 没有可验证的代码签名")
	}
	requirement := designatedRequirement(string(output))
	if !isStableDesignatedRequirement(requirement) {
		return unstableMacOSCodeSigningCheck("agentd 代码身份绑定当前二进制哈希，重新编译后 macOS 文件授权可能失效")
	}
	return Check{Name: "macos-code-signing", OK: true, Message: "agentd 使用可跨构建识别的稳定代码签名"}
}

func unstableMacOSCodeSigningCheck(message string) Check {
	return Check{
		Name:    "macos-code-signing",
		OK:      false,
		Message: message,
		Fix:     "源码开发运行 bash ./scripts/restart-agentd-dev-macos.sh；正式安装请升级到带 Developer ID 签名的版本",
	}
}

func designatedRequirement(output string) string {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "#"))
		if index := strings.Index(line, "designated =>"); index >= 0 {
			return strings.TrimSpace(line[index+len("designated =>"):])
		}
	}
	return ""
}

func isStableDesignatedRequirement(requirement string) bool {
	normalized := strings.ToLower(strings.TrimSpace(requirement))
	// Go 链接器生成的 ad-hoc 签名只有 cdhash；每次 build 都会变。
	// 稳定身份至少需要固定 identifier 和受证书链约束的 anchor。
	return normalized != "" &&
		!strings.Contains(normalized, "cdhash") &&
		strings.Contains(normalized, "identifier") &&
		strings.Contains(normalized, "anchor")
}

func (c *Checker) configFileCheck() Check {
	path := strings.TrimSpace(c.configPath)
	if path == "" {
		return Check{}
	}
	return sensitiveFileCheck("config-file", "配置文件", path)
}

func (c *Checker) appServerTokenFileCheck() Check {
	if strings.EqualFold(strings.TrimSpace(c.cfg.AppServer.Transport), "unix") {
		return Check{}
	}
	path := strings.TrimSpace(c.cfg.AppServer.WSTokenFile)
	if path == "" {
		if c.cfg.AppServer.Managed && strings.EqualFold(firstNonEmpty(c.cfg.AppServer.Transport, "ws"), "ws") {
			return Check{
				Name:    "app-server-token-file",
				OK:      false,
				Message: "托管 app-server 未配置独立 token file",
				Fix:     "运行 agentd doctor --fix 生成独立 token file；不要手工复用 agentd 访问 token",
			}
		}
		return Check{}
	}
	return sensitiveFileCheck("app-server-token-file", "app-server token file", path)
}

func sensitiveFileCheck(name string, label string, path string) Check {
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Check{Name: name, OK: false, Message: label + "不存在", Fix: "运行 agentd doctor --fix 自动修复，或确认文件路径正确"}
		}
		return Check{Name: name, OK: false, Message: label + "状态不可读取", Fix: "检查文件所有者和权限"}
	}
	if !info.Mode().IsRegular() {
		// Lstat 会把符号链接识别为非 regular，避免敏感路径被替换后指向意外文件。
		return Check{Name: name, OK: false, Message: label + "必须是 regular file，不能是目录或符号链接", Fix: "改用当前用户拥有的普通文件"}
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return Check{
			Name:    name,
			OK:      false,
			Message: fmt.Sprintf("%s权限过宽（当前 %04o）", label, info.Mode().Perm()),
			Fix:     "运行 agentd doctor --fix 将权限收紧为 0600",
		}
	}
	file, err := os.Open(path)
	if err != nil {
		return Check{Name: name, OK: false, Message: label + "不可读取", Fix: "检查文件所有者和当前用户读取权限"}
	}
	_ = file.Close()
	return Check{Name: name, OK: true, Message: label + "存在且权限仅当前用户可访问"}
}

func expandConfigPath(path string) string {
	value := strings.TrimSpace(path)
	if !strings.HasPrefix(value, "~/") {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return value
	}
	return filepath.Join(home, strings.TrimPrefix(value, "~/"))
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func (c *Checker) runtimeCheck() Check {
	runtimeType := c.cfg.Runtime.Type
	if runtimeType == "" {
		runtimeType = "codex_app_server"
	}
	if runtimeType != "codex_app_server" {
		return Check{Name: "runtime", OK: false, Message: fmt.Sprintf("当前运行时配置无效：%s", runtimeType), Fix: "设置 runtime.type=codex_app_server，或重新执行 agentd setup"}
	}
	return Check{Name: "runtime", OK: true, Message: "当前运行时：codex_app_server"}
}

func (c *Checker) appServerGatewayCheck(ctx context.Context) Check {
	transport := c.cfg.AppServer.Transport
	if transport == "" {
		transport = "ws"
	}
	switch transport {
	case "ws":
		if c.cfg.AppServer.Listen == "" {
			return Check{Name: "app-server", OK: false, Message: "app-server ws upstream 未配置", Fix: "执行 agentd setup 生成默认 loopback upstream"}
		}
		if isLoopbackListen(c.cfg.AppServer.Listen) {
			return Check{Name: "app-server", OK: true, Message: "Codex app-server ws upstream 仅限 loopback 本机访问"}
		}
		return Check{
			Name:    "app-server",
			OK:      false,
			Message: "Codex app-server 不应暴露到非 loopback 网络",
			Fix:     "将 app_server.listen 改为 127.0.0.1，仅让 iPad 连接 agentd",
		}
	case "unix":
		if listen := strings.TrimSpace(c.cfg.AppServer.Listen); listen != "" && listen != appserver.LocalDaemonListen {
			return Check{Name: "app-server", OK: false, Message: "共享 Codex daemon 地址无效", Fix: "将 app_server.listen 设置为 unix://"}
		}
		socketPath, err := appserver.LocalDaemonSocketPath(c.cfg.Codex.Env)
		if err != nil {
			return Check{Name: "app-server", OK: false, Message: "共享 Codex daemon 路径不可用", Fix: err.Error()}
		}
		probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		probe, err := appserver.ProbeLocalDaemonInfo(probeCtx, socketPath)
		cancel()
		if err != nil {
			return Check{
				Name:    "app-server",
				OK:      false,
				Message: "共享 Codex daemon 当前不可连接",
				Fix:     "先在 Mac 设置中重新启用共享服务；若提示 standalone 缺失，请安装官方 Codex 命令行工具",
			}
		}
		return Check{Name: "app-server", OK: true, Message: "Codex Desktop 与 Mimi 使用同一私有 Unix app-server（" + probe.Version + "）"}
	default:
		return Check{Name: "app-server", OK: false, Message: "app-server transport 配置无效", Fix: "设置 AGENTD_APP_SERVER_TRANSPORT=unix 或 ws"}
	}
}

func (c *Checker) needsCodexAppServerCheck() bool {
	return true
}

func (c *Checker) codexAppServerCheck(ctx context.Context) Check {
	if !commandExists(c.cfg.Codex.Bin) {
		return Check{Name: "codex-app-server", OK: false, Message: "无法检查 Codex app-server 能力", Fix: "先安装 Codex CLI"}
	}
	runCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(runCtx, c.cfg.Codex.Bin, "app-server", "--help").CombinedOutput()
	if err != nil {
		return Check{Name: "codex-app-server", OK: false, Message: "Codex CLI 不支持 app-server 命令", Fix: "升级 Codex CLI，然后重新执行 agentd doctor"}
	}
	help := string(out)
	requiredFlags := []string{"--listen"}
	if !strings.EqualFold(strings.TrimSpace(c.cfg.AppServer.Transport), "unix") {
		requiredFlags = append(requiredFlags, "--ws-auth", "--ws-token-file")
	}
	for _, flag := range requiredFlags {
		if !strings.Contains(help, flag) {
			return Check{Name: "codex-app-server", OK: false, Message: "Codex app-server 缺少必要 transport 参数", Fix: "升级 Codex CLI 到支持共享 app-server 的版本"}
		}
	}
	if strings.EqualFold(strings.TrimSpace(c.cfg.AppServer.Transport), "unix") {
		daemonCtx, daemonCancel := context.WithTimeout(ctx, 3*time.Second)
		defer daemonCancel()
		if output, err := exec.CommandContext(daemonCtx, c.cfg.Codex.Bin, "app-server", "daemon", "start", "--help").CombinedOutput(); err != nil || !strings.Contains(string(output), "local app server daemon") {
			return Check{Name: "codex-app-server", OK: false, Message: "Codex CLI 不支持 local daemon", Fix: "升级 Codex CLI 后重新运行 agentd doctor"}
		}
		return Check{Name: "codex-app-server", OK: true, Message: "Codex app-server Unix daemon 能力可用"}
	}
	return Check{Name: "codex-app-server", OK: true, Message: "Codex app-server WebSocket 能力可用"}
}

func (c *Checker) localDaemonLifecycleCheck(ctx context.Context) Check {
	if !strings.EqualFold(strings.TrimSpace(c.cfg.AppServer.Transport), "unix") {
		return Check{}
	}
	checkName := "codex-daemon-lifecycle"
	if !c.cfg.AppServer.Managed {
		// 外部 Unix upstream 的生命周期由部署方负责；doctor 仍报告风险，但不
		// 应替外部 owner 宣布服务不可用。
		checkName = "codex-daemon-lifecycle-external"
	}
	check := Check{
		Name: checkName,
		Fix:  "安装官方 standalone Codex 命令行工具，确保 Mac 重启后 local daemon 仍可自动恢复",
	}
	runCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	status, err := appserver.InspectLocalDaemonLifecycle(runCtx, appserver.LocalDaemonOptions{
		CodexBin: c.cfg.Codex.Bin,
		Env:      c.cfg.Codex.Env,
	})
	cancel()
	if err != nil {
		check.Message = "共享 daemon 当前可由 socket 检查，但官方生命周期状态不可用"
		return check
	}
	expectedSocket, err := appserver.LocalDaemonSocketPath(c.cfg.Codex.Env)
	if err != nil {
		check.Message = "无法解析共享 daemon 的 CODEX_HOME"
		return check
	}
	if err := appserver.ValidateLocalDaemonLifecycle(status, expectedSocket); err != nil {
		check.Message = "当前共享 daemon 可用，但冷启动恢复条件不完整：" + err.Error()
		return check
	}
	check.OK = true
	check.Message = "官方 Codex daemon 生命周期可恢复（" + status.AppServerVersion + "）"
	return check
}

func (c *Checker) sharedDaemonOwnerCheck(ctx context.Context) Check {
	if !strings.EqualFold(strings.TrimSpace(c.cfg.AppServer.Transport), "unix") ||
		c.cfg.AppServer.SharedFallback == nil {
		return Check{}
	}
	status, err := appserver.InspectSharedDaemonOwner(ctx)
	if err != nil {
		return sharedDaemonOwnerInspectionFailureCheck(err)
	}
	if !status.Supported {
		return Check{}
	}
	check := Check{
		Name: "codex-daemon-owner",
		Fix:  "在 Mimi Remote Mac 中关闭后重新开启共享；若提示需要迁移，请保存任务后点击“应用待处理设置”并确认",
	}
	switch {
	case !status.Installed:
		check.Message = "共享 Codex daemon 缺少稳定 LaunchAgent owner"
	case !status.Secure:
		check.Message = "共享 Codex daemon LaunchAgent 权限过宽，可能暴露运行环境"
	case !status.Loaded:
		check.Message = "共享 Codex daemon LaunchAgent 已安装但未加载"
	case status.MigrationRequired:
		check.Message = "共享 Codex daemon 的稳定 owner 迁移尚未完成，等待显式应用"
	default:
		check.OK = true
		check.Message = "共享 Codex daemon 的稳定 LaunchAgent owner 已安装；TCC 归因仍需签名 App 运行态验收"
		check.Fix = ""
	}
	return check
}

// 共享 owner 检查的底层错误可能包含 LaunchAgent 或 socket 绝对路径；Doctor
// 结果会进入状态接口和远端 UI，因此只返回固定的可执行提示，不传播原始错误。
func sharedDaemonOwnerInspectionFailureCheck(_ error) Check {
	return Check{
		Name:    "codex-daemon-owner",
		OK:      false,
		Message: "无法检查共享 Codex daemon 的 launchd owner",
		Fix:     "确认共享 Codex daemon 已启用，并检查当前用户对 LaunchAgent 和进程信息的读取权限后重试",
	}
}

func (c *Checker) sharedDaemonRuntimeCheck(ctx context.Context) Check {
	if !strings.EqualFold(strings.TrimSpace(c.cfg.AppServer.Transport), "unix") {
		return Check{}
	}
	inspect := c.sharedDaemonDiagnostics
	if inspect == nil {
		inspect = appserver.InspectSharedDaemonDiagnostics
	}
	status, err := inspect(ctx, appserver.LocalDaemonOptions{
		CodexBin:    c.cfg.Codex.Bin,
		Env:         c.cfg.Codex.Env,
		StableOwner: c.cfg.AppServer.SharedFallback != nil,
	})
	return sharedDaemonRuntimeDiagnosticCheck(status, err)
}

func sharedDaemonRuntimeDiagnosticCheck(
	status appserver.SharedDaemonDiagnostics,
	err error,
) Check {
	check := Check{
		Name: "codex-daemon-resources",
		Fix:  "先保存所有活跃任务；若资源继续上涨，使用受控迁移恢复 owner，不要直接强杀进程",
	}
	if err != nil {
		check.Level = "warning"
		check.Message = "无法读取共享 Codex daemon 的 FD / 子进程水位"
		// 底层 Unix dial 错误可能包含 CODEX_HOME/socket 绝对路径；Doctor
		// 只返回固定操作建议，不把原始错误扩大到状态输出或日志。
		check.Fix = "确认共享 Codex daemon 正在运行，并允许 Mimi 读取当前用户的进程信息"
		return check
	}
	if !status.Supported {
		return Check{}
	}
	summary := sharedDaemonResourceSummary(status)
	switch status.OwnerState {
	case appserver.SharedDaemonOwnerStateExternal:
		check.OK = true
		check.Message = "共享 daemon 由外部 owner 管理；" + summary + "；FD soft limit 由外部 owner 负责"
		check.Fix = ""
	case appserver.SharedDaemonOwnerStateStable:
		switch status.ResourceState {
		case appserver.SharedDaemonResourceStateHealthy:
			check.OK = true
			check.Message = "共享 daemon 资源水位正常；" + summary
			check.Fix = ""
		case appserver.SharedDaemonResourceStateDegraded:
			check.Level = "warning"
			check.Message = "共享 daemon FD 水位偏高；" + summary
		case appserver.SharedDaemonResourceStateCritical:
			check.Message = "共享 daemon FD 接近耗尽；" + summary
		default:
			check.Level = "warning"
			check.Message = "共享 daemon owner 正常，但 FD soft limit 尚不可确认；" + summary
		}
	case appserver.SharedDaemonOwnerStateMigrationPending:
		check.Message = "共享 daemon 正在等待显式迁移，新 FD 上限尚未作用于当前 listener；" + summary
		check.Fix = "保存任务后，在 Mimi Remote Mac 中点击“应用待处理设置”并确认"
	case appserver.SharedDaemonOwnerStateUnavailable:
		check.Message = "共享 daemon listener 可用，但稳定 LaunchAgent owner 不可用；" + summary
		check.Fix = "在 Mimi Remote Mac 中关闭后重新开启共享，恢复稳定 owner"
	case appserver.SharedDaemonOwnerStateClaimedUnverified:
		check.Level = "warning"
		check.Message = "共享 daemon 的稳定 owner 已提交，但官方 lifecycle 未返回 listener PID；" + summary
		check.Fix = "继续观察真实 FD 与子进程水位；不要仅凭 owner 配置推测当前进程上限"
	case appserver.SharedDaemonOwnerStateUnmanagedListener:
		check.Message = "共享 daemon listener 尚未由官方 pid daemon 管理；" + summary
		check.Fix = "保存任务并退出 Codex Desktop 后，在 Mimi Remote Mac 中应用待处理设置"
	case appserver.SharedDaemonOwnerStateListenerMismatch:
		check.Message = "共享 daemon lifecycle PID 与真实 socket listener 不一致；" + summary
		check.Fix = "不要直接终止进程；保存任务后使用显式受控迁移重新对账 owner"
	default:
		check.Level = "warning"
		check.Message = "共享 daemon owner 状态暂时无法确认；" + summary
	}
	return check
}

func sharedDaemonResourceSummary(status appserver.SharedDaemonDiagnostics) string {
	fd := fmt.Sprintf("打开 FD %d", status.OpenFileDescriptors)
	if status.EffectiveFDSoftLimit != nil {
		fd = fmt.Sprintf("打开 FD %d/%d", status.OpenFileDescriptors, *status.EffectiveFDSoftLimit)
		if status.FDUsagePercent != nil {
			fd += fmt.Sprintf("（%.1f%%）", *status.FDUsagePercent)
		}
	} else if status.OwnerTargetFDSoftLimit != nil {
		fd += fmt.Sprintf("；owner 目标上限 %d（当前进程未验证）", *status.OwnerTargetFDSoftLimit)
	}
	return fmt.Sprintf(
		"listener PID %d，%s，直接子进程 %d",
		status.ListenerPID,
		fd,
		status.DirectChildProcesses,
	)
}

func (c *Checker) claudeBridgeCheck(ctx context.Context) Check {
	if !c.cfg.Claude.Enabled {
		return Check{Name: "claude-bridge", OK: true, Message: "Claude Code experimental 通道未启用"}
	}
	configuredBin := strings.TrimSpace(c.cfg.Claude.BridgeBin)
	bin, ok := claudebridge.ResolveBinary(configuredBin)
	if !ok {
		if configuredBin == "" {
			return Check{Name: "claude-bridge", OK: false, Message: "Claude bridge 未配置", Fix: "安装 alleycat-claude-bridge，或使用内置 bridge 的 Mimi Remote Mac"}
		}
		return Check{Name: "claude-bridge", OK: false, Message: "未找到 Claude bridge", Fix: "安装 alleycat-claude-bridge，并把 claude.bridge_bin 配成绝对路径"}
	}
	runCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	output, err := exec.CommandContext(runCtx, bin, "--version").Output()
	if err != nil {
		return Check{Name: "claude-bridge", OK: false, Message: "Claude bridge 未返回标准 --version", Fix: claudebridge.UpgradeMessage("")}
	}
	version, ok := claudebridge.ParseVersion(string(output))
	if !ok {
		return Check{Name: "claude-bridge", OK: false, Message: "Claude bridge 版本无法解析", Fix: claudebridge.UpgradeMessage("")}
	}
	if !claudebridge.IsSupported(version) {
		return Check{Name: "claude-bridge", OK: false, Message: fmt.Sprintf("Claude bridge %s 低于最低兼容版本 %s", version, claudebridge.MinimumVersion), Fix: claudebridge.UpgradeMessage(version)}
	}
	return Check{Name: "claude-bridge", OK: true, Message: fmt.Sprintf("Claude bridge %s 可用", version)}
}

func isLoopbackListen(raw string) bool {
	if strings.Contains(raw, "://") {
		parsed, err := url.Parse(raw)
		if err != nil {
			return false
		}
		raw = parsed.Host
	}
	host, _, err := net.SplitHostPort(raw)
	if err != nil {
		return raw == "localhost" || raw == "::1"
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (c *Checker) portChecks(ctx context.Context) []Check {
	checks := []Check{
		c.portCheck(ctx, "agentd-port", c.cfg.Listen, "agentd"),
	}
	if strings.EqualFold(c.cfg.AppServer.Transport, "ws") && c.cfg.AppServer.Managed && strings.TrimSpace(c.cfg.AppServer.Listen) != "" {
		checks = append(checks, c.portCheck(ctx, "app-server-port", c.cfg.AppServer.Listen, "app-server upstream"))
	}
	return checks
}

func (c *Checker) portCheck(ctx context.Context, name, listen, label string) Check {
	address, err := tcpAddressFromListen(listen)
	if err != nil {
		return Check{Name: name, OK: false, Message: fmt.Sprintf("%s 监听地址无效", label), Fix: err.Error()}
	}
	var listenConfig net.ListenConfig
	listener, err := listenConfig.Listen(ctx, "tcp", address)
	if err != nil {
		return Check{Name: name, OK: false, Message: fmt.Sprintf("%s 端口不可监听", label), Fix: "修改配置里的监听地址/端口，或关闭占用该端口的进程"}
	}
	_ = listener.Close()
	return Check{Name: name, OK: true, Message: fmt.Sprintf("%s 端口可监听", label)}
}

func tcpAddressFromListen(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", fmt.Errorf("监听地址不能为空")
	}
	if strings.Contains(value, "://") {
		parsed, err := url.Parse(value)
		if err != nil {
			return "", fmt.Errorf("解析监听地址失败：%w", err)
		}
		value = parsed.Host
	}
	if _, _, err := net.SplitHostPort(value); err == nil {
		return value, nil
	}
	if strings.Count(value, ":") == 0 {
		return "", fmt.Errorf("监听地址缺少端口：%s", value)
	}
	return "", fmt.Errorf("监听地址格式无效：%s", value)
}

func commandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func Print(w io.Writer, results Results) {
	status := "OK"
	if !results.OK {
		status = "FAIL"
	}
	fmt.Fprintf(w, "agentd doctor [%s]\n\n", status)
	fmt.Fprintf(w, "Version: %s\n", results.Version)
	fmt.Fprintf(w, "Listen:  %s\n\n", results.Listen)
	fmt.Fprintln(w, "检查结果：")
	for _, check := range results.Checks {
		marker := "OK"
		switch effectiveCheckLevel(check) {
		case "warning":
			marker = "WARN"
		case "error":
			marker = "!"
		}
		fmt.Fprintf(w, "  %s %s：%s\n", marker, check.Name, check.Message)
	}

	if !results.OK {
		fmt.Fprintln(w, "\n需要处理：")
		for _, check := range results.Checks {
			if effectiveCheckLevel(check) != "error" {
				continue
			}
			fmt.Fprintf(w, "  ! %s：%s\n", check.Name, check.Message)
			if strings.TrimSpace(check.Fix) != "" {
				fmt.Fprintf(w, "    处理：%s\n", check.Fix)
			}
		}
	}
}

func effectiveCheckLevel(check Check) string {
	switch strings.ToLower(strings.TrimSpace(check.Level)) {
	case "ok", "warning", "error":
		return strings.ToLower(strings.TrimSpace(check.Level))
	default:
		// 兼容旧代码构造的 Check：未提供 level 时仍按 ok 布尔值推导。
		if check.OK {
			return "ok"
		}
		return "error"
	}
}
