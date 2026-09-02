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
	fileAccessMu               sync.RWMutex
	fileAccessPreflightStarted bool
	fileAccessPreflight        Check
}

type doctorSSHTransport interface {
	CheckRemoteCodex(context.Context) (string, error)
	EnsureReady(context.Context) error
	SSHCheckCommand() string
}

var newDoctorSSHTransport = func(options appserver.SSHTransportOptions) (doctorSSHTransport, error) {
	return appserver.NewSSHTransport(options)
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
		version:  version,
		cfg:      cfg,
		registry: registry,
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
	if check := legacyCodexExperimentCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.fileAccessPreflightCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.configFileCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.appServerTokenFileCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if check := c.windowsLANCheck(ctx); check.Name != "" {
		checks = append(checks, check)
	}
	if c.needsCodexAppServerCheck() {
		checks = append(checks, c.codexAppServerCheck(ctx))
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

func legacyCodexExperimentCheck() Check {
	residue, err := appserver.LegacyCodexExperimentResidue()
	if err != nil {
		return Check{Name: "legacy-codex-experiment", OK: false, Message: err.Error(), Fix: "确认当前用户可以执行 launchctl 后重试"}
	}
	if residue == "" {
		return Check{}
	}
	return Check{
		Name:    "legacy-codex-experiment",
		OK:      false,
		Message: "检测到旧 Codex Desktop 共享实验残留：" + residue,
		Fix:     "先退出 Codex Desktop，并用旧实验版本关闭共享；当前版本不会自动终止任务或删除 owner",
	}
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
	case "tailscale", "macos-code-signing", "file-access-preflight":
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
	if runtime.GOOS != "windows" ||
		!strings.EqualFold(strings.TrimSpace(c.cfg.AppServer.Transport), "ws") ||
		!c.cfg.AppServer.Managed {
		return Check{}
	}
	path := strings.TrimSpace(c.cfg.AppServer.WSTokenFile)
	if path == "" {
		return Check{
			Name:    "app-server-token-file",
			OK:      false,
			Message: "app-server token file 未配置",
			Fix:     "运行 agentd setup --force 重新生成 Windows 本机 App Server 配置",
		}
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
		transport = "ssh"
	}
	switch transport {
	case "ssh":
		if err := config.ValidateAppServerSSHTarget(c.cfg.AppServer.SSHTarget); err != nil {
			return Check{Name: "app-server", OK: false, Message: "app-server SSH target 无效", Fix: "将 app_server.ssh_target 设为 127.0.0.1 或可用 SSH 主机"}
		}
		return Check{Name: "app-server", OK: true, Message: "Codex app-server 使用共享 SSH proxy"}
	case "ws":
		if runtime.GOOS != "windows" || !c.cfg.AppServer.Managed {
			return Check{Name: "app-server", OK: false, Message: "app-server WebSocket 模式无效", Fix: "Windows 必须使用受管 loopback WebSocket；其他平台使用 ssh"}
		}
		if !isLoopbackListen(c.cfg.AppServer.Listen) {
			return Check{Name: "app-server", OK: false, Message: "app-server WebSocket 不在 loopback", Fix: "将 app_server.listen 设置为 ws://127.0.0.1:<port>"}
		}
		return Check{Name: "app-server", OK: true, Message: "Codex app-server 使用 Windows 本机受管 WebSocket"}
	default:
		return Check{Name: "app-server", OK: false, Message: "app-server transport 配置无效", Fix: "将 app_server.transport 设置为 ssh；Windows 本机宿主可使用受管 ws"}
	}
}

func (c *Checker) needsCodexAppServerCheck() bool {
	return true
}

func (c *Checker) codexAppServerCheck(ctx context.Context) Check {
	if strings.EqualFold(strings.TrimSpace(c.cfg.AppServer.Transport), "ws") {
		version, err := appserver.CheckLocalCodex(ctx, c.cfg.Codex.Bin)
		if err != nil {
			return Check{Name: "codex-app-server", OK: false, Message: "本机 Codex CLI 版本不兼容", Fix: err.Error()}
		}
		codexBin := strings.TrimSpace(c.cfg.Codex.Bin)
		if codexBin == "" {
			codexBin = "codex"
		}
		runCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		output, err := exec.CommandContext(runCtx, codexBin, "app-server", "--help").CombinedOutput()
		help := string(output)
		if err != nil ||
			!strings.Contains(help, "--listen") ||
			!strings.Contains(help, "--ws-auth") ||
			!strings.Contains(help, "--ws-token-file") {
			return Check{Name: "codex-app-server", OK: false, Message: "本机 Codex CLI 不支持 app-server WebSocket", Fix: "升级 Codex CLI 后重试"}
		}
		return Check{Name: "codex-app-server", OK: true, Message: fmt.Sprintf("本机 Codex %s 支持受管 App Server", version)}
	}
	transport, err := newDoctorSSHTransport(appserver.SSHTransportOptions{Target: c.cfg.AppServer.SSHTarget})
	if err != nil {
		return Check{Name: "codex-app-server", OK: false, Message: "SSH App Server 配置无效", Fix: "检查 app_server.ssh_target"}
	}
	version, err := transport.CheckRemoteCodex(ctx)
	if err != nil {
		return Check{Name: "codex-app-server", OK: false, Message: "SSH host key、非交互密钥或远程 Codex 版本检查失败", Fix: "先手工执行：" + transport.SSHCheckCommand()}
	}
	if err := transport.EnsureReady(ctx); err != nil {
		return Check{Name: "codex-app-server", OK: false, Message: "SSH proxy 无法完成 app-server initialize", Fix: "运行 agentd logs 查看 SSH proxy 错误"}
	}
	return Check{Name: "codex-app-server", OK: true, Message: fmt.Sprintf("远程 Codex %s 与 SSH proxy initialize 可用", version)}
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
