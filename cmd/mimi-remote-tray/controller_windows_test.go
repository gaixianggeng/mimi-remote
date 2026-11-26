//go:build windows

package main

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestMenuPairCommandIDIsStable(t *testing.T) {
	if menuStatus != 100 {
		t.Fatalf("menu status command ID = %d, want 100", menuStatus)
	}
	if menuPair != 105 {
		t.Fatalf("menu pair command ID = %d, want 105", menuPair)
	}
	if menuExitAndStop != 108 {
		t.Fatalf("menu exit-and-stop command ID = %d, want 108", menuExitAndStop)
	}
	if menuDoctorFix != 109 {
		t.Fatalf("menu doctor-fix command ID = %d, want 109", menuDoctorFix)
	}
	if menuControlPanel != 110 {
		t.Fatalf("menu control-panel command ID = %d, want 110", menuControlPanel)
	}
	if menuFirstSetup != 115 {
		t.Fatalf("menu first-setup command ID = %d, want 115", menuFirstSetup)
	}
}

func TestDoctorArgumentsOnlyRequestFixWhenSelected(t *testing.T) {
	plain := doctorArguments(false)
	if len(plain) != 1 || plain[0] != "doctor" {
		t.Fatalf("plain doctor arguments = %#v", plain)
	}
	fix := doctorArguments(true)
	if len(fix) != 2 || fix[0] != "doctor" || fix[1] != "--fix" {
		t.Fatalf("doctor fix arguments = %#v", fix)
	}
}

func TestActionArgumentsWaitForInteractiveServiceReadiness(t *testing.T) {
	for _, action := range []string{"start", "restart"} {
		arguments := actionArguments(action)
		want := []string{action, "--wait", "1m0s", "--no-pair"}
		if len(arguments) != len(want) {
			t.Fatalf("%s arguments = %#v", action, arguments)
		}
		for index := range want {
			if arguments[index] != want[index] {
				t.Fatalf("%s arguments = %#v, want %#v", action, arguments, want)
			}
		}
	}
	stop := actionArguments("stop")
	if len(stop) != 1 || stop[0] != "stop" {
		t.Fatalf("stop arguments = %#v", stop)
	}
}

func TestStatusArgumentsOnlyForceRuntimeForManualRefresh(t *testing.T) {
	background := statusArguments(false, false)
	if strings.Contains(strings.Join(background, " "), "--runtime-refresh") {
		t.Fatalf("background status arguments = %#v", background)
	}
	manual := statusArguments(true, true)
	joined := strings.Join(manual, " ")
	for _, expected := range []string{"--runtime", "--runtime-refresh", "--network-policy"} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("manual status arguments missing %s: %#v", expected, manual)
		}
	}
}

