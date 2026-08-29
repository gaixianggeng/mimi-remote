//go:build windows

package main

import (
	"errors"
	"strings"
	"testing"
)

func TestControlPanelPresentationForReadyService(t *testing.T) {
	status := agentStatus{
		Version:   "1.2.3",
		Endpoint:  "http://127.0.0.1:8787",
		ProcessOK: true,
		ServiceOK: true,
		DoctorOK:  true,
	}
	presentation := makeControlPanelPresentation(status, nil, false, false)
	if presentation.StateTitle != "服务运行正常" || presentation.StateBadge != "运行正常" {
		t.Fatalf("state title = %q", presentation.StateTitle)
	}
	if presentation.StartEnabled || !presentation.RestartEnabled || !presentation.StopEnabled || !presentation.PairEnabled {
		t.Fatalf("unexpected service actions: %#v", presentation)
	}
	if !presentation.RefreshEnabled || !presentation.DoctorEnabled || !presentation.FixEnabled || !presentation.LogsEnabled {
		t.Fatalf("common actions should be enabled: %#v", presentation)
	}
	if presentation.EndpointValue != "127.0.0.1:8787" || presentation.VersionValue != "1.2.3" {
		t.Fatalf("compact details = endpoint %q version %q", presentation.EndpointValue, presentation.VersionValue)
	}
}

func TestControlPanelPresentationSeparatesCodexAndClaudeConnectionStates(t *testing.T) {
	status := agentStatus{
		Version:   "1.2.3",
		ProcessOK: true,
		ServiceOK: true,
		DoctorOK:  true,
		RuntimeStatus: &runtimeStatus{Runtimes: []runtimeEntry{
			{ID: "codex", Enabled: true, State: "connected"},
			{ID: "claude", Enabled: false, State: "disabled"},
		}},
	}
	presentation := makeControlPanelPresentation(status, nil, false, false)
	if presentation.CodexValue != "已连接" {
		t.Fatalf("Codex state = %q, want 已连接", presentation.CodexValue)
	}
	if presentation.ClaudeValue != "未配置" {
		t.Fatalf("Claude Code state = %q, want 未配置", presentation.ClaudeValue)
	}
	if presentation.CodexColor == presentation.ClaudeColor {
		t.Fatal("connected and unconfigured runtimes should use different colors")
	}
}

func TestControlPanelRuntimePresentationSupportsRuntimeStates(t *testing.T) {
	tests := []struct {
		name     string
		snapshot *runtimeStatus
		want     string
	}{
		{name: "available", snapshot: &runtimeStatus{Runtimes: []runtimeEntry{{ID: "codex", Enabled: true, State: "available"}}}, want: "运行时可用"},
		{name: "signed out", snapshot: &runtimeStatus{Runtimes: []runtimeEntry{{ID: "codex", Enabled: true, State: "signed_out"}}}, want: "未登录"},
		{name: "unavailable", snapshot: &runtimeStatus{Runtimes: []runtimeEntry{{ID: "codex", Enabled: true, State: "unavailable"}}}, want: "不可用"},
		{name: "refreshing", snapshot: &runtimeStatus{Refreshing: true, Runtimes: []runtimeEntry{{ID: "codex", Enabled: true, State: "unavailable", Reason: "refresh_in_progress"}}}, want: "正在检查"},
		{name: "stale", snapshot: &runtimeStatus{Stale: true, Runtimes: []runtimeEntry{{ID: "codex", Enabled: true, State: "connected"}}}, want: "状态已过期"},
		{name: "stale refreshing", snapshot: &runtimeStatus{Stale: true, Refreshing: true, Runtimes: []runtimeEntry{{ID: "codex", Enabled: true, State: "connected"}}}, want: "正在刷新"},
		{name: "stale disabled refreshing", snapshot: &runtimeStatus{Stale: true, Refreshing: true, Runtimes: []runtimeEntry{{ID: "codex", Enabled: false, State: "disabled"}}}, want: "正在刷新"},
		{name: "missing runtime", snapshot: &runtimeStatus{}, want: "状态未知"},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			got := makeControlPanelRuntimePresentation(testCase.snapshot, "codex", true)
			if got.Value != testCase.want {
				t.Fatalf("runtime state = %q, want %q", got.Value, testCase.want)
			}
		})
	}
}

