package main

import (
	"errors"
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

func TestStatusRefreshKeepsLastGoodValueAndRejectsLateOlderResult(t *testing.T) {
	app := &trayApplication{status: agentStatus{Version: "1.0.0", ProcessOK: true}}
	older := app.beginStatusRequest()
	newer := app.beginStatusRequest()
	app.completeStatusRequest(newer, agentStatus{Version: "2.0.0", ProcessOK: true}, nil)
	app.completeStatusRequest(older, agentStatus{Version: "0.9.0"}, nil)
	app.completeStatusRequest(app.beginStatusRequest(), agentStatus{}, errors.New("timed out"))
	if app.status.Version != "2.0.0" || !app.status.ProcessOK {
		t.Fatalf("last good status was overwritten: %+v", app.status)
	}
	if app.statusErr == nil {
		t.Fatal("refresh error should remain visible without clearing status")
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
