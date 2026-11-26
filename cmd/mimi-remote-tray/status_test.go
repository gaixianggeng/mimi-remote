package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseAgentStatusAndPresentation(t *testing.T) {
	status, err := parseAgentStatus([]byte(`{
		"version":"1.2.3",
		"server_version":"1.2.3",
		"endpoint":"http://192.168.1.20:8787",
		"projects":2,
		"process_ok":true,
		"service_ok":true,
		"doctor_ok":true,
		"network_status":{
			"mode":"lan",
			"allow_lan":true,
			"policy_checked":true,
			"policy_ok":true,
			"firewall_valid":true,
			"interface_alias":"WLAN",
			"network_category":"Private"
		},
		"runtime_status":{"runtimes":[
			{"id":"codex","title":"Codex","enabled":true,"state":"connected","version":"0.9.0",
			 "plan_type":"pro","rate_limits":{"availability":"available","primary":{"used_percent":25,"window_duration_mins":300,"resets_at":1800000000},"secondary":{"used_percent":80,"window_duration_mins":10080}}},
			{"id":"claude","title":"Claude","enabled":false,"state":"disabled"}
		]}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if status.lifecycleTitle() != "运行正常" {
		t.Fatalf("unexpected lifecycle: %s", status.lifecycleTitle())
	}
	details := status.details()
	for _, expected := range []string{
		"http://192.168.1.20:8787",
		"网络：局域网 · WLAN · 专用 (Private)",
		"防火墙：Private / LocalSubnet",
		"Codex：connected · 0.9.0",
		"套餐：pro",
		"5 小时额度：剩余 75%",
		"每周额度：剩余 20%",
		"Claude：未启用",
	} {
		if !strings.Contains(details, expected) {
			t.Fatalf("details missing %q: %s", expected, details)
		}
	}
}

func TestAgentStatusDisplaysUnavailableRuntimeQuota(t *testing.T) {
	status, err := parseAgentStatus([]byte(`{
		"version":"1.2.3",
		"process_ok":true,
		"service_ok":true,
		"doctor_ok":true,
		"runtime_status":{"runtimes":[
			{"id":"codex","title":"Codex","enabled":true,"state":"connected",
			 "rate_limits":{"availability":"unavailable","unavailable_reason":"等待账户刷新"}}
		]}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status.details(), "额度：等待账户刷新") {
		t.Fatalf("unavailable quota missing from details: %s", status.details())
	}
}

func TestAgentStatusDisplaysUnsafeWindowsFirewallPolicy(t *testing.T) {
	status, err := parseAgentStatus([]byte(`{
		"version":"1.2.3",
		"endpoint":"http://192.168.1.20:8787",
		"process_ok":true,
		"service_ok":true,
		"doctor_ok":true,
		"network_status":{
			"mode":"lan",
			"allow_lan":true,
			"policy_checked":true,
			"policy_ok":false,
			"interface_alias":"WLAN",
			"network_category":"Public",
			"unsafe_rule_count":2
		}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	details := status.details()
	for _, expected := range []string{
		"服务需要处理",
		"网络：局域网 · WLAN · 公用 (Public)",
		"防火墙：需要处理（2 条额外入站放行规则）",
	} {
		if !strings.Contains(details, expected) {
			t.Fatalf("details missing %q: %s", expected, details)
		}
	}
}

func TestParseAgentStatusRejectsMissingVersion(t *testing.T) {
	if _, err := parseAgentStatus([]byte(`{"service_ok":false}`)); err == nil {
		t.Fatal("missing version must fail")
	}
}

func TestAgentStatusStoppedDetailsUsesSanitizedError(t *testing.T) {
	status := agentStatus{
		Version:      "dev",
		Endpoint:     "http://127.0.0.1:8787",
		ServiceError: "connection refused",
	}
	if status.lifecycleTitle() != "服务已停止" ||
		!strings.Contains(status.details(), "connection refused") {
		t.Fatalf("unexpected stopped presentation: %s", status.details())
	}
}

func TestParseAgentStatusWorkspaceConfirmedAndAbsenceHandling(t *testing.T) {
	pending, err := parseAgentStatus([]byte(`{
		"version":"1.2.3",
		"process_ok":true,
		"service_ok":true,
		"doctor_ok":true,
		"workspace_confirmed":false
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if !pending.workspacePendingConfirmation() || pending.workspaceConfirmedKnownTrue() {
		t.Fatalf("pending status misclassified: %+v", pending)
	}
	if !needsFirstSetup(pending, nil, false) {
		t.Fatal("workspace_confirmed=false must require first setup")
	}
	if !strings.Contains(pending.details(), "待确认") {
		t.Fatalf("pending details missing confirmation hint: %s", pending.details())
	}

	confirmed, err := parseAgentStatus([]byte(`{
		"version":"1.2.3",
		"process_ok":true,
		"service_ok":true,
		"doctor_ok":true,
		"workspace_confirmed":true
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if confirmed.workspacePendingConfirmation() || !confirmed.workspaceConfirmedKnownTrue() {
		t.Fatalf("confirmed status misclassified: %+v", confirmed)
	}
	if needsFirstSetup(confirmed, errors.New("transient"), true) {
		t.Fatal("confirmed workspace must NEVER trigger first setup")
	}

	fixtureBytes, err := os.ReadFile(filepath.Join("..", "..", "contracts", "host-cli", "status-ready.json"))
	if err != nil {
		t.Fatal(err)
	}
	legacy, err := parseAgentStatus(fixtureBytes)
	if err != nil {
		t.Fatal(err)
	}
	if legacy.WorkspaceConfirmed != nil {
		t.Fatalf("expected omitted workspace_confirmed in status-ready.json, got %v", *legacy.WorkspaceConfirmed)
	}
	if needsFirstSetup(legacy, nil, true) {
		t.Fatal("omitted workspace_confirmed on valid legacy status must be handled safely without forcing first setup")
	}

	configMissingErr := &onboardingCLIError{
		Diagnostic: onboardingResolvedDiagnostic{
			Code:    "config_missing",
			Step:    "config_store",
			Message: "尚未保存首次设置。",
			Trusted: true,
		},
	}
	if !needsFirstSetup(agentStatus{}, configMissingErr, false) {
		t.Fatal("unconfigured config_missing error must trigger first setup")
	}
	if !needsFirstSetup(agentStatus{}, errors.New("status failed"), true) {
		t.Fatal("unconfigured preflightPending must trigger first setup")
	}
	if needsFirstSetup(agentStatus{}, errors.New("temporary timeout"), false) {
		t.Fatal("unknown transient status error without unconfigured evidence must not trigger first setup")
	}
}

func TestFormatTrayUserErrorUsesTypedCopyAndScrubsSecrets(t *testing.T) {
	recoveryFix := onboardingFix{Kind: "open_settings", Target: "host_recovery"}
	typed := &onboardingCLIError{
		Diagnostic: onboardingResolvedDiagnostic{
			Code:         "config_invalid",
			Step:         "config_store",
			Message:      "配置文件格式损坏，已保留原文件。",
			AllowedFix:   &recoveryFix,
			ConfigPath:   "~/.config/mimi-remote/config.json",
			RecoveryPath: "~/.config/mimi-remote/config.json.bak",
			Trusted:      true,
		},
	}
	got := formatTrayUserError(typed)
	if !strings.Contains(got, "配置文件格式损坏") || !strings.Contains(got, "config.json.bak") {
		t.Fatalf("typed error lost recovery context: %q", got)
	}

	leaky := errors.New("raw stderr: mimiremote://pair?pair_sig=secret123 Bearer tok_9876543210abcdef /Users/alice/private/config.json")
	scrubbed := formatTrayUserError(leaky)
	for _, secret := range []string{"secret123", "tok_9876543210abcdef", "/Users/alice", "mimiremote://"} {
		if strings.Contains(scrubbed, secret) {
			t.Fatalf("formatTrayUserError leaked %q in %q", secret, scrubbed)
		}
	}
}

func windowsPendingSetupFixture(t *testing.T) []byte {
	t.Helper()
	return applyTrayReportPatch(t, "preflight-windows-public.json", []trayReportPatch{
		{Op: "replace", Path: "/stage", Value: "setup"},
		{Op: "replace", Path: "/ok", Value: true},
		{Op: "replace", Path: "/workspace_confirmed", Value: false},
		{Op: "replace", Path: "/checks/11/blocking", Value: false},
	})
}

func TestSetupPreflightRequiresReadableConfiguration(t *testing.T) {
	report, err := decodeAndValidatePreflightReportForStage(windowsPendingSetupFixture(t), "windows", "setup", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if pending, err := pendingFromSetupReport(report); !pending || err != nil {
		t.Fatalf("readable pending configuration: pending=%t err=%v", pending, err)
	}
	for _, code := range []string{"config_invalid", "config_recovery_required", "config_permissions_unsafe", "probe_timeout"} {
		report.Checks[0].State, report.Checks[0].Code = "error", code
		pending, err := pendingFromSetupReport(report)
		if pending || err == nil || needsFirstSetup(agentStatus{WorkspaceConfirmed: report.WorkspaceConfirmed}, err, pending) {
			t.Fatalf("%s incorrectly enabled first setup", code)
		}
	}
}