func TestControlPanelRuntimeStatusDoesNotDependOnCodexReadiness(t *testing.T) {
	status := agentStatus{
		Version:   "1.2.3",
		ProcessOK: true,
		ServiceOK: false,
		RuntimeStatus: &runtimeStatus{Runtimes: []runtimeEntry{
			{ID: "codex", Enabled: true, State: "unavailable"},
			{ID: "claude", Enabled: true, State: "connected"},
		}},
	}
	presentation := makeControlPanelPresentation(status, nil, false, false)
	if presentation.CodexValue != "不可用" {
		t.Fatalf("Codex state = %q, want 不可用", presentation.CodexValue)
	}
	if presentation.ClaudeValue != "已连接" {
		t.Fatalf("Claude state = %q, want 已连接", presentation.ClaudeValue)
	}
}

func TestControlPanelPresentationForStoppedService(t *testing.T) {
	status := agentStatus{Version: "1.2.3"}
	presentation := makeControlPanelPresentation(status, nil, false, false)
	if presentation.StateTitle != "服务已停止" {
		t.Fatalf("state title = %q", presentation.StateTitle)
	}
	if !presentation.StartEnabled || presentation.RestartEnabled || presentation.StopEnabled || presentation.PairEnabled {
		t.Fatalf("unexpected stopped actions: %#v", presentation)
	}
	if !strings.Contains(presentation.StateSummary, "启动服务") {
		t.Fatalf("stopped summary is not actionable: %s", presentation.StateSummary)
	}
}

func TestControlPanelPresentationExplainsUnsafeNetworkPolicy(t *testing.T) {
	status := agentStatus{
		Version:   "1.2.3",
		ProcessOK: true,
		ServiceOK: true,
		DoctorOK:  true,
		NetworkStatus: &networkStatus{
			PolicyChecked: true,
			PolicyOK:      false,
		},
	}
	presentation := makeControlPanelPresentation(status, nil, false, false)
	if presentation.StateTitle != "服务需要处理" {
		t.Fatalf("state title = %q", presentation.StateTitle)
	}
	if !strings.Contains(presentation.StateSummary, "配置或依赖需要处理") {
		t.Fatalf("warning summary overstates readiness: %s", presentation.StateSummary)
	}
}

func TestControlPanelPresentationDisablesConflictingActionsWhileBusy(t *testing.T) {
	status := agentStatus{
		Version:   "1.2.3",
		ProcessOK: true,
		ServiceOK: true,
		DoctorOK:  true,
	}
	presentation := makeControlPanelPresentation(status, nil, true, false)
	if presentation.RefreshEnabled || presentation.StartEnabled || presentation.RestartEnabled ||
		presentation.StopEnabled || presentation.PairEnabled || presentation.DoctorEnabled ||
		presentation.FixEnabled || presentation.LogsEnabled {
		t.Fatalf("busy panel exposed an action: %#v", presentation)
	}
	if !strings.Contains(presentation.StateSummary, "请稍候") {
		t.Fatalf("busy summary missing progress feedback: %s", presentation.StateSummary)
	}
}

