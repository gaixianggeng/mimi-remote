//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
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
		t.Fatal("confirmed workspace with LAN disabled must expose Private LAN maintenance action")
	}
	if got := lanMaintenanceMenuLabel(app.status); got != "开启专用局域网访问…" {
		t.Fatalf("LAN disabled label = %q", got)
	}
	prePresentation := makeControlPanelPresentation(app.status, nil, false, false)
	if prePresentation.FirstSetupVisible || !prePresentation.LanMaintenanceVisible || !prePresentation.LanMaintenanceEnabled {
		t.Fatalf("confirmed workspace panel with LAN disabled should expose LAN maintenance without first setup: %+v", prePresentation)
	}
	busyPresentation := makeControlPanelPresentation(app.status, nil, true, false)
	if busyPresentation.LanMaintenanceEnabled {
		t.Fatalf("busy panel must disable LAN maintenance: %+v", busyPresentation)
	}
	unhealthy := app.status
	unhealthy.NetworkStatus = &networkStatus{Mode: "lan", AllowLAN: true, PolicyChecked: true, PolicyOK: false}
	if !canRunLanMaintenance(unhealthy, nil, false, false, false) {
		t.Fatal("unhealthy Private LAN must expose repair maintenance action")
	}
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
	// Once LAN is enabled and policy is affirmatively healthy, hide the Modify
	// entry so opening the unchecked wizard cannot default to disabling working LAN.
	if canRunLanMaintenance(app.status, nil, false, false, false) {
		t.Fatal("healthy Private LAN must not expose Modify entry that defaults to disabling LAN")
	}
	postPresentation := makeControlPanelPresentation(app.status, nil, false, false)
	if postPresentation.FirstSetupVisible || postPresentation.LanMaintenanceVisible || postPresentation.LanMaintenanceEnabled {
		t.Fatalf("healthy LAN panel must hide LAN maintenance entry: %+v", postPresentation)
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

func TestMaintenanceIdentityRejectionBlocksEveryExecutableActionHandler(t *testing.T) {
	confirmed := true
	runner, _, _, _ := makeValidMaintenanceFixture(t)
	runner.ops.runBroker = func(_ context.Context, _ pinnedBrokerImage, args []string) ([]byte, []byte, int, error) {
		if len(args) > 0 && args[0] == "status" {
			return nil, nil, -1, newMaintenanceError(maintenanceFailureIdentityMismatch)
		}
		// UAC cancellation followed by rejected status readback must still latch identity rejection.
		return nil, []byte("错误：管理员授权已取消"), 1223, errors.New("exit 1223")
	}

	unverifiedCalls := 0
	controller := &agentController{
		statusGate: make(chan struct{}, 1),
		statusRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedCalls++
			return nil, nil
		},
		commandRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedCalls++
			return nil, nil
		},
	}

	dialogs := 0
	opened := []string{}
	app := &trayApplication{
		controller: controller,
		status: agentStatus{
			Version:            "1.2.3",
			ProcessOK:          true,
			ServiceOK:          true,
			WorkspaceConfirmed: &confirmed,
		},
		statusErr:           errors.New("prior status timeout"),
		tailcat:             tailcatTrayStatus{Enabled: true, Running: true},
		hasTailcat:          true,
		maintenanceOverride: &runner,
		showDialogFn: func(_ uintptr, _, _ string, _ uint32) int {
			dialogs++
			return idYes
		},
		openURLFn: func(url string) error {
			opened = append(opened, url)
			return nil
		},
	}
	panel := &controlPanel{app: app, window: 1}
	app.panel = panel

	app.executeLanFirewallMaintenance(app.showDialogFn, app.openURLFn)
	if !app.isMaintenanceIdentityRejected() {
		t.Fatal("UAC cancel followed by readback identity rejection must latch maintenanceIdentityRejected")
	}
	if panel.pairNetworkEnabled() {
		t.Fatal("pairNetworkEnabled must be false after maintenance identity rejection")
	}

	dialogsBefore := dialogs
	app.refreshStatusInteractive()
	app.runAction("启动", "start")
	app.runAction("重新启动", "restart")
	app.runAction("停止", "stop")
	app.runDoctor(false)
	app.runDoctor(true)
	app.requestPairing()
	app.toggleTailcat()
	app.confirmAndSetTailcat(true, 0)
	app.setTailcatForPairing(0)
	app.requestTailcatPairing()
	app.refreshTailcat(true)
	panel.applyRelay("default", "")
	panel.refreshPairing()

	if unverifiedCalls != 0 {
		t.Fatalf("executable action handler launched rejected agentd.exe %d times", unverifiedCalls)
	}
	if app.busy || app.pairingBusy {
		t.Fatalf("blocked action handlers must not enter busy state: busy=%v pairingBusy=%v", app.busy, app.pairingBusy)
	}
	if dialogs <= dialogsBefore {
		t.Fatal("blocked executable handlers should offer official download recovery")
	}
	for _, url := range opened {
		if url != maintenanceOfficialDownloadURL {
			t.Fatalf("unexpected recovery URL: %q", url)
		}
	}
}

