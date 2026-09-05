//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func linuxTerminalFixture(t *testing.T) (*linuxTerminalScreen, *[]string) {
	t.Helper()
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	state := readyLinuxSnapshot()
	state.HasTailcat = true
	state.Status.NetworkStatus = &networkStatus{Mode: "tailscale", AllowLAN: true}
	calls := []string{}
	controller := &linuxController{runner: func(_ context.Context, args ...string) ([]byte, error) {
		call := strings.Join(args, " ")
		calls = append(calls, call)
		switch call {
		case "status --json --runtime":
			return json.Marshal(state.Status)
		case "tailcat status --json":
			return json.Marshal(state.Tailcat)
		case "tailcat enable --json":
			state.Tailcat.Enabled, state.Tailcat.Running = true, true
			return []byte(`{"enabled":true,"running":true}`), nil
		case "stop":
			state.Status.ProcessOK, state.Status.ServiceOK = false, false
			return nil, nil
		}
		if strings.Contains(call, "--qr-only --json") {
			expires := time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano)
			query := url.Values{"endpoint": {"http://127.0.0.1:8787"}, "issued_at": {time.Now().UTC().Format(time.RFC3339Nano)}, "expires_at": {expires}, "pair_sig": {"short-ticket"}}
			if args[0] == "tailcat" {
				query.Set("transport", "tailcat")
				query.Set("tailcat_pair_address", "temporary-tailcat-address")
			}
			return json.Marshal(linuxPairingInfo{PairURL: "mimiremote://pair?" + query.Encode(), PairExpiresAt: expires})
		}
		return nil, errors.New("unexpected command: " + call)
	}}
	return &linuxTerminalScreen{app: &linuxTrayApplication{ctx: context.Background(), controller: controller, state: state, operation: make(chan struct{}, 1)}, page: "status"}, &calls
}

func TestLinuxTerminalTailcatRequiresEnableThenUsesTailcatPairing(t *testing.T) {
	s, calls := linuxTerminalFixture(t)
	s.selectAction("pair-tailcat")
	if s.pending != "tailcat-enable" || len(*calls) != 0 {
		t.Fatal("Tailcat enabled without confirmation", s.pending, *calls)
	}
	s.input("enable", 50)
	if s.pair == nil || s.pending != "" {
		t.Fatal("Tailcat pairing missing", s.output, s.pending)
	}
	want := []string{"tailcat enable --json", "status --json --runtime", "tailcat status --json", "tailcat pair --qr-only --json"}
	if !reflect.DeepEqual(*calls, want) {
		t.Fatal(*calls)
	}
	s.selectAction("pair-tailscale")
	if s.pair == nil || (*calls)[len(*calls)-1] != "pair --network tailscale --qr-only --json" {
		t.Fatal(*calls, s.output)
	}
	s.selectAction("pair-lan")
	if s.pair == nil || (*calls)[len(*calls)-1] != "pair --network lan --qr-only --json" {
		t.Fatal(*calls, s.output)
	}
}

func TestLinuxTerminalServiceConfirmationIsExplicitAndCancelable(t *testing.T) {
	s, calls := linuxTerminalFixture(t)
	s.selectAction("stop")
	if len(*calls) != 0 || !strings.Contains(s.content(), "断开当前连接") {
		t.Fatal("opening service page mutated service")
	}
	s.input("y", 40)
	if len(*calls) != 0 || !strings.Contains(s.output, "已取消") {
		t.Fatal("generic input confirmed stop")
	}
	s.selectAction("stop")
	s.input("stop", 40)
	if len(*calls) == 0 || (*calls)[0] != "stop" || s.app.snapshot().Status.ProcessOK {
		t.Fatal("explicit stop failed", *calls)
	}
}

func TestLinuxTerminalTicketExpiryAndViewport(t *testing.T) {
	s, _ := linuxTerminalFixture(t)
	s.selectAction("pair-tailscale")
	var output bytes.Buffer
	s.draw(&output, 50, 20, time.Now())
	if !strings.Contains(output.String(), "请放大窗口") || strings.Contains(output.String(), "█") || strings.Contains(output.String(), "short-ticket") {
		t.Fatal("oversized QR wrapped or leaked URI")
	}
	output.Reset()
	s.draw(&output, 240, 120, time.Now())
	if !strings.Contains(output.String(), "█") || !strings.Contains(output.String(), "有效至") {
		t.Fatal("valid QR did not render")
	}
	s.pair.PairExpiresAt = time.Now().Add(-time.Second).Format(time.RFC3339Nano)
	output.Reset()
	s.draw(&output, 240, 120, time.Now())
	if s.pair != nil || strings.Contains(output.String(), "█") || !strings.Contains(output.String(), "已过期") {
		t.Fatal("expired QR retained")
	}
}