func TestControlPanelPresentationHandlesPairingAndStatusErrors(t *testing.T) {
	status := agentStatus{
		Version:   "1.2.3",
		ProcessOK: true,
		ServiceOK: true,
		DoctorOK:  true,
	}
	if makeControlPanelPresentation(status, nil, false, true).PairEnabled {
		t.Fatal("pairing action should be disabled while a pairing terminal is already open")
	}

	presentation := makeControlPanelPresentation(agentStatus{}, errors.New("first line\r\n second line"), false, false)
	if presentation.StateTitle != "无法读取服务状态" || presentation.StateBadge != "不可用" {
		t.Fatalf("state title = %q", presentation.StateTitle)
	}
	if strings.Contains(presentation.StateSummary, "\r") || strings.Contains(presentation.StateSummary, "\n") {
		t.Fatalf("error summary should remain one line: %q", presentation.StateSummary)
	}
	if !strings.Contains(presentation.StateSummary, "first line second line") {
		t.Fatalf("error summary lost useful context: %q", presentation.StateSummary)
	}
}

func TestControlPanelPresentationKeepsLastGoodStatusAfterRefreshError(t *testing.T) {
	status := agentStatus{Version: "1.2.3", ProcessOK: true, ServiceOK: true, DoctorOK: true}
	presentation := makeControlPanelPresentation(status, errors.New("refresh timed out"), false, false)
	if presentation.StateTitle != "服务运行正常" || presentation.StartEnabled || !presentation.StopEnabled {
		t.Fatalf("refresh error replaced the last good service state: %#v", presentation)
	}
	if !strings.Contains(presentation.StateSummary, "当前显示上次状态") {
		t.Fatalf("refresh warning is missing: %q", presentation.StateSummary)
	}
}

func TestCompactControlPanelNetworkUsesShortWindowsLabels(t *testing.T) {
	status := &networkStatus{
		Mode:            "lan",
		NetworkCategory: "Private",
		PolicyChecked:   true,
		PolicyOK:        false,
	}
	if got := compactControlPanelNetwork(status); got != "局域网 · 专用 · 需处理" {
		t.Fatalf("compact network = %q", got)
	}
}

func TestMakePairingMatrixBuildsDrawableQRCode(t *testing.T) {
	matrix, err := makePairingMatrix("mimiremote://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787&pair_sig=short-ticket")
	if err != nil {
		t.Fatalf("make pairing matrix: %v", err)
	}
	if len(matrix) < 21 || len(matrix) != len(matrix[0]) {
		t.Fatalf("unexpected QR matrix size: %dx%d", len(matrix), len(matrix[0]))
	}
	dark := 0
	for _, row := range matrix {
		for _, value := range row {
			if value {
				dark++
			}
		}
	}
	if dark == 0 {
		t.Fatal("QR matrix contains no dark modules")
	}
}

func TestFormatPairingExpiryExplainsShortLifetime(t *testing.T) {
	formatted := formatPairingExpiry("2026-08-09T18:00:00+08:00")
	if !strings.Contains(formatted, "约 10 分钟") {
		t.Fatalf("pairing expiry = %q", formatted)
	}
}

func TestControlPanelScalesLayoutFor4KDisplayDPI(t *testing.T) {
	panel := controlPanel{dpi: 192}
	if got := panel.scale(600); got != 1200 {
		t.Fatalf("600 logical pixels at 200%% DPI = %d, want 1200", got)
	}
	rect := panel.scaledRect(16, 76, 568, 326)
	if rect.Left != 32 || rect.Top != 152 || rect.Right != 1136 || rect.Bottom != 652 {
		t.Fatalf("scaled card rect = %#v", rect)
	}
	panel.dpi = 144
	if got := panel.scale(34); got != 51 {
		t.Fatalf("34 logical pixels at 150%% DPI = %d, want 51", got)
	}
	if width, height := scaleControlPanelValue(controlPanelLogicalWidth, 144), scaleControlPanelValue(controlPanelLogicalHeight, 144); width != 900 || height != 825 {
		t.Fatalf("control panel bounds at 150%% DPI = %dx%d, want 900x825", width, height)
	}
	if width, height := scaleControlPanelValue(controlPanelLogicalWidth, 192), scaleControlPanelValue(controlPanelLogicalHeight, 192); width != 1200 || height != 1100 {
		t.Fatalf("control panel bounds at 200%% DPI = %dx%d, want 1200x1100", width, height)
	}
}
