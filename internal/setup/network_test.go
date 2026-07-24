package setup

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestPairingEndpointSelectsTailscaleOrLANWithoutChangingToken(t *testing.T) {
	cfg := config.Config{
		Listen:  "100.127.16.9:8787",
		Network: config.NetworkConfig{AllowLAN: true},
	}
	lookups := pairingNetworkLookups{
		tailscaleIP: func(context.Context) string { return "100.100.100.100" },
		lanIP:       func() string { return "192.168.31.20" },
	}

	tailscaleEndpoint, _, err := pairingEndpoint(
		context.Background(),
		cfg,
		PairingNetworkTailscale,
		lookups,
	)
	if err != nil {
		t.Fatal(err)
	}
	if tailscaleEndpoint != "http://100.127.16.9:8787" {
		t.Fatalf("Tailscale Endpoint 异常：%s", tailscaleEndpoint)
	}

	lanEndpoint, warnings, err := pairingEndpoint(
		context.Background(),
		cfg,
		PairingNetworkLAN,
		lookups,
	)
	if err != nil {
		t.Fatal(err)
	}
	if lanEndpoint != "http://192.168.31.20:8787" {
		t.Fatalf("局域网 Endpoint 异常：%s", lanEndpoint)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], "同一局域网") {
		t.Fatalf("局域网配对应包含范围提示：%v", warnings)
	}
}

func TestPairingEndpointAutoPrefersTailscaleAndFallsBackToLAN(t *testing.T) {
	cfg := config.Config{
		Listen:  "0.0.0.0:8787",
		Network: config.NetworkConfig{AllowLAN: true},
	}
	lookups := pairingNetworkLookups{
		tailscaleIP: func(context.Context) string { return "100.100.100.100" },
		lanIP:       func() string { return "192.168.31.20" },
	}

	endpoint, warnings, err := pairingEndpoint(context.Background(), cfg, PairingNetworkAuto, lookups)
	if err != nil {
		t.Fatal(err)
	}
	if endpoint != "http://100.100.100.100:8787" || len(warnings) != 0 {
		t.Fatalf("自动配对应优先 Tailscale：endpoint=%s warnings=%v", endpoint, warnings)
	}

	lookups.tailscaleIP = func(context.Context) string { return "" }
	endpoint, warnings, err = pairingEndpoint(context.Background(), cfg, PairingNetworkAuto, lookups)
	if err != nil {
		t.Fatal(err)
	}
	if endpoint != "http://192.168.31.20:8787" ||
		len(warnings) != 1 ||
		!strings.Contains(warnings[0], "同一局域网") {
		t.Fatalf("无 Tailscale 时自动配对应回退 LAN：endpoint=%s warnings=%v", endpoint, warnings)
	}
}

func TestPairingEndpointAutoRejectsStaleTailscaleWithoutLAN(t *testing.T) {
	cfg := config.Config{Listen: "100.127.16.9:8787"}
	_, _, err := pairingEndpoint(
		context.Background(),
		cfg,
		PairingNetworkAuto,
		pairingNetworkLookups{
			tailscaleIP: func(context.Context) string { return "" },
			lanIP:       func() string { return "192.168.31.20" },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "尚未启用局域网") {
		t.Fatalf("失效 Tailscale 配置必须要求启用 LAN：%v", err)
	}
}

func TestPairingNetworkForEndpointClassifiesRemoteNetwork(t *testing.T) {
	tests := []struct {
		endpoint string
		want     PairingNetwork
	}{
		{endpoint: "http://100.100.20.30:8787", want: PairingNetworkTailscale},
		{endpoint: "http://192.168.31.20:8787", want: PairingNetworkLAN},
		{endpoint: "http://10.0.0.8:8787", want: PairingNetworkLAN},
		{endpoint: "http://127.0.0.1:8787", want: ""},
	}
	for _, testCase := range tests {
		if got := pairingNetworkForEndpoint(testCase.endpoint); got != testCase.want {
			t.Fatalf("网络类型识别错误：endpoint=%s got=%q want=%q", testCase.endpoint, got, testCase.want)
		}
	}
}

func TestPairingEndpointRejectsLANWhenAccessIsDisabled(t *testing.T) {
	cfg := config.Config{Listen: "100.127.16.9:8787"}
	_, _, err := pairingEndpoint(
		context.Background(),
		cfg,
		PairingNetworkLAN,
		pairingNetworkLookups{
			tailscaleIP: func(context.Context) string { return "100.127.16.9" },
			lanIP:       func() string { return "192.168.31.20" },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "尚未启用局域网") {
		t.Fatalf("未开启 LAN 时必须拒绝生成不可达二维码：%v", err)
	}
}

func TestPrivateLANIPv4ExcludesTailscaleAndPublicAddresses(t *testing.T) {
	tests := []struct {
		raw  string
		want bool
	}{
		{raw: "192.168.1.20", want: true},
		{raw: "10.0.0.5", want: true},
		{raw: "172.20.10.2", want: true},
		{raw: "100.127.16.9", want: false},
		{raw: "8.8.8.8", want: false},
		{raw: "127.0.0.1", want: false},
	}
	for _, testCase := range tests {
		if got := isPrivateLANIPv4(net.ParseIP(testCase.raw)); got != testCase.want {
			t.Fatalf("isPrivateLANIPv4(%s)=%v want=%v", testCase.raw, got, testCase.want)
		}
	}
}

func TestSetLANAccessPreservesExistingConfigFields(t *testing.T) {
	root := t.TempDir()
	projectPath := filepath.Join(root, "project")
	if err := os.Mkdir(projectPath, 0o700); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(root, "config.json")
	document := map[string]any{
		"listen":  "100.127.16.9:8787",
		"network": map[string]any{"allow_lan": false, "future_option": "keep"},
		"auth":    map[string]any{"token": "0123456789abcdef0123456789abcdef"},
		"projects": []map[string]any{{
			"id": "demo", "name": "Demo", "path": projectPath,
		}},
		"future_top_level": map[string]any{"keep": true},
	}
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	changed, err := SetLANAccess(configPath, true)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("首次启用 LAN 应报告配置发生变化")
	}
	changed, err = SetLANAccess(configPath, true)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("重复启用 LAN 不应重复写配置")
	}

	updatedRaw, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	updated := map[string]any{}
	if err := json.Unmarshal(updatedRaw, &updated); err != nil {
		t.Fatal(err)
	}
	network, _ := updated["network"].(map[string]any)
	if network["allow_lan"] != true || network["future_option"] != "keep" {
		t.Fatalf("network 字段未被窄范围更新：%v", network)
	}
	if _, ok := updated["future_top_level"]; !ok {
		t.Fatalf("未知顶层字段不应丢失：%v", updated)
	}
	info, err := os.Stat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("配置权限必须保持私有：mode=%v", info.Mode().Perm())
	}
}
