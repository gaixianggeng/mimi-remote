package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTailcatConfigureRequiresExplicitDERPMapFlag(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	err := runTailcatWithWriters([]string{"tailcat", "configure"}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--derp-map-url") {
		t.Fatalf("configure 未显式指定中继时必须失败：%v", err)
	}

	err = runTailcatWithWriters(
		[]string{"tailcat", "enable", "--derp-map-url=https://relay.example/map"},
		&stdout,
		&stderr,
	)
	if err == nil || !strings.Contains(err.Error(), "只适用于 tailcat configure") {
		t.Fatalf("其他子命令不能接受中继参数：%v", err)
	}
}

func TestPrintTailcatStatusIncludesRelayMode(t *testing.T) {
	var output bytes.Buffer
	printTailcatStatus(&output, tailcatCommandStatus{Enabled: true, Running: true})
	if !strings.Contains(output.String(), "中继：Tailcat 默认") {
		t.Fatalf("默认中继未展示：%s", output.String())
	}

	output.Reset()
	printTailcatStatus(&output, tailcatCommandStatus{
		Enabled:    true,
		Running:    true,
		DERPMapURL: "https://relay.example/derpmap/default",
	})
	if !strings.Contains(output.String(), "中继：https://relay.example/derpmap/default") {
		t.Fatalf("自定义中继未展示：%s", output.String())
	}
}

func TestPrintTailcatStatusIncludesManagedAndSelfHostedMode(t *testing.T) {
	for mode, label := range map[string]string{"": "自建", "self_hosted": "自建", "managed": "托管"} {
		var output bytes.Buffer
		printTailcatStatus(&output, tailcatCommandStatus{Mode: mode})
		if !strings.Contains(output.String(), "模式："+label) {
			t.Fatalf("未显示模式：%s", output.String())
		}
	}
}

func TestTailcatManagedCommandsUseLocalControlAndShowMode(t *testing.T) {
	var receivedAction string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/local/tailcat" || r.Header.Get("X-Mimi-Tailcat-Local-Control") != "test-local-control" {
			t.Error("命令未沿用本机控制边界")
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if r.Method == http.MethodGet {
			receivedAction = "status"
		} else {
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Error(err)
			}
			receivedAction = payload["action"]
		}
		if receivedAction == "configure" {
			w.WriteHeader(http.StatusConflict)
			_, _ = fmt.Fprint(w, `{"code":"tailcat_managed_relay_locked","error":"托管模式下不能手动修改中继，请先退出托管模式"}`)
			return
		}
		mode := "managed"
		if receivedAction == "exit-managed" {
			mode = "self_hosted"
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"enabled": true, "running": true, "mode": mode})
	}))
	defer server.Close()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	data, _ := json.Marshal(map[string]any{
		"listen": strings.TrimPrefix(server.URL, "http://"), "auth": map[string]string{"token": "0123456789abcdef0123456789abcdef"},
		"codex": map[string]bool{"enabled": false}, "claude": map[string]bool{"enabled": false},
	})
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "tailcat"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tailcat", "local-control.token"), []byte("test-local-control"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, action := range []string{"enter-managed", "status", "exit-managed"} {
		var stdout, stderr bytes.Buffer
		if err := runTailcatWithWriters([]string{"tailcat", action, "--config", path}, &stdout, &stderr); err != nil {
			t.Fatal(err)
		}
		label := "托管"
		if action == "exit-managed" {
			label = "自建"
		}
		if receivedAction != action || !strings.Contains(stdout.String(), "模式："+label) {
			t.Fatalf("命令或模式输出异常：%s %s", receivedAction, stdout.String())
		}
	}
	var stdout, stderr bytes.Buffer
	if err := runTailcatWithWriters([]string{"tailcat", "configure", "--config", path, "--derp-map-url="}, &stdout, &stderr); err == nil || !strings.Contains(err.Error(), "请先退出托管模式") {
		t.Fatalf("命令应展示拒绝手动改中继的中文错误：%v", err)
	}
}

func TestTailcatPairOnlyAdvertisesManagedFieldsInManagedMode(t *testing.T) {
	for _, tc := range []struct {
		mode        string
		wantManaged bool
	}{
		{mode: "self_hosted", wantManaged: false},
		{mode: "managed", wantManaged: true},
	} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"enabled": true, "running": true, "mode": tc.mode,
				"public_key":          "nodekey:" + strings.Repeat("a", 64),
				"mac_installation_id": "test-installation",
				"pair_address":        "tailcat-test-pair-address",
				"pair_public_key":     "nodekey:" + strings.Repeat("b", 64),
			})
		}))
		dir := t.TempDir()
		path := filepath.Join(dir, "config.json")
		data, _ := json.Marshal(map[string]any{
			"listen": strings.TrimPrefix(server.URL, "http://"), "auth": map[string]string{"token": "0123456789abcdef0123456789abcdef"},
			"codex": map[string]bool{"enabled": false}, "claude": map[string]bool{"enabled": false},
		})
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(filepath.Join(dir, "tailcat"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "tailcat", "local-control.token"), []byte("test-local-control"), 0o600); err != nil {
			t.Fatal(err)
		}
		var stdout, stderr bytes.Buffer
		err := runTailcatWithWriters([]string{"tailcat", "pair", "--config", path, "--qr-only", "--json"}, &stdout, &stderr)
		server.Close()
		if err != nil {
			t.Fatalf("%s 模式生成二维码失败：%v %s", tc.mode, err, stderr.String())
		}
		var output map[string]any
		if err := json.Unmarshal(stdout.Bytes(), &output); err != nil {
			t.Fatal(err)
		}
		pairURL, _ := output["pair_url"].(string)
		if pairURL == "" || !strings.Contains(pairURL, "tailcat_pair_address=") {
			t.Fatalf("%s 模式缺少配对地址：%s", tc.mode, stdout.String())
		}
		// 自建模式带上托管字段，iOS 会先向云端预留电脑名额，到 claim 时才被拒绝。
		for _, field := range []string{"managed_mac_installation_id=", "managed_mac_tailcat_public_key=", "managed_pair_tailcat_public_key="} {
			if strings.Contains(pairURL, field) != tc.wantManaged {
				t.Fatalf("%s 模式的二维码对 %s 的处理不对：%s", tc.mode, field, pairURL)
			}
		}
	}
}
