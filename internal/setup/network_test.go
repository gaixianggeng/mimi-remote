package setup

import (
	"context"
	"net"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
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

func TestPairingResultAdvertisesMagicDNSWithoutChangingSignedQRCode(t *testing.T) {
	cfg := config.Config{
		Listen: "100.100.20.30:8787",
		Auth:   config.AuthConfig{Token: "secret"},
	}
	result, err := resultFromConfigForNetwork(
		context.Background(),
		"/tmp/config.json",
		cfg,
		PairingNetworkTailscale,
		pairingNetworkLookups{
			tailscaleIP: func(context.Context) string { return "100.100.20.30" },
			tailscaleHost: func(context.Context) tailscaleinfo.Host {
				return tailscaleinfo.Host{
					DNSName:    "studio-mac.tailnet.ts.net",
					DeviceName: "studio-mac",
				}
			},
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.TailscaleDNSName != "studio-mac.tailnet.ts.net" ||
		result.TailscaleDeviceName != "studio-mac" {
		t.Fatalf("配对输出缺少 Tailscale 名称：%+v", result)
	}
	if strings.Contains(result.PairURL, "tailscale_dns_name") ||
		strings.Contains(result.PairURL, "studio-mac") ||
		strings.Contains(result.PairURL, "secret") {
		t.Fatalf("短期二维码不能携带可变名称或长期 Token：%s", result.PairURL)
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

func TestSelectLANIPv4CandidatePrefersPhysicalDefaultRoute(t *testing.T) {
	candidates := []lanIPv4Candidate{
		{
			ip:      "172.21.96.1",
			name:    "vethernet (default switch)",
			score:   lanInterfaceScore("vethernet (default switch)", false),
			virtual: true,
		},
		{
			ip:      "192.168.31.140",
			name:    "wlan",
			score:   lanInterfaceScore("wlan", true),
			virtual: false,
		},
		{
			ip:      "172.18.32.1",
			name:    "vethernet (wsl (hyper-v firewall))",
			score:   lanInterfaceScore("vethernet (wsl (hyper-v firewall))", false),
			virtual: true,
		},
	}
	if got := selectLANIPv4Candidate(candidates); got != "192.168.31.140" {
		t.Fatalf("应选择系统默认路由对应的 WLAN 地址，got=%s", got)
	}
}

func TestSelectLANIPv4CandidateRejectsVirtualOnlyNetwork(t *testing.T) {
	candidates := []lanIPv4Candidate{{
		ip:      "172.21.96.1",
		name:    "vethernet (default switch)",
		score:   lanInterfaceScore("vethernet (default switch)", true),
		virtual: true,
	}}
	if got := selectLANIPv4Candidate(candidates); got != "" {
		t.Fatalf("只有 Hyper-V 私网时不应发布 LAN Endpoint，got=%s", got)
	}
}
