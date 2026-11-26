package main

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

type pairingBlocker struct {
	Summary string
	Fix     string
}

type pairingReadiness struct {
	Ready       bool
	PairCommand string
	Blockers    []pairingBlocker
}

type pairingCommandContext struct {
	platform       string
	configPath     string
	managedService bool
	includeConfig  bool
}

func newPairingCommandContext(configPath, platform string) pairingCommandContext {
	trimmed := strings.TrimSpace(configPath)
	if trimmed == "" {
		return pairingCommandContext{
			platform:       platform,
			managedService: true,
		}
	}
	expanded := config.ExpandPath(trimmed)
	managed := isManagedCoreConfig(expanded)
	includeConfig := !managed
	if managed && !samePairingConfigPath(expanded, config.DefaultPath()) {
		// 即使选中的是平台默认配置，只要当前环境里 AGENTD_CONFIG 指向别处，仍显式带上 --config。
		includeConfig = true
	}
	return pairingCommandContext{
		platform:       platform,
		configPath:     expanded,
		managedService: managed,
		includeConfig:  includeConfig,
	}
}

func samePairingConfigPath(a, b string) bool {
	idA, errA := config.ConfigPathIdentity(a)
	idB, errB := config.ConfigPathIdentity(b)
	if errA == nil && errB == nil {
		return idA == idB
	}
	absA, errA := absoluteConfigPath(a)
	absB, errB := absoluteConfigPath(b)
	return errA == nil && errB == nil && absA == absB
}

func (c pairingCommandContext) configFlag() string {
	if !c.includeConfig || strings.TrimSpace(c.configPath) == "" {
		return ""
	}
	return "--config " + shellQuoteArgument(c.configPath)
}

func (c pairingCommandContext) cmd(subcommand string, extraArgs ...string) string {
	parts := []string{"agentd", subcommand}
	if flag := c.configFlag(); flag != "" {
		parts = append(parts, flag)
	}
	for _, arg := range extraArgs {
		if strings.TrimSpace(arg) != "" {
			parts = append(parts, arg)
		}
	}
	return strings.Join(parts, " ")
}

func (c pairingCommandContext) startNoPair() string {
	return c.cmd("start", "--no-pair")
}

func (c pairingCommandContext) restartNoPair() string {
	return c.cmd("restart", "--no-pair")
}

func (c pairingCommandContext) serve() string {
	return c.cmd("serve")
}

// inspectPairingReadiness 复用 internal/setup 的本机配对预检，不新增平行检测，也不发起外部联网。
func inspectPairingReadiness(ctx context.Context, configPath, legacyPath, platform string) pairingReadiness {
	report := runHostPreflight(ctx, agentsetup.PreflightOptions{
		Stage:      "pair",
		ConfigPath: configPath,
		LegacyPath: legacyPath,
		Version:    version,
		HostDial:   coreDialForConfig(configPath),
	}, nil)
	return summarizePairingReadiness(report, configPath, platform)
}

func summarizePairingReadiness(report agentsetup.PreflightReport, configPath, platform string) pairingReadiness {
	cmds := newPairingCommandContext(configPath, platform)
	checksByID := make(map[string]agentsetup.PreflightCheck, len(report.Checks))
	for _, check := range report.Checks {
		checksByID[check.ID] = check
	}
	if report.OK && !report.ConfigRestartRequired {
		return pairingReadiness{
			Ready:       true,
			PairCommand: readyPairCommand(checksByID, cmds),
		}
	}
	blockers := make([]pairingBlocker, 0, 6)
	for _, check := range report.Checks {
		if !check.Blocking {
			continue
		}
		blockers = append(blockers, describePairingBlocker(check, checksByID, cmds))
	}
	if report.ConfigRestartRequired {
		blockers = append(blockers, describeConfigRestartBlocker(cmds))
	}
	if len(blockers) == 0 {
		blockers = append(blockers, pairingBlocker{
			Summary: "配对条件尚未满足",
			Fix:     fmt.Sprintf("运行 %s 和 %s 检查详细状态", cmds.cmd("doctor"), cmds.cmd("status")),
		})
	}
	return pairingReadiness{
		Ready:    false,
		Blockers: blockers,
	}
}

func readyPairCommand(checksByID map[string]agentsetup.PreflightCheck, cmds pairingCommandContext) string {
	// Tailscale 或局域网任一直连通道已就绪时使用 agentd pair --qr-only；
	// 仅 Tailcat 已就绪时给出实际可用的 agentd tailcat pair --qr-only，避免推荐会报错的命令。
	if checksByID["network_tailscale"].State == "ok" || checksByID["network_lan"].State == "ok" {
		return cmds.cmd("pair", "--qr-only")
	}
	if checksByID["network_tailcat"].State == "ok" {
		return cmds.cmd("tailcat pair", "--qr-only")
	}
	return cmds.cmd("pair", "--qr-only")
}

