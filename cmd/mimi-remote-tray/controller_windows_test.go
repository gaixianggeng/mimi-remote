//go:build windows

package main

import (
	"strings"
	"testing"
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
		want := []string{action, "--wait", "20s", "--no-pair"}
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

func TestParsePairingInfoRequiresShortLivedPairURL(t *testing.T) {
	payload := []byte(`{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=short","pair_expires_at":"2026-08-09T18:00:00+08:00"}`)
	result, err := parsePairingInfo(payload)
	if err != nil {
		t.Fatalf("parse pairing info: %v", err)
	}
	if result.Endpoint != "http://127.0.0.1:8787" || !strings.Contains(result.PairURL, "pair_sig=short") {
		t.Fatalf("pairing info = %#v", result)
	}
	if _, err := parsePairingInfo([]byte(`{"endpoint":"http://127.0.0.1:8787"}`)); err == nil {
		t.Fatal("missing short-lived pair URL should fail closed")
	}
}
