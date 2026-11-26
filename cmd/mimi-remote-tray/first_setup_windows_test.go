//go:build windows

package main

import (
	"context"
	"strings"
	"testing"
)

func TestFirstSetupOnlyShowsManualModifyInstructionsPendingBE6(t *testing.T) {
	// Without BE-6's authenticated maintenance-image identity, even a pending
	// workspace click must work without an agent controller or an installer.
	confirmed := false
	app := &trayApplication{status: agentStatus{WorkspaceConfirmed: &confirmed}}
	calls := 0
	show := func(_ uintptr, title, body string, flags uint32) int {
		calls++
		if title != "完成首次设置" || flags != mbOK|mbIconInfo ||
			!strings.Contains(body, "安装程序") || !strings.Contains(body, "选择“修改”") || !strings.Contains(body, "刷新状态") {
			t.Fatal("missing manual installer guidance")
		}
		return 0
	}
	app.showFirstSetupInstructions(show)
	if calls != 1 || !app.firstSetupRequired() {
		t.Fatal("viewing instructions should leave setup pending")
	}
	confirmed = true
	app.showFirstSetupInstructions(show)
	if calls != 1 {
		t.Fatal("stale menu click showed instructions for an already confirmed workspace")
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