func TestManualStatusGetsFullExecutionBudgetAfterQueueWait(t *testing.T) {
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	secondBudget := make(chan time.Duration, 1)
	controller := &agentController{statusGate: make(chan struct{}, 1)}
	call := 0
	controller.statusRunner = func(ctx context.Context, _ ...string) ([]byte, error) {
		call++
		if call == 1 {
			close(firstStarted)
			<-releaseFirst
		} else if deadline, ok := ctx.Deadline(); ok {
			secondBudget <- time.Until(deadline)
		}
		return []byte(`{"version":"1.2.3"}`), nil
	}

	firstDone := make(chan error, 1)
	go func() {
		_, err := controller.status(context.Background(), false)
		firstDone <- err
	}()
	<-firstStarted
	secondDone := make(chan error, 1)
	go func() {
		_, err := controller.status(context.Background(), true)
		secondDone <- err
	}()
	time.Sleep(50 * time.Millisecond)
	close(releaseFirst)
	if err := <-firstDone; err != nil {
		t.Fatal(err)
	}
	if err := <-secondDone; err != nil {
		t.Fatal(err)
	}
	if budget := <-secondBudget; budget < manualStatusCommandTimeout-time.Second {
		t.Fatalf("manual execution budget was consumed while queued: %s", budget)
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

func TestPairingArgumentsRequestSafeJSONWithoutTerminalOutput(t *testing.T) {
	arguments := pairingArguments()
	want := []string{"pair", "--qr-only", "--json"}
	if len(arguments) != len(want) {
		t.Fatalf("pairing arguments = %#v", arguments)
	}
	for index := range want {
		if arguments[index] != want[index] {
			t.Fatalf("pairing arguments = %#v, want %#v", arguments, want)
		}
	}
}

func TestParsePairingInfoRequiresValidTicketReceipt(t *testing.T) {
	payload := []byte(`{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=short","pair_expires_at":"2026-08-09T18:00:00+08:00"}`)
	result, err := parsePairingInfo(payload)
	if err != nil {
		t.Fatalf("parse pairing info: %v", err)
	}
	if result.Endpoint != "http://127.0.0.1:8787" || !strings.Contains(result.PairURL, "pair_sig=short") {
		t.Fatalf("pairing info = %#v", result)
	}
	for _, invalid := range []string{
		`{"endpoint":"http://127.0.0.1:8787"}`,
		`{"pair_url":"mimiremote://pair?pair_sig=short"}`,
		`{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=short"}`,
		`{"endpoint":"http://127.0.0.1:8787","pair_url":"https://evil.example/pair","pair_expires_at":"2030-01-01T00:05:00Z"}`,
		`{"ok":false,"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=short","pair_expires_at":"2030-01-01T00:05:00Z"}`,
		`{"ok":true,"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=short","pair_expires_at":"not-a-date","network":"tailscale"}`,
	} {
		if _, err := parsePairingInfo([]byte(invalid)); err == nil {
			t.Fatalf("invalid pairing receipt should fail closed: %s", invalid)
		}
	}
	privateTransport := `{"ok":true,"endpoint":"http://127.0.0.1","pair_url":"mimiremote://pair?pair_sig=short","pair_expires_at":"2030-01-01T00:05:00Z","network":"private-value"}`
	if _, err := parsePairingInfo([]byte(privateTransport)); err == nil || strings.Contains(err.Error(), "private-value") {
		t.Fatal("invalid pairing transport leaked into tray diagnostics")
	}
	if actionCommandBudget < 120*time.Second {
		t.Fatalf("Windows actionCommandBudget = %s, want >= 120s", actionCommandBudget)
	}
}

func TestPairingOnNetworkPreservesExplicitSelection(t *testing.T) {
	for _, network := range []string{"tailscale", "lan"} {
		var received []string
		controller := &agentController{commandRunner: func(_ context.Context, args ...string) ([]byte, error) {
			received = args
			return []byte(`{"ok":true,"endpoint":"http://192.0.2.1:8787","pair_url":"mimiremote://pair?endpoint=http%3A%2F%2F192.0.2.1%3A8787","pair_expires_at":"2030-01-01T00:05:00Z","network":"` + network + `"}`), nil
		}}
		if _, err := controller.pairingOnNetwork(context.Background(), network); err != nil {
			t.Fatal(err)
		}
		expected := []string{"pair", "--qr-only", "--json", "--network", network}
		if !reflect.DeepEqual(received, expected) {
			t.Fatalf("network %s: %v", network, received)
		}
	}
	controller := &agentController{}
	if _, err := controller.pairingOnNetwork(context.Background(), "unknown"); err == nil {
		t.Fatal("accepted unknown network")
	}
}

func TestManagedLogPathFollowsAgentdLayout(t *testing.T) {
	localAppData := t.TempDir()
	t.Setenv("LOCALAPPDATA", localAppData)

	path, err := managedLogPath()
	if err != nil {
		t.Fatalf("managedLogPath returned %v", err)
	}
	want := filepath.Join(localAppData, "Mimi Remote", "logs", "agentd.log")
	if path != want {
		t.Fatalf("managedLogPath = %q, want %q", path, want)
	}
}
