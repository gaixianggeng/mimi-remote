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

type Results struct {
	OK      bool    `json:"ok"`
	Version string  `json:"version"`
	Listen  string  `json:"listen"`
	Checks  []Check `json:"checks"`
}

type Check struct {
	Name    string `json:"name"`
	OK      bool   `json:"ok"`
	Level   string `json:"level"`
	Message string `json:"message"`
	Fix     string `json:"fix,omitempty"`
}

func NewChecker(version string, cfg config.Config, registry *projects.Registry, configPath ...string) *Checker {
	checker := &Checker{version: version, cfg: cfg, registry: registry}
	// variadic 参数保持现有嵌入方兼容；CLI 传入真实路径后才启用配置文件权限检查。
	if len(configPath) > 0 {
		checker.configPath = expandConfigPath(configPath[0])
	}
	return checker
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
	if check := c.appServerTokenFileCheck(); check.Name != "" {
		checks = append(checks, check)
	}
	if c.needsCodexAppServerCheck() {
		checks = append(checks, c.codexAppServerCheck(ctx))
	}
	checks = append(checks, c.claudeBridgeCheck(ctx))
	if check := c.appServerGatewayCheck(); check.Name != "" {
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
func (c *Checker) RunReadiness(_ context.Context) Results {
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
	if check := c.appServerGatewayCheck(); check.Name != "" {
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
		if isWarningOnlyCheck(checks[i].Name) {
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
	if info.Mode().Perm()&0o077 != 0 {
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

func (c *Checker) appServerGatewayCheck() Check {
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
	default:
		return Check{Name: "app-server", OK: false, Message: "app-server transport 配置无效", Fix: "设置 AGENTD_APP_SERVER_TRANSPORT=ws"}
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
	for _, flag := range []string{"--listen", "--ws-auth", "--ws-token-file"} {
		if !strings.Contains(help, flag) {
			return Check{Name: "codex-app-server", OK: false, Message: "Codex app-server 缺少必要 WebSocket 参数", Fix: "升级 Codex CLI 到支持 app-server WebSocket 的版本"}
		}
	}
	return Check{Name: "codex-app-server", OK: true, Message: "Codex app-server WebSocket 能力可用"}
}

func (c *Checker) claudeBridgeCheck(ctx context.Context) Check {
	if !c.cfg.Claude.Enabled {
		return Check{Name: "claude-bridge", OK: true, Message: "Claude Code experimental 通道未启用"}
	}
	bin := strings.TrimSpace(c.cfg.Claude.BridgeBin)
	if bin == "" {
		return Check{Name: "claude-bridge", OK: false, Message: "Claude bridge 未配置", Fix: "设置 claude.bridge_bin 或 AGENTD_CLAUDE_BRIDGE_BIN"}
	}
	if !commandExists(bin) {
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