func describeConfigRestartBlocker(cmds pairingCommandContext) pairingBlocker {
	if !cmds.managedService {
		return pairingBlocker{
			Summary: "已保存的配置尚未应用到运行中的服务进程",
			Fix:     fmt.Sprintf("重启匹配该配置的前台进程（%s）使最新配置生效", cmds.serve()),
		}
	}
	return pairingBlocker{
		Summary: "已保存的配置尚未应用到运行中的后台服务",
		Fix:     fmt.Sprintf("运行 %s 使最新配置生效", cmds.restartNoPair()),
	}
}

func describePairingBlocker(check agentsetup.PreflightCheck, checksByID map[string]agentsetup.PreflightCheck, cmds pairingCommandContext) pairingBlocker {
	switch check.ID {
	case "config_store":
		return describeConfigStoreBlocker(check, cmds)
	case "workspace_root":
		fix := fmt.Sprintf("运行 %s 后执行 %s", cmds.cmd("workspace", "--root <代码目录路径>"), cmds.restartNoPair())
		if !cmds.managedService {
			fix = fmt.Sprintf("运行 %s，然后重启匹配该配置的前台进程（%s）", cmds.cmd("workspace", "--root <代码目录路径>"), cmds.serve())
		}
		return pairingBlocker{
			Summary: pairingDetailSummary("代码目录未就绪", check.Detail),
			Fix:     fix,
		}
	case "service_daemon":
		return describeServiceDaemonBlocker(check, cmds)
	case "assistant_any":
		return describeAssistantBlocker(checksByID, cmds)
	case "network_any":
		return describeNetworkBlocker(checksByID, cmds)
	default:
		return pairingBlocker{
			Summary: pairingDetailSummary(check.Title, check.Detail),
			Fix:     fmt.Sprintf("运行 %s 检查详细状态", cmds.cmd("doctor")),
		}
	}
}

func describeConfigStoreBlocker(check agentsetup.PreflightCheck, cmds pairingCommandContext) pairingBlocker {
	fix := fmt.Sprintf("运行 %s 和 %s", cmds.cmd("check-config", "--json"), cmds.cmd("doctor"))
	switch check.Code {
	case "config_missing":
		fix = "运行 " + cmds.cmd("setup", "--no-pair")
	case "config_permissions_unsafe":
		fix = "运行 " + cmds.cmd("doctor", "--fix")
	case "config_requires_newer_version":
		fix = "升级到最新版本的 Mimi Remote 后重试"
	}
	return pairingBlocker{
		Summary: pairingDetailSummary("配置文件未就绪", check.Detail),
		Fix:     fix,
	}
}

func describeServiceDaemonBlocker(check agentsetup.PreflightCheck, cmds pairingCommandContext) pairingBlocker {
	if !cmds.managedService {
		fix := fmt.Sprintf("检查匹配该配置的前台服务日志，并运行 %s", cmds.cmd("doctor"))
		switch check.Code {
		case "service_not_running", "service_not_registered":
			fix = fmt.Sprintf("运行 %s 启动匹配该配置的前台进程", cmds.serve())
		case "service_version_mismatch", "pair_token_mismatch":
			fix = fmt.Sprintf("重启匹配该配置的前台进程（%s）", cmds.serve())
		}
		return pairingBlocker{
			Summary: pairingDetailSummary("后台服务未就绪", check.Detail),
			Fix:     fix,
		}
	}
	fix := fmt.Sprintf("运行 agentd logs -n 200 和 %s", cmds.cmd("doctor"))
	switch check.Code {
	case "service_not_running":
		fix = "运行 " + cmds.startNoPair()
	case "service_version_mismatch", "pair_token_mismatch":
		fix = "运行 " + cmds.restartNoPair()
	case "service_not_registered":
		if cmds.platform == "linux" {
			fix = "从正式 Release 解压目录运行 bash ./scripts/install-linux.sh install"
		} else {
			fix = "先注册并启动后台服务"
		}
	}
	return pairingBlocker{
		Summary: pairingDetailSummary("后台服务未就绪", check.Detail),
		Fix:     fix,
	}
}

