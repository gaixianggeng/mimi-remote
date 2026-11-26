//go:build windows

package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestFirstSetupInvokesTrustedMaintenanceAndUpdatesState(t *testing.T) {
	confirmed := false
	runner, _, launchedArgs, _ := makeValidMaintenanceFixture(t)
	unverifiedRefreshes := 0
	controller := &agentController{
		statusGate: make(chan struct{}, 1),
		cachedNetwork: &networkStatus{
			Mode:          "loopback",
			AllowLAN:      false,
			PolicyChecked: true,
			PolicyOK:      false,
		},
		networkLastChecked: time.Now(),
		statusRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedRefreshes++
			return nil, nil
		},
		commandRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedRefreshes++
			return nil, nil
		},
	}
	app := &trayApplication{
		controller:          controller,
		status:              agentStatus{Version: "1.2.3", WorkspaceConfirmed: &confirmed},
		maintenanceOverride: &runner,
	}
	dialogs := 0
	openedURLs := []string{}
	app.executeFirstSetupMaintenance(
		func(_ uintptr, _, _ string, _ uint32) int {
			dialogs++
			return 0
		},
		func(url string) error {
			openedURLs = append(openedURLs, url)
			return nil
		},
	)
	if len(*launchedArgs) != 2 ||
		strings.Join((*launchedArgs)[0], " ") != "installer-maintenance modify" ||
		strings.Join((*launchedArgs)[1], " ") != "status --json --runtime --network-policy" {
		t.Fatalf("expected verified modify + pinned status readback, got %#v", *launchedArgs)
	}
	if unverifiedRefreshes != 0 {
		t.Fatalf("maintenance must not trigger unverified controller refresh, got %d calls", unverifiedRefreshes)
	}
	if controller.cachedNetwork == nil || !controller.cachedNetwork.PolicyOK || !controller.cachedNetwork.FirewallValid {
		t.Fatalf("controller network policy cache was not refreshed from verified maintenance status: %+v", controller.cachedNetwork)
	}
	if app.firstSetupRequired() {
		t.Fatal("confirmed post-run status should clear first-setup requirement")
	}
	if dialogs != 0 || len(openedURLs) != 0 {
		t.Fatalf("successful setup should not show error dialogs or open fallback URL: dialogs=%d urls=%v", dialogs, openedURLs)
	}

	// Stale menu click after confirmation must be a no-op.
	app.executeFirstSetupMaintenance(
		func(_ uintptr, _, _ string, _ uint32) int {
			dialogs++
			return 0
		},
		nil,
	)
	if len(*launchedArgs) != 2 || dialogs != 0 {
		t.Fatal("stale menu click launched maintenance for an already confirmed workspace")
	}
}

func TestFirstSetupUnsignedBuildSkipsUnverifiedRefreshAndFallsBackToOfficialDownload(t *testing.T) {
	confirmed := false
	runner, _, _, _ := makeValidMaintenanceFixture(t)
	runner.publisherSHA256 = ""
	unverifiedRefreshes := 0
	controller := &agentController{
		statusGate: make(chan struct{}, 1),
		statusRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedRefreshes++
			return []byte(`{"version":"evil","workspace_confirmed":true}`), nil
		},
		commandRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedRefreshes++
			return nil, nil
		},
	}
	app := &trayApplication{
		controller:          controller,
		status:              agentStatus{Version: "1.2.3", WorkspaceConfirmed: &confirmed},
		maintenanceOverride: &runner,
	}
	var shownTitle, shownBody string
	var shownFlags uint32
	var opened []string
	app.executeFirstSetupMaintenance(
		func(_ uintptr, title, body string, flags uint32) int {
			shownTitle, shownBody, shownFlags = title, body, flags
			return idYes
		},
		func(url string) error {
			opened = append(opened, url)
			return nil
		},
	)
	if unverifiedRefreshes != 0 {
		t.Fatalf("identity rejection must skip all executable refreshes, got %d", unverifiedRefreshes)
	}
	if shownTitle != "完成首次设置" || shownFlags != mbYesNo|mbIconWarning {
		t.Fatalf("unexpected fallback dialog: title=%q flags=%d", shownTitle, shownFlags)
	}
	if !strings.Contains(shownBody, maintenanceOfficialDownloadURL) || strings.Contains(shownBody, "选择“修改”") {
		t.Fatalf("fallback body should direct to official download without legacy manual copy: %q", shownBody)
	}
	if len(opened) != 1 || opened[0] != maintenanceOfficialDownloadURL {
		t.Fatalf("expected hardcoded official download URL to open, got %v", opened)
	}
	if !app.firstSetupRequired() {
		t.Fatal("unsigned fallback must keep first-setup pending")
	}
}

