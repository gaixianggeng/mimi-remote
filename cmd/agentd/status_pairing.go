package main

import (
	"context"
	"fmt"
	"io"
	"strings"

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

// inspectPairingReadiness 复用 internal/setup 的本机配对预检，不新增平行检测，也不发起外部联网。
func inspectPairingReadiness(ctx context.Context, configPath, legacyPath, platform string) pairingReadiness {
	report := runHostPreflight(ctx, agentsetup.PreflightOptions{
		Stage:      "pair",
		ConfigPath: configPath,
		LegacyPath: legacyPath,
		Version:    version,
		HostDial:   coreDialForConfig(configPath),
	}, nil)
	return summarizePairingReadiness(report, platform)
}

func summarizePairingReadiness(report agentsetup.PreflightReport, platform string) pairingReadiness {
	checksByID := make(map[string]agentsetup.PreflightCheck, len(report.Checks))
	for _, check := range report.Checks {
		checksByID[check.ID] = check
	}
	if report.OK {
		return pairingReadiness{
			Ready:       true,
			PairCommand: readyPairCommand(checksByID),
		}
	}
	blockers := make([]pairingBlocker, 0, 5)
	for _, check := range report.Checks {
		if !check.Blocking {
			continue
		}
		blockers = append(blockers, describePairingBlocker(check, checksByID, platform))
	}
	if len(blockers) == 0 {
		blockers = append(blockers, pairingBlocker{
			Summary: "配对条件尚未满足",
			Fix:     "运行 agentd doctor 和 agentd status 检查详细状态",
		})
	}
	return pairingReadiness{
		Ready:    false,
		Blockers: blockers,
	}
}

func readyPairCommand(checksByID map[string]agentsetup.PreflightCheck) string {
	// Tailscale 或局域网任一直连通道已就绪时使用 agentd pair --qr-only；
	// 仅 Tailcat 已就绪时给出实际可用的 agentd tailcat pair --qr-only，避免推荐会报错的命令。
	if checksByID["network_tailscale"].State == "ok" || checksByID["network_lan"].State == "ok" {
		return "agentd pair --qr-only"
	}
	if checksByID["network_tailcat"].State == "ok" {
		return "agentd tailcat pair --qr-only"
	}
	return "agentd pair --qr-only"
}

func describePairingBlocker(check agentsetup.PreflightCheck, checksByID map[string]agentsetup.PreflightCheck, platform string) pairingBlocker {
	switch check.ID {
	case "config_store":
		return describeConfigStoreBlocker(check)
	case "workspace_root":
		return pairingBlocker{
			Summary: pairingDetailSummary("代码目录未就绪", check.Detail),
			Fix:     "运行 agentd workspace --root <代码目录路径> 后执行 agentd restart --no-pair",
		}
	case "service_daemon":
		return describeServiceDaemonBlocker(check, platform)
	case "assistant_any":
		return describeAssistantBlocker(checksByID)
	case "network_any":
		return describeNetworkBlocker(checksByID, platform)
	default:
		return pairingBlocker{
			Summary: pairingDetailSummary(check.Title, check.Detail),
			Fix:     "运行 agentd doctor 检查详细状态",
		}
	}
}

func describeConfigStoreBlocker(check agentsetup.PreflightCheck) pairingBlocker {
	fix := "运行 agentd check-config --json 和 agentd doctor"
	switch check.Code {
	case "config_missing":
		fix = "运行 agentd setup --no-pair"
	case "config_permissions_unsafe":
		fix = "运行 agentd doctor --fix"
	case "config_requires_newer_version":
		fix = "升级到最新版本的 Mimi Remote 后重试"
	}
	return pairingBlocker{
		Summary: pairingDetailSummary("配置文件未就绪", check.Detail),
		Fix:     fix,
	}
}

func describeServiceDaemonBlocker(check agentsetup.PreflightCheck, platform string) pairingBlocker {
	fix := "运行 agentd logs -n 200 和 agentd doctor"
	switch check.Code {
	case "service_not_running":
		fix = "运行 agentd start --no-pair"
	case "service_version_mismatch", "pair_token_mismatch":
		fix = "运行 agentd restart --no-pair"
	case "service_not_registered":
		if platform == "linux" {
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

func describeAssistantBlocker(checksByID map[string]agentsetup.PreflightCheck) pairingBlocker {
	type assistantMeta struct {
		id         string
		label      string
		enableCmd  string
		loginHint  string
		cliEnabled bool
	}
	members := []assistantMeta{
		{id: "assistant_codex", label: "Codex", enableCmd: "agentd runtime --codex=enabled", loginHint: "codex login", cliEnabled: true},
		{id: "assistant_claude", label: "Claude Code", enableCmd: "agentd runtime --claude=enabled", loginHint: "claude login", cliEnabled: true},
		{id: "assistant_agy", label: "Antigravity", enableCmd: "agentd runtime --agy=enabled", loginHint: "登录 agy CLI", cliEnabled: true},
		{id: "assistant_deepseek", label: "DeepSeek", enableCmd: "agentd runtime --deepseek=connect", cliEnabled: false},
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

	if len(availableEnable) > 0 {
		return pairingBlocker{
			Summary: "没有可用助手（已检测到可用助手但尚未启用）",
			Fix:     fmt.Sprintf("运行 %s，然后执行 agentd restart --no-pair", strings.Join(availableEnable, " 或 ")),
		}
	}
	if codexUpstreamUnavailable {
		return pairingBlocker{
			Summary: "没有可用助手（Codex 服务暂不可用）",
			Fix:     "运行 agentd doctor 和 agentd logs -n 200 检查 Codex 服务状态",
		}
	}
	if len(signedOut) > 0 {
		first := signedOut[0]
		return pairingBlocker{
			Summary: fmt.Sprintf("没有可用助手（已检测到 %s，但尚未登录）", first.label),
			Fix:     fmt.Sprintf("先完成 %s 登录（%s），再运行 %s && agentd restart --no-pair", first.label, first.loginHint, first.enableCmd),
		}
	}
	return pairingBlocker{
		Summary: "没有可用助手（至少需要一个已安装并登录的助手，例如 Codex 或 Claude Code）",
		Fix:     "安装并登录 Codex（codex login）或 Claude Code 后，运行 agentd runtime --codex=enabled && agentd restart --no-pair",
	}
}

func describeNetworkBlocker(checksByID map[string]agentsetup.PreflightCheck, platform string) pairingBlocker {
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

	if platform == "windows" {
		return pairingBlocker{
			Summary: summary,
			Fix:     "Tailscale：agentd network --tailscale-enabled=true && agentd restart --no-pair；局域网：重新运行安装器并勾选局域网访问；联网时也可用 Tailcat：agentd tailcat enable 后运行 agentd tailcat pair",
		}
	}
	return pairingBlocker{
		Summary: summary,
		Fix:     "同一局域网：agentd network --lan-enabled=true && agentd restart --no-pair；Tailscale：agentd network --tailscale-enabled=true && agentd restart --no-pair；联网时也可用 Tailcat：agentd tailcat enable 后运行 agentd tailcat pair",
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

func printManagedServicePairingFailure(stderr io.Writer, configPath, legacyPath, platform, safePairError string) {
	fmt.Fprintf(stderr, "警告：服务已启动，但暂时无法生成配对信息：%s\n", safePairError)
	readiness := inspectPairingReadiness(context.Background(), configPath, legacyPath, platform)
	if !readiness.Ready {
		printPairingReadiness(stderr, readiness)
		return
	}
	cmd := readiness.PairCommand
	if cmd == "" {
		cmd = "agentd pair --qr-only"
	}
	fmt.Fprintf(stderr, "下一步：稍后运行 %s，或运行 agentd status --pairing 检查配对前提\n", cmd)
}