func describeAssistantBlocker(checksByID map[string]agentsetup.PreflightCheck, cmds pairingCommandContext) pairingBlocker {
	type assistantMeta struct {
		id         string
		label      string
		enableCmd  string
		loginHint  string
		cliEnabled bool
	}
	members := []assistantMeta{
		{id: "assistant_codex", label: "Codex", enableCmd: cmds.cmd("runtime", "--codex=enabled"), loginHint: "codex login", cliEnabled: true},
		{id: "assistant_claude", label: "Claude Code", enableCmd: cmds.cmd("runtime", "--claude=enabled"), loginHint: "claude login", cliEnabled: true},
		{id: "assistant_agy", label: "Antigravity", enableCmd: cmds.cmd("runtime", "--agy=enabled"), loginHint: "登录 agy CLI", cliEnabled: true},
		{id: "assistant_deepseek", label: "DeepSeek", enableCmd: cmds.cmd("runtime", "--deepseek=connect"), cliEnabled: false},
	}

	var availableEnable []string
	var signedOut []assistantMeta
	codexUpstreamUnavailable := false
	for _, member := range members {
		row, ok := checksByID[member.id]
		if !ok {
			continue
		}
		if member.id == "assistant_codex" && row.Code == "codex_upstream_unavailable" {
			codexUpstreamUnavailable = true
		}
		if checkAvailable(row) && member.cliEnabled {
			availableEnable = append(availableEnable, member.enableCmd)
		}
		if strings.HasSuffix(row.Code, "_signed_out") {
			signedOut = append(signedOut, member)
		}
	}

	restartSuffix := fmt.Sprintf("，然后执行 %s", cmds.restartNoPair())
	if !cmds.managedService {
		restartSuffix = fmt.Sprintf("，然后重启匹配该配置的前台进程（%s）", cmds.serve())
	}

	if len(availableEnable) > 0 {
		return pairingBlocker{
			Summary: "没有可用助手（已检测到可用助手但尚未启用）",
			Fix:     fmt.Sprintf("运行 %s%s", strings.Join(availableEnable, " 或 "), restartSuffix),
		}
	}
	if codexUpstreamUnavailable {
		fix := fmt.Sprintf("运行 %s 和 agentd logs -n 200 检查 Codex 服务状态", cmds.cmd("doctor"))
		if !cmds.managedService {
			fix = fmt.Sprintf("运行 %s 并检查前台服务日志，排查 Codex 服务状态", cmds.cmd("doctor"))
		}
		return pairingBlocker{
			Summary: "没有可用助手（Codex 服务暂不可用）",
			Fix:     fix,
		}
	}
	if len(signedOut) == 1 {
		first := signedOut[0]
		fix := fmt.Sprintf("先完成 %s 登录（%s），再运行 %s && %s", first.label, first.loginHint, first.enableCmd, cmds.restartNoPair())
		if !cmds.managedService {
			fix = fmt.Sprintf("先完成 %s 登录（%s），再运行 %s%s", first.label, first.loginHint, first.enableCmd, restartSuffix)
		}
		return pairingBlocker{
			Summary: fmt.Sprintf("没有可用助手（已检测到 %s，但尚未登录）", first.label),
			Fix:     fix,
		}
	}
	if len(signedOut) > 1 {
		labels := make([]string, 0, len(signedOut))
		steps := make([]string, 0, len(signedOut))
		for _, member := range signedOut {
			labels = append(labels, member.label)
			steps = append(steps, fmt.Sprintf("%s（%s 后运行 %s）", member.label, member.loginHint, member.enableCmd))
		}
		return pairingBlocker{
			Summary: fmt.Sprintf("没有可用助手（已检测到 %s，但尚未登录）", strings.Join(labels, " / ")),
			Fix:     fmt.Sprintf("完成任一助手登录并启用：%s%s", strings.Join(steps, "；"), restartSuffix),
		}
	}
	assistantOptions := fmt.Sprintf(
		"Codex（codex login 后运行 %s）、Claude Code（claude login 后运行 %s）、Antigravity（登录 agy 后运行 %s）或 DeepSeek（%s）",
		cmds.cmd("runtime", "--codex=enabled"),
		cmds.cmd("runtime", "--claude=enabled"),
		cmds.cmd("runtime", "--agy=enabled"),
		cmds.cmd("runtime", "--deepseek=connect"),
	)
	return pairingBlocker{
		Summary: "没有可用助手（至少需要一个已安装并登录的助手，例如 Codex 或 Claude Code）",
		Fix:     fmt.Sprintf("安装并登录后启用任一助手：%s%s", assistantOptions, restartSuffix),
	}
}