func TestFirstSetupPostRunStillUnconfirmedShowsTypedGuidance(t *testing.T) {
	confirmed := false
	runner, _, _, _ := makeValidMaintenanceFixture(t)
	stillPending := false
	statusRaw, _ := json.Marshal(agentStatus{Version: "1.2.3", ProcessOK: true, ServiceOK: true, WorkspaceConfirmed: &stillPending})
	runner.ops.runBroker = func(_ context.Context, _ pinnedBrokerImage, args []string) ([]byte, []byte, int, error) {
		if len(args) > 0 && args[0] == "status" {
			return statusRaw, nil, 0, nil
		}
		return nil, nil, 0, nil
	}
	app := &trayApplication{
		status:              agentStatus{Version: "1.2.3", WorkspaceConfirmed: &confirmed},
		maintenanceOverride: &runner,
	}
	var body string
	app.executeFirstSetupMaintenance(
		func(_ uintptr, _, text string, _ uint32) int {
			body = text
			return 0
		},
		nil,
	)
	if !strings.Contains(body, "待确认") || !app.firstSetupRequired() {
		t.Fatalf("expected still-unconfirmed guidance and pending state, got body=%q pending=%v", body, app.firstSetupRequired())
	}
}

func TestMissingBrokerRecoveryWorksWithoutAgentd(t *testing.T) {
	app := &trayApplication{
		controller: nil,
		statusErr:  newMaintenanceError(maintenanceFailureImageMissing),
	}
	var shownTitle, shownBody string
	var shownFlags uint32
	var opened []string
	app.promptMissingBrokerRecovery(
		func(_ uintptr, title, body string, flags uint32) int {
			shownTitle, shownBody, shownFlags = title, body, flags
			return idYes
		},
		func(url string) error {
			opened = append(opened, url)
			return nil
		},
	)
	if shownTitle != "Mimi Remote 恢复" || shownFlags != mbYesNo|mbIconWarning {
		t.Fatalf("unexpected missing broker dialog: title=%q flags=%d", shownTitle, shownFlags)
	}
	if !strings.Contains(shownBody, maintenanceOfficialDownloadURL) {
		t.Fatalf("missing broker dialog lacks official download URL: %q", shownBody)
	}
	if len(opened) != 1 || opened[0] != maintenanceOfficialDownloadURL {
		t.Fatalf("expected official download URL to open, got %v", opened)
	}

	// Local direct download recovery action also works with nil controller.
	app.executeOfficialDownloadRecovery(nil, func(url string) error {
		opened = append(opened, url)
		return nil
	})
	if len(opened) != 2 || opened[1] != maintenanceOfficialDownloadURL {
		t.Fatalf("direct local recovery failed: %v", opened)
	}

	// Control panel presentation stays actionable for recovery while disabling broker commands.
	presentation := makeControlPanelPresentation(agentStatus{}, newMaintenanceError(maintenanceFailureImageMissing), false, false)
	if !presentation.FirstSetupVisible || !presentation.FirstSetupEnabled || !presentation.LogsEnabled {
		t.Fatalf("missing broker panel should expose recovery + logs: %+v", presentation)
	}
	if presentation.RefreshEnabled || presentation.StartEnabled || presentation.PairEnabled || presentation.DoctorEnabled {
		t.Fatalf("missing broker panel must disable broker-dependent actions: %+v", presentation)
	}
}

