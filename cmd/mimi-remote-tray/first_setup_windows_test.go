//go:build windows

package main

import (
	"context"
	"strings"
	"testing"
)

func TestFirstSetupInvokesTrustedMaintenanceAndUpdatesState(t *testing.T) {
	confirmed := false
	runner, _, launchedArgs, _ := makeValidMaintenanceFixture(t)
	app := &trayApplication{
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
	if len(*launchedArgs) != 1 || strings.Join((*launchedArgs)[0], " ") != "installer-maintenance modify" {
		t.Fatalf("expected trusted installer-maintenance modify launch, got %#v", *launchedArgs)
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
	if len(*launchedArgs) != 1 || dialogs != 0 {
		t.Fatal("stale menu click launched maintenance for an already confirmed workspace")
	}
}

func TestFirstSetupUnsignedBuildFallsBackToOfficialDownload(t *testing.T) {
	confirmed := false
	runner, _, _, _ := makeValidMaintenanceFixture(t)
	runner.publisherSHA256 = ""
	app := &trayApplication{
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
	runner.ops.readStatus = func(context.Context) (agentStatus, error) {
		stillPending := false
		return agentStatus{Version: "1.2.3", ProcessOK: true, ServiceOK: true, WorkspaceConfirmed: &stillPending}, nil
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