func describeNetworkBlocker(checksByID map[string]agentsetup.PreflightCheck, cmds pairingCommandContext) pairingBlocker {
	summary := "没有可达的手机连接方式"
	var reasons []string
	if row, ok := checksByID["network_tailscale"]; ok && checkEnabled(row) && row.Code == "tailscale_not_connected" {
		reasons = append(reasons, "Tailscale 尚未连接")
	}
	if row, ok := checksByID["network_lan"]; ok && checkEnabled(row) {
		switch row.Code {
		case "lan_unavailable":
			reasons = append(reasons, "未检测到可用局域网")
		case "lan_public_network_blocked":
			reasons = append(reasons, "当前 Windows 网络不是专用网络")
		case "lan_firewall_blocked":
			reasons = append(reasons, "Windows 防火墙未放行局域网")
		}
	}
	if row, ok := checksByID["network_tailcat"]; ok && checkEnabled(row) && row.Code == "tailcat_relay_unreachable" {
		reasons = append(reasons, "Tailcat 暂无法连接中继")
	}
	if len(reasons) > 0 {
		summary = fmt.Sprintf("%s（%s）", summary, strings.Join(reasons, "；"))
	}

	tailscaleCmd := cmds.cmd("network", "--tailscale-enabled=true")
	lanCmd := cmds.cmd("network", "--lan-enabled=true")
	tailcatEnableCmd := cmds.cmd("tailcat enable")
	tailcatPairCmd := cmds.cmd("tailcat pair")

	if cmds.platform == "windows" {
		tailscaleStep := fmt.Sprintf("%s && %s", tailscaleCmd, cmds.restartNoPair())
		if !cmds.managedService {
			tailscaleStep = fmt.Sprintf("%s，然后重启匹配该配置的前台进程（%s）", tailscaleCmd, cmds.serve())
		}
		return pairingBlocker{
			Summary: summary,
			Fix:     fmt.Sprintf("Tailscale：%s；局域网：重新运行安装器并勾选局域网访问；联网时也可用 Tailcat：%s 后运行 %s", tailscaleStep, tailcatEnableCmd, tailcatPairCmd),
		}
	}
	if !cmds.managedService {
		return pairingBlocker{
			Summary: summary,
			Fix:     fmt.Sprintf("同一局域网：%s；Tailscale：%s（修改后重启匹配该配置的前台进程：%s）；联网时也可用 Tailcat：%s 后运行 %s", lanCmd, tailscaleCmd, cmds.serve(), tailcatEnableCmd, tailcatPairCmd),
		}
	}
	return pairingBlocker{
		Summary: summary,
		Fix:     fmt.Sprintf("同一局域网：%s && %s；Tailscale：%s && %s；联网时也可用 Tailcat：%s 后运行 %s", lanCmd, cmds.restartNoPair(), tailscaleCmd, cmds.restartNoPair(), tailcatEnableCmd, tailcatPairCmd),
	}
}

func pairingDetailSummary(prefix, detail string) string {
	trimmed := strings.TrimSuffix(strings.TrimSpace(detail), "。")
	if trimmed == "" {
		return prefix
	}
	return fmt.Sprintf("%s（%s）", prefix, trimmed)
}

func checkAvailable(row agentsetup.PreflightCheck) bool {
	return row.Available != nil && *row.Available != nil && **row.Available
}

func checkEnabled(row agentsetup.PreflightCheck) bool {
	return row.Enabled != nil && *row.Enabled
}

func printPairingReadiness(w io.Writer, r pairingReadiness) {
	if r.Ready {
		cmd := r.PairCommand
		if cmd == "" {
			cmd = "agentd pair --qr-only"
		}
		fmt.Fprintf(w, "配对：可用，运行 %s\n", cmd)
		return
	}
	fmt.Fprintln(w, "配对：暂不可用")
	for _, blocker := range r.Blockers {
		fmt.Fprintf(w, "  - %s\n", blocker.Summary)
		if strings.TrimSpace(blocker.Fix) != "" {
			fmt.Fprintf(w, "    修复：%s\n", blocker.Fix)
		}
	}
}

func printManagedServicePairingFailure(stderr io.Writer, configPath, legacyPath, platform, safePairError string, waitedReady bool) {
	if waitedReady {
		fmt.Fprintf(stderr, "警告：服务已启动，但暂时无法生成配对信息：%s\n", safePairError)
	} else {
		fmt.Fprintf(stderr, "警告：已提交启动请求，尚未确认就绪，暂时无法生成配对信息：%s\n", safePairError)
	}
	readiness := inspectPairingReadiness(context.Background(), configPath, legacyPath, platform)
	if !readiness.Ready {
		printPairingReadiness(stderr, readiness)
		return
	}
	cmds := newPairingCommandContext(configPath, platform)
	cmd := readiness.PairCommand
	if cmd == "" {
		cmd = cmds.cmd("pair", "--qr-only")
	}
	fmt.Fprintf(stderr, "下一步：稍后运行 %s，或运行 %s 检查配对前提\n", cmd, cmds.cmd("status", "--pairing"))
}