func TestPassiveTrayBootstrapOnlyReadsStatus(t *testing.T) {
	t.Setenv("LocalAppData", t.TempDir())
	reads := 0
	controller := &agentController{
		statusGate: make(chan struct{}, 1),
		statusRunner: func(context.Context, ...string) ([]byte, error) {
			reads++
			if reads == 1 {
				return []byte(`{"version":"fixture","process_ok":false,"service_ok":false,"workspace_confirmed":true}`), nil
			}
			return []byte(`{"version":"fixture","process_ok":true,"service_ok":true,"workspace_confirmed":true}`), nil
		},
		commandRunner: func(_ context.Context, args ...string) ([]byte, error) {
			if strings.Join(args, " ") != "tailcat status --json" {
				t.Fatalf("passive launch ran %v", args)
			}
			return []byte(`{"enabled":false}`), nil
		},
	}
	app := &trayApplication{controller: controller}
	app.bootstrap()
	if reads != 2 || !app.status.ServiceOK {
		t.Fatal("bootstrap did not observe the later ready state")
	}
}

func TestConfirmedWorkspaceLanMaintenanceVerifiesPolicyAndUpdatesCache(t *testing.T) {
	confirmed := true
	runner, _, launchedArgs, _ := makeValidMaintenanceFixture(t)
	unverifiedRefreshes := 0
	controller := &agentController{
		statusGate: make(chan struct{}, 1),
		cachedNetwork: &networkStatus{
			Mode:          "loopback",
			AllowLAN:      false,
			PolicyChecked: true,
			PolicyOK:      false,
		},
		networkLastChecked: time.Now(),
		statusRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedRefreshes++
			return nil, nil
		},
		commandRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedRefreshes++
			return nil, nil
		},
	}
	app := &trayApplication{
		controller: controller,
		status: agentStatus{
			Version:            "1.2.3",
			ProcessOK:          true,
			ServiceOK:          true,
			WorkspaceConfirmed: &confirmed,
			NetworkStatus:      &networkStatus{Mode: "loopback", AllowLAN: false, PolicyChecked: true, PolicyOK: true},
		},
		maintenanceOverride: &runner,
	}
	if !canRunLanMaintenance(app.status, nil, false, false, false) {
		t.Fatal("confirmed workspace must expose Private LAN maintenance action")
	}
	if got := lanMaintenanceMenuLabel(app.status); got != "开启专用局域网访问…" {
		t.Fatalf("LAN disabled label = %q", got)
	}
	unhealthy := app.status
	unhealthy.NetworkStatus = &networkStatus{Mode: "lan", AllowLAN: true, PolicyChecked: true, PolicyOK: false}
	if got := lanMaintenanceMenuLabel(unhealthy); got != "修复专用局域网防火墙…" {
		t.Fatalf("LAN unhealthy label = %q", got)
	}

	dialogs := 0
	app.executeLanFirewallMaintenance(
		func(_ uintptr, _, _ string, _ uint32) int {
			dialogs++
			return 0
		},
		nil,
	)
	if len(*launchedArgs) != 2 ||
		strings.Join((*launchedArgs)[0], " ") != "installer-maintenance modify" ||
		strings.Join((*launchedArgs)[1], " ") != "status --json --runtime --network-policy" {
		t.Fatalf("expected verified modify + LAN status readback, got %#v", *launchedArgs)
	}
	if unverifiedRefreshes != 0 {
		t.Fatalf("LAN maintenance must not run unverified refreshes, got %d", unverifiedRefreshes)
	}
	if dialogs != 0 {
		t.Fatalf("successful LAN maintenance should not show error dialogs, got %d", dialogs)
	}
	if controller.cachedNetwork == nil || !controller.cachedNetwork.AllowLAN || !controller.cachedNetwork.FirewallValid || !controller.cachedNetwork.PolicyOK {
		t.Fatalf("controller network cache not updated from verified LAN readback: %+v", controller.cachedNetwork)
	}
	if got := lanMaintenanceMenuLabel(app.status); got != "管理专用局域网防火墙…" {
		t.Fatalf("LAN healthy label = %q", got)
	}

	// Verify control panel presentation exposes the LAN maintenance action for confirmed workspaces.
	presentation := makeControlPanelPresentation(app.status, nil, false, false)
	if presentation.FirstSetupVisible || !presentation.LanMaintenanceVisible || !presentation.LanMaintenanceEnabled {
		t.Fatalf("confirmed workspace panel should expose LAN maintenance without first setup: %+v", presentation)
	}
	busyPresentation := makeControlPanelPresentation(app.status, nil, true, false)
	if busyPresentation.LanMaintenanceEnabled {
		t.Fatalf("busy panel must disable LAN maintenance: %+v", busyPresentation)
	}
}

