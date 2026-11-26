//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseAndValidateInnoModifyTargetSecurityBoundaries(t *testing.T) {
	installDir := t.TempDir()
	modifyExe := filepath.Join(installDir, "unins000.exe")
	if err := os.WriteFile(modifyExe, []byte("stub"), 0o600); err != nil {
		t.Fatal(err)
	}
	outsideDir := t.TempDir()
	outsideExe := filepath.Join(outsideDir, "unins000.exe")
	if err := os.WriteFile(outsideExe, []byte("stub"), 0o600); err != nil {
		t.Fatal(err)
	}
	scriptFile := filepath.Join(installDir, "modify.ps1")
	if err := os.WriteFile(scriptFile, []byte("Write-Host hi"), 0o600); err != nil {
		t.Fatal(err)
	}

	target, err := parseAndValidateInnoModifyTarget(`"`+modifyExe+`" /MODIFY`, installDir)
	if err != nil {
		t.Fatalf("valid quoted ModifyPath rejected: %v", err)
	}
	if target.Executable != modifyExe || !reflect.DeepEqual(target.Args, []string{"/MODIFY"}) {
		t.Fatalf("unexpected target: %+v", target)
	}

	targetDefault, err := parseAndValidateInnoModifyTarget(`"`+modifyExe+`"`, installDir)
	if err != nil || !reflect.DeepEqual(targetDefault.Args, []string{"/MODIFY"}) {
		t.Fatalf("default modify args = %+v, %v", targetDefault, err)
	}

	for _, bad := range []string{
		"",
		`"` + outsideExe + `" /MODIFY`,
		`"` + scriptFile + `" /MODIFY`,
		`"` + modifyExe + `" /VERYSILENT`,
		`"` + modifyExe + `" /MODIFY && calc.exe`,
		`"` + filepath.Join(installDir, "missing.exe") + `" /MODIFY`,
	} {
		if _, err := parseAndValidateInnoModifyTarget(bad, installDir); err == nil {
			t.Fatalf("unsafe ModifyPath accepted: %q", bad)
		} else if !isFirstSetupRecoverableViaDesktop(err) {
			t.Fatalf("rejected ModifyPath %q should offer DESKTOP recovery: %v", bad, err)
		}
	}
}

func TestFirstSetupLaunchesVerifiedInnoModifyOnlyWhenNeededAndRereadsStatus(t *testing.T) {
	installDir := t.TempDir()
	trayExe := filepath.Join(installDir, "mimi-remote-tray.exe")
	modifyExe := filepath.Join(installDir, "mimi-remote-setup.exe")

	pendingReport := windowsPendingSetupFixture(t)
	confirmedVal := false
	readbackFails := false
	var events []string
	controller := &agentController{
		trayPath:   trayExe,
		statusGate: make(chan struct{}, 1),
		statusRunner: func(_ context.Context, _ ...string) ([]byte, error) {
			events = append(events, "status")
			if readbackFails && confirmedVal {
				return nil, errors.New("status unavailable")
			}
			if confirmedVal {
				return []byte(`{"version":"1.2.3","process_ok":true,"service_ok":true,"doctor_ok":true,"workspace_confirmed":true}`), nil
			}
			return []byte(`{"version":"1.2.3","process_ok":true,"service_ok":true,"doctor_ok":true,"workspace_confirmed":false}`), nil
		},
		commandRunner: func(_ context.Context, args ...string) ([]byte, error) {
			if len(args) > 0 && args[0] == "preflight" && !(confirmedVal && readbackFails) {
				events = append(events, "preflight")
				return pendingReport, nil
			}
			if len(args) > 0 && args[0] == "tailcat" {
				return []byte(`{"enabled":false,"running":false}`), nil
			}
			return nil, errors.New("unexpected command")
		},
		modifyResolver: func() (innoModifyTarget, error) {
			events = append(events, "resolve")
			return innoModifyTarget{Executable: modifyExe, Args: []string{"/MODIFY"}}, nil
		},
		modifyVerifier: func(candidate, current string) error {
			events = append(events, "verify")
			if candidate != modifyExe || current != trayExe {
				t.Fatalf("unexpected verify paths: %q vs %q", candidate, current)
			}
			return nil
		},
		modifyRunner: func(_ context.Context, exe string, args []string) error {
			events = append(events, "run:"+strings.Join(args, " "))
			if exe != modifyExe {
				t.Fatalf("unexpected modify exe: %q", exe)
			}
			confirmedVal = true
			return nil
		},
	}

	app := &trayApplication{controller: controller}
	app.refreshStatus()
	if !app.firstSetupRequired() {
		t.Fatal("pending workspace_confirmed=false must require first setup")
	}
	if err := app.executeFirstSetup(); err != nil {
		t.Fatalf("executeFirstSetup failed: %v", err)
	}
	if app.firstSetupRequired() {
		t.Fatal("first setup remained required after Modify confirmed workspace")
	}
	wantOrder := []string{"status", "preflight", "status", "preflight", "resolve", "verify", "run:/MODIFY", "status"}
	if !reflect.DeepEqual(events, wantOrder) {
		t.Fatalf("event order = %v, want %v", events, wantOrder)
	}

	// Once confirmed, executeFirstSetup MUST NEVER run again.
	events = nil
	if err := app.executeFirstSetup(); err != nil {
		t.Fatalf("confirmed executeFirstSetup returned error: %v", err)
	}
	if len(events) != 0 {
		t.Fatalf("confirmed workspace invoked first setup: %v", events)
	}

	// A different settings surface can confirm after the menu was rendered.
	confirmedVal = false
	app.refreshStatus()
	confirmedVal = true
	events = nil
	if err := app.executeFirstSetup(); err != nil || !reflect.DeepEqual(events, []string{"status"}) {
		t.Fatalf("stale pending click: events=%v err=%v", events, err)
	}

	confirmedVal = false
	app.refreshStatus()
	readbackFails = true
	if err := app.executeFirstSetup(); err == nil {
		t.Fatal("failed read-back reported a successful setup")
	}
}

func TestFirstSetupFailsClosedWhenSignatureVerificationFails(t *testing.T) {
	ran := false
	controller := &agentController{
		trayPath: `C:\Apps\Mimi Remote\mimi-remote-tray.exe`,
		modifyResolver: func() (innoModifyTarget, error) {
			return innoModifyTarget{Executable: `C:\Apps\Mimi Remote\unins000.exe`, Args: []string{"/MODIFY"}}, nil
		},
		modifyVerifier: func(_, _ string) error {
			return &firstSetupModifyError{Message: "签名校验失败", RecoverViaLink: true}
		},
		modifyRunner: func(_ context.Context, _ string, _ []string) error {
			ran = true
			return nil
		},
	}
	err := controller.launchFirstSetup(context.Background())
	if err == nil || ran || !isFirstSetupRecoverableViaDesktop(err) {
		t.Fatalf("unsigned modify must fail closed with DESKTOP recovery: err=%v ran=%v", err, ran)
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