func TestMaintenanceModifyRealDiagnosticIdentityRejectionIsTerminalAndLatches(t *testing.T) {
	confirmed := true
	runner, _, _, _ := makeValidMaintenanceFixture(t)
	brokerCalls := 0
	runner.ops.runBroker = func(_ context.Context, _ pinnedBrokerImage, args []string) ([]byte, []byte, int, error) {
		brokerCalls++
		if len(args) > 0 && args[0] == "status" {
			t.Fatalf("status readback must not run after Modify identity rejection: %v", args)
		}
		return nil, []byte("错误：无法验证此版本的维护程序，请从官方下载页重新安装已签名的桌面安装包\n"), 1, errors.New("broker exited non-zero")
	}

	unverifiedCalls := 0
	controller := &agentController{
		agentPath:  `C:\nonexistent\agentd.exe`,
		statusGate: make(chan struct{}, 1),
		statusRunner: func(context.Context, ...string) ([]byte, error) {
			unverifiedCalls++
			return []byte(`{"version":"tampered","workspace_confirmed":true}`), nil
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
	if brokerCalls != 1 {
		t.Fatalf("brokerCalls = %d, want 1 (modify only, no status readback)", brokerCalls)
	}
	if !app.isMaintenanceIdentityRejected() || !controller.rejectionLatch.IsRejected() {
		t.Fatal("real Modify identity rejection must set the single authoritative rejection latch")
	}
	if len(opened) != 1 || opened[0] != maintenanceOfficialDownloadURL {
		t.Fatalf("expected official download recovery URL, got %v", opened)
	}

	// Even if applyMaintenanceOutcome were called with BrokerVerified=true alongside
	// a terminal identity rejection error, the latch must remain set and status ignored.
	app.applyMaintenanceOutcome(
		maintenanceRunOutcome{BrokerVerified: true, Status: agentStatus{Version: "9.9.9"}},
		newMaintenanceError(maintenanceFailureIdentityMismatch),
	)
	if !app.isMaintenanceIdentityRejected() || app.status.Version != "1.2.3" {
		t.Fatalf("terminal identity rejection did not take precedence: rejected=%v version=%q", app.isMaintenanceIdentityRejected(), app.status.Version)
	}

	// Subsequent ordinary status/refresh/readback calls must fail at process launch
	// without invoking agentd.exe or clearing the latch.
	app.refreshStatus()
	if _, err := controller.status(context.Background(), false); err == nil {
		t.Fatal("controller.status succeeded while latched")
	}
	if _, err := controller.runHiddenWithProgress(context.Background(), nil, 0, nil, "status", "--json"); err == nil {
		t.Fatal("controller.runHiddenWithProgress launched while latched")
	} else {
		var maintErr *maintenanceError
		if !errors.As(err, &maintErr) || maintErr.Kind != maintenanceFailureIdentityMismatch {
			t.Fatalf("expected maintenanceError(identity_mismatch) from runHiddenWithProgress, got %v", err)
		}
	}
	if unverifiedCalls != 0 || !app.isMaintenanceIdentityRejected() {
		t.Fatalf("latched rejection leaked calls=%d or cleared latch=%v", unverifiedCalls, app.isMaintenanceIdentityRejected())
	}

	// Fresh verified maintenance run clears the latch.
	app.applyMaintenanceOutcome(
		maintenanceRunOutcome{
			BrokerVerified:     true,
			WorkspaceConfirmed: true,
			Status:             agentStatus{Version: "1.2.4", ProcessOK: true, ServiceOK: true, WorkspaceConfirmed: &confirmed},
		},
		nil,
	)
	if app.isMaintenanceIdentityRejected() || app.status.Version != "1.2.4" {
		t.Fatalf("fresh verified maintenance run did not clear latch or apply status: rejected=%v version=%q", app.isMaintenanceIdentityRejected(), app.status.Version)
	}
}

func TestMaintenanceRejectionEnforcedAtProcessLaunchForQueuedRefreshAndCommands(t *testing.T) {
	t.Run("rejection arrives while timer refresh is queued on controller statusGate", func(t *testing.T) {
		firstEntered := make(chan struct{})
		releaseFirst := make(chan struct{})
		statusCalls := 0
		commandCalls := 0
		controller := &agentController{
			statusGate: make(chan struct{}, 1),
		}
		controller.statusRunner = func(_ context.Context, _ ...string) ([]byte, error) {
			statusCalls++
			if statusCalls == 1 {
				close(firstEntered)
				<-releaseFirst
			}
			return []byte(`{"version":"2.0.0","process_ok":true,"service_ok":true,"workspace_confirmed":true,"network_status":{"mode":"lan","allow_lan":true,"policy_checked":true,"policy_ok":true}}`), nil
		}
		controller.commandRunner = func(_ context.Context, _ ...string) ([]byte, error) {
			commandCalls++
			return nil, nil
		}
		confirmed := true
		app := &trayApplication{
			controller: controller,
			status:     agentStatus{Version: "1.2.3", ProcessOK: true, ServiceOK: true, WorkspaceConfirmed: &confirmed},
		}

		// First refresh holds statusGate.
		firstDone := make(chan struct{})
		go func() {
			defer close(firstDone)
			app.refreshStatus()
		}()
		<-firstEntered

		// Second refresh passes the entry guard BEFORE rejection and blocks on statusGate.
		secondDone := make(chan struct{})
		go func() {
			defer close(secondDone)
			app.refreshStatus()
		}()
		time.Sleep(40 * time.Millisecond)

		// Maintenance identity rejection latches while the second refresh is queued.
		app.applyMaintenanceOutcome(maintenanceRunOutcome{}, newMaintenanceError(maintenanceFailureIdentityMismatch))
		close(releaseFirst)

		<-firstDone
		<-secondDone

		if statusCalls != 1 {
			t.Fatalf("queued refresh launched agentd.exe after rejection latched: statusCalls=%d", statusCalls)
		}
		if commandCalls != 0 {
			t.Fatalf("queued refresh launched follow-up command after rejection latched: commandCalls=%d", commandCalls)
		}
		if app.status.Version != "1.2.3" || controller.cachedNetwork != nil {
			t.Fatalf("late in-flight refresh overwrote state after rejection: version=%q cachedNetwork=%+v", app.status.Version, controller.cachedNetwork)
		}
	})

	t.Run("rejection arrives between status and preflight inside refreshStatusWithRuntimeRefresh", func(t *testing.T) {
		pending := false
		pendingJSON, _ := json.Marshal(agentStatus{Version: "1.2.3", WorkspaceConfirmed: &pending})
		preflightCalls := 0
		var app *trayApplication
		controller := &agentController{
			statusGate: make(chan struct{}, 1),
			statusRunner: func(_ context.Context, _ ...string) ([]byte, error) {
				// Rejection latches while status is finishing, before refresh reaches preflight.
				app.applyMaintenanceOutcome(maintenanceRunOutcome{}, newMaintenanceError(maintenanceFailureDigestMismatch))
				return pendingJSON, nil
			},
			commandRunner: func(_ context.Context, _ ...string) ([]byte, error) {
				preflightCalls++
				return nil, nil
			},
		}
		app = &trayApplication{
			controller: controller,
			status:     agentStatus{Version: "1.0.0"},
		}

		app.refreshStatus()
		if preflightCalls != 0 {
			t.Fatalf("preflight launched after maintenance rejection latched mid-refresh: %d calls", preflightCalls)
		}
		if app.status.Version != "1.0.0" {
			t.Fatalf("mid-refresh status overwrote app status after rejection: %+v", app.status)
		}
	})

	t.Run("rejection arrives between two sequential queued controller commands", func(t *testing.T) {
		commandCalls := 0
		controller := &agentController{
			statusGate: make(chan struct{}, 1),
		}
		controller.commandRunner = func(_ context.Context, args ...string) ([]byte, error) {
			commandCalls++
			if commandCalls == 1 {
				// Latch rejection immediately before the second chained command (tailcat status).
				controller.rejectionLatch.Latch(maintenanceFailureIdentityMismatch)
				return []byte(`{"ok":true}`), nil
			}
			t.Fatalf("second command %v ran after rejection latched", args)
			return nil, nil
		}

		_, err := controller.setTailcat(context.Background(), true)
		if err == nil {
			t.Fatal("setTailcat succeeded across mid-sequence identity rejection")
		}
		var maintErr *maintenanceError
		if !errors.As(err, &maintErr) || maintErr.Kind != maintenanceFailureIdentityMismatch {
			t.Fatalf("expected wrapped identity_mismatch error from second command, got %v", err)
		}
		if commandCalls != 1 {
			t.Fatalf("commandCalls = %d, want 1", commandCalls)
		}
	})
}