func TestConfirmedWorkspaceLanMaintenanceFailsClosedWhenPolicyNotAffirmative(t *testing.T) {
	confirmed := true
	runner, _, _, _ := makeValidMaintenanceFixture(t)
	statusRaw, _ := json.Marshal(agentStatus{
		Version:            "1.2.3",
		ProcessOK:          true,
		ServiceOK:          true,
		WorkspaceConfirmed: &confirmed,
		ModuleStatus:       &moduleStatus{LANEnabled: true, LANAvailable: true},
		NetworkStatus:      &networkStatus{Mode: "lan", AllowLAN: true, PolicyChecked: true, PolicyOK: false, FirewallValid: false},
	})
	runner.ops.runBroker = func(_ context.Context, _ pinnedBrokerImage, args []string) ([]byte, []byte, int, error) {
		if len(args) > 0 && args[0] == "status" {
			return statusRaw, nil, 0, nil
		}
		return nil, nil, 0, nil
	}
	app := &trayApplication{
		status:              agentStatus{Version: "1.2.3", ProcessOK: true, ServiceOK: true, WorkspaceConfirmed: &confirmed},
		maintenanceOverride: &runner,
	}
	var shownTitle, shownBody string
	app.executeLanFirewallMaintenance(
		func(_ uintptr, title, body string, _ uint32) int {
			shownTitle, shownBody = title, body
			return 0
		},
		nil,
	)
	if shownTitle != "专用局域网防火墙" || !strings.Contains(shownBody, "专用网络防火墙策略未生效") {
		t.Fatalf("expected LAN policy failure dialog, got title=%q body=%q", shownTitle, shownBody)
	}
}

func TestMaintenanceIdentityRejectionBlocksSubsequentPeriodicRefresh(t *testing.T) {
	confirmed := true
	runner, _, _, _ := makeValidMaintenanceFixture(t)
	runner.ops.verifyCMSReceipt = func([]byte, []byte) ([]byte, error) {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	unverifiedCalls := 0
	controller := &agentController{
		statusGate: make(chan struct{}, 1),
		statusRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedCalls++
			return []byte(`{"version":"tampered"}`), nil
		},
		commandRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedCalls++
			return nil, nil
		},
	}
	app := &trayApplication{
		controller:          controller,
		status:              agentStatus{Version: "1.2.3", ProcessOK: true, ServiceOK: true, WorkspaceConfirmed: &confirmed},
		maintenanceOverride: &runner,
	}
	var opened []string
	app.executeLanFirewallMaintenance(
		func(_ uintptr, _, _ string, _ uint32) int { return idYes },
		func(url string) error {
			opened = append(opened, url)
			return nil
		},
	)
	if !app.isMaintenanceIdentityRejected() {
		t.Fatal("identity rejection must latch maintenanceIdentityRejected")
	}
	if len(opened) != 1 || opened[0] != maintenanceOfficialDownloadURL {
		t.Fatalf("expected local official download fallback, got %v", opened)
	}
	// Subsequent periodic status refresh must not launch the rejected sibling agentd.exe.
	app.refreshStatus()
	app.refreshStatusWithRuntimeRefresh(true)
	if unverifiedCalls != 0 {
		t.Fatalf("periodic/manual refresh ran unverified sibling after identity rejection: %d calls", unverifiedCalls)
	}
	if canRunLanMaintenance(app.status, nil, false, false, true) {
		t.Fatal("identity-rejected tray must not expose LAN maintenance button")
	}
}
