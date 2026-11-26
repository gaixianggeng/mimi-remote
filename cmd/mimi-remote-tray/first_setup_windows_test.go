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