func TestLinuxTerminalUntrustedOutputCannotControlTerminal(t *testing.T) {
	input := "safe\n\x1b]52;c;clipboard-payload\a\x1b[31mtok\x1b[0men=private-value\nnormal\u202e text"
	got := safeLinuxTerminalText(input)
	if strings.ContainsAny(got, "\x1b\a\u202e") || strings.Contains(got, "clipboard-payload") || strings.Contains(got, "private-value") || !strings.Contains(got, "safe") {
		t.Fatal(got)
	}
	if got := terminalClip("主机状态 abc", 8); got != "主机状态" {
		t.Fatal("wide characters clipped incorrectly", got)
	}
}

func TestLinuxTerminalLaunchUsesArgumentsAndNeverBrowser(t *testing.T) {
	var looked []string
	lookup := func(name string) (string, error) {
		looked = append(looked, name)
		if name == "xdg-terminal-exec" {
			return "/usr/bin/xdg-terminal-exec", nil
		}
		return "", errors.New("missing")
	}
	executable, agent := "/tmp/with spaces/tray;$x", "/tmp/with spaces/agentd"
	cmd, err := linuxTerminalCommand(executable, agent, "pair-tailcat", lookup)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"/usr/bin/xdg-terminal-exec", "--title=Mimi Remote", "--app-id=io.github.gaixianggeng.MimiRemote", "--", executable, "--agent", agent, "--terminal", "pair-tailcat"}
	if !reflect.DeepEqual(cmd.Args, want) || !reflect.DeepEqual(looked, []string{"xdg-terminal-exec"}) {
		t.Fatal(cmd.Args, looked)
	}
	if _, err = linuxTerminalCommand(executable, agent, "stop; echo x", lookup); err == nil {
		t.Fatal("arbitrary command accepted")
	}
}

func TestLinuxTerminalSeparateWindowsShareOperationLock(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	first, err := lockLinuxTrayOperation()
	if err != nil {
		t.Fatal(err)
	}
	if release, err := lockLinuxTrayOperation(); err == nil {
		release()
		first()
		t.Fatal("concurrent window operation accepted")
	}
	first()
	second, err := lockLinuxTrayOperation()
	if err != nil {
		t.Fatal("completed window retained lock", err)
	}
	second()
	lock := filepath.Join(os.Getenv("XDG_RUNTIME_DIR"), "mimi-remote-tray", "operation.lock")
	if err = os.Remove(lock); err != nil {
		t.Fatal(err)
	}
	if err = os.Symlink(filepath.Join(t.TempDir(), "other"), lock); err != nil {
		t.Fatal(err)
	}
	if release, err := lockLinuxTrayOperation(); err == nil {
		release()
		t.Fatal("symlink lock accepted")
	}
}

func TestLinuxMenuSubmenuAndSymbolicStates(t *testing.T) {
	s, _ := linuxTerminalFixture(t)
	m := &linuxDBusMenu{}
	m.update(linuxMenuItems(s.app.snapshot()))
	_, layout, err := m.GetLayout(112, 1, nil)
	if err != nil || len(layout.Children) == 0 || layout.Properties["children-display"].Value() != "submenu" {
		t.Fatal("service submenu missing", err)
	}
	state := s.app.snapshot()
	if linuxTrayIconName(state) != "mimi-remote-symbolic" {
		t.Fatal("healthy symbolic icon missing")
	}
	state.Status.ProcessOK = false
	if linuxTrayIconName(state) != "mimi-remote-offline-symbolic" {
		t.Fatal("offline symbolic icon missing")
	}
	state.Error = "unavailable"
	if linuxTrayIconName(state) != "mimi-remote-attention-symbolic" {
		t.Fatal("attention symbolic icon missing")
	}
	if pixels := linuxTrayPixmap(state); pixels[0].Data[0] != 0 {
		t.Fatal("fallback icon has an opaque square")
	}
}
