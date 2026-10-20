//go:build windows

package main

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestTailcatMenuCommandIDsAppendAfterExistingCommands(t *testing.T) {
	if menuTailcatPair != 111 || menuTailcatToggle != 112 || menuTailcatStatus != 113 {
		t.Fatalf("Tailcat menu IDs = %d/%d/%d, want 111/112/113", menuTailcatPair, menuTailcatToggle, menuTailcatStatus)
	}
}

func TestTailcatArgumentsUseAgentdJSONContract(t *testing.T) {
	for _, item := range []struct {
		got  []string
		want []string
	}{
		{tailcatStatusArguments(), []string{"tailcat", "status", "--json"}},
		{tailcatToggleArguments(true), []string{"tailcat", "enable", "--json"}},
		{tailcatToggleArguments(false), []string{"tailcat", "disable", "--json"}},
		{tailcatPairingArguments(), []string{"tailcat", "pair", "--qr-only", "--json"}},
	} {
		if !reflect.DeepEqual(item.got, item.want) {
			t.Fatalf("arguments = %#v, want %#v", item.got, item.want)
		}
	}
}

func TestParseTailcatTrayStatusRequiresEnabledAndRunningFields(t *testing.T) {
	if _, err := parseTailcatTrayStatus([]byte(`{"paired_device_count":1}`)); err == nil {
		t.Fatal("status without enabled/running must be rejected as an old agentd")
	}
	status, err := parseTailcatTrayStatus([]byte(`{"enabled":true,"running":true,"paired_device_count":2,"address":"private"}`))
	if err != nil || !status.ready() || status.PairedDeviceCount != 2 || status.title() != "运行中 · 2 台设备" {
		t.Fatalf("parsed status = %+v, %v", status, err)
	}
}

func fakeTailcatController(responses map[string]string, calls *[]string) *agentController {
	return &agentController{commandRunner: func(_ context.Context, args ...string) ([]byte, error) {
		key := strings.Join(args, " ")
		*calls = append(*calls, key)
		if value, ok := responses[key]; ok {
			return []byte(value), nil
		}
		return nil, errors.New("unexpected command " + key)
	}}
}

func TestSetTailcatEnableRequiresRunningReadback(t *testing.T) {
	var calls []string
	controller := fakeTailcatController(map[string]string{
		"tailcat enable --json": `{"enabled":true,"running":true}`,
		"tailcat status --json": `{"enabled":true,"running":false,"error":"Tailcat sidecar 已退出"}`,
	}, &calls)
	_, err := controller.setTailcat(context.Background(), true)
	if err == nil || !strings.Contains(err.Error(), "Tailcat sidecar 已退出") {
		t.Fatalf("enable without a running readback must fail with the agentd reason: %v", err)
	}
	if want := []string{"tailcat enable --json", "tailcat status --json"}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("calls = %#v, want %#v", calls, want)
	}
}

func TestSetTailcatSucceedsOnlyAfterConfirmedState(t *testing.T) {
	var calls []string
	controller := fakeTailcatController(map[string]string{
		"tailcat enable --json":  `{"enabled":true,"running":true}`,
		"tailcat disable --json": `{"enabled":false,"running":false}`,
		"tailcat status --json":  `{"enabled":true,"running":true,"paired_device_count":0}`,
	}, &calls)
	if status, err := controller.setTailcat(context.Background(), true); err != nil || !status.ready() {
		t.Fatalf("confirmed enable = %+v, %v", status, err)
	}
	// 状态仍显示运行中时，关闭不能报告成功。
	if _, err := controller.setTailcat(context.Background(), false); err == nil {
		t.Fatal("disable must fail while agentd still reports Tailcat running")
	}
}

func TestTailcatPairingRequiresTailcatTransport(t *testing.T) {
	var calls []string
	controller := fakeTailcatController(map[string]string{
		"tailcat pair --qr-only --json": `{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x"}`,
	}, &calls)
	if _, err := controller.tailcatPairing(context.Background()); err == nil {
		t.Fatal("a pairing link without the Tailcat transport must be rejected")
	}
	controller = fakeTailcatController(map[string]string{
		"tailcat pair --qr-only --json": `{"pair_url":"mimiremote://pair?pair_sig=x&transport=tailcat&tailcat_pair_address=temporary","pair_expires_at":"2026-10-21T00:10:00Z"}`,
	}, &calls)
	if result, err := controller.tailcatPairing(context.Background()); err != nil || result.PairURL == "" {
		t.Fatalf("Tailcat pairing = %+v, %v", result, err)
	}
}

func TestTailcatPresentationOnlyOffersToggleForKnownState(t *testing.T) {
	ready := agentStatus{Version: "1.0.0", ProcessOK: true, ServiceOK: true}
	if p := makeTailcatPresentation(ready, tailcatTrayStatus{}, false, nil, false); p.ToggleEnabled || p.Value != "正在检查" {
		t.Fatalf("unknown Tailcat state offered a toggle: %+v", p)
	}
	if p := makeTailcatPresentation(ready, tailcatTrayStatus{}, true, errors.New("old agentd"), false); p.ToggleEnabled || p.Value != "状态不可用" {
		t.Fatalf("unreadable Tailcat state offered a toggle: %+v", p)
	}
	if p := makeTailcatPresentation(ready, tailcatTrayStatus{}, true, nil, false); !p.ToggleEnabled || p.ToggleLabel != "开启 Tailcat" || p.Value != "未开启" {
		t.Fatalf("disabled Tailcat presentation = %+v", p)
	}
	if p := makeTailcatPresentation(ready, tailcatTrayStatus{}, true, nil, true); p.ToggleEnabled {
		t.Fatalf("busy tray must not offer the Tailcat toggle: %+v", p)
	}
	running := tailcatTrayStatus{Enabled: true, Running: true, PairedDeviceCount: 1}
	if p := makeTailcatPresentation(ready, running, true, nil, false); !p.ToggleEnabled || p.ToggleLabel != "关闭 Tailcat" || p.Value != "运行中 · 1 台设备" {
		t.Fatalf("running Tailcat presentation = %+v", p)
	}
	stopped := agentStatus{Version: "1.0.0"}
	if p := makeTailcatPresentation(stopped, running, true, nil, false); p.ToggleEnabled || p.Value != "服务未运行" {
		t.Fatalf("stopped service still offered Tailcat controls: %+v", p)
	}
}

func TestDefaultPairingUsesTailcatOnlyWithoutReachableNetwork(t *testing.T) {
	running := tailcatTrayStatus{Enabled: true, Running: true}
	// listen 为回环地址时 agentd 仍可能另外监听 Tailscale，不能据此改用 Tailcat。
	tailscale := agentStatus{
		NetworkStatus: &networkStatus{Mode: "loopback"},
		ModuleStatus:  &moduleStatus{TailscaleEnabled: true, TailscaleAvailable: true, LANAvailable: true},
	}
	if defaultPairingUsesTailcat(tailscale, running, true) {
		t.Fatal("a host reachable over Tailscale should keep the default pairing code")
	}
	offline := agentStatus{ModuleStatus: &moduleStatus{TailscaleEnabled: true, LANAvailable: true}}
	if !defaultPairingUsesTailcat(offline, running, true) {
		t.Fatal("without an enabled and available network, running Tailcat should open the Tailcat code")
	}
	if defaultPairingUsesTailcat(offline, tailcatTrayStatus{Enabled: true}, true) {
		t.Fatal("Tailcat that is not running must not be selected automatically")
	}
	if defaultPairingUsesTailcat(agentStatus{}, running, true) {
		t.Fatal("unknown module status must keep the default pairing code")
	}
}
