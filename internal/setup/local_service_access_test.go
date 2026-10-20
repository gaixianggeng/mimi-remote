package setup

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeNoNetworkConfig 复现 Windows 安装器不勾选局域网后的配置：loopback listen，
// 且 network --lan-enabled=false 已把两种连接意图都显式记录为关闭（#874）。
func writeNoNetworkConfig(t *testing.T, listen, token string) string {
	t.Helper()
	dir := t.TempDir()
	document := map[string]any{
		"listen":  listen,
		"auth":    map[string]any{"token": token},
		"network": map[string]any{"allow_lan": false, "allow_tailscale": false},
		"runtime": map[string]any{"type": "codex_app_server"},
		"app_server": map[string]any{
			"transport": "ws", "managed": true, "listen": "ws://127.0.0.1:4222",
			"ws_token_file": filepath.Join(dir, "app-server-ws-token"),
		},
		"codex": map[string]any{"bin": "codex"},
	}
	raw, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLocalServiceAccessDoesNotRequirePairingNetwork(t *testing.T) {
	token := "local-service-test-token"
	path := writeNoNetworkConfig(t, "127.0.0.1:9123", token)

	if _, err := Pair(context.Background(), path); err == nil || !strings.Contains(err.Error(), "没有可用的 Tailscale 或局域网连接") {
		t.Fatalf("两种连接都关闭时配对必须失败并说明原因：%v", err)
	}
	result, err := LocalServiceAccess(path)
	if err != nil {
		t.Fatalf("本机就绪检查不能依赖配对网络：%v", err)
	}
	if result.Endpoint != "http://127.0.0.1:9123" || result.Token != token {
		t.Fatalf("应返回 loopback Endpoint 与原 Token：%+v", result)
	}
	if result.PairURL != "" || result.ConnectURL != "" || len(result.Warnings) != 0 {
		t.Fatalf("本机访问信息不应生成配对凭据或网络警告：%+v", result)
	}
}

func TestLocalServiceAccessRejectsUnreadableConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LocalServiceAccess(path); err == nil {
		t.Fatal("损坏的配置不能被当作可启动的服务")
	}
}

func TestNoPairingNetworkErrorGivesPlatformNextSteps(t *testing.T) {
	windows := noPairingNetworkError("windows").Error()
	for _, expected := range []string{"agentd network --tailscale-enabled=true", "agentd restart", "安装器"} {
		if !strings.Contains(windows, expected) {
			t.Fatalf("Windows 提示缺少可执行步骤 %q：%s", expected, windows)
		}
	}
	if strings.Contains(windows, "Tailcat") {
		t.Fatalf("Windows 尚未提供 Tailcat，不能引导用户使用：%s", windows)
	}
	if other := noPairingNetworkError("darwin").Error(); !strings.Contains(other, "Tailcat") {
		t.Fatalf("Mac 与 Linux 仍应提示 Tailcat：%s", other)
	}
}
