package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// disableAllPairingNetworks 复现 Windows 安装器不勾选局域网后的状态：
// network --lan-enabled=false 把 Tailscale 与局域网意图都显式记录为关闭（#874）。
func disableAllPairingNetworks(t *testing.T, fixture mainLegacyConfigFixture) {
	t.Helper()
	var document map[string]any
	if err := json.Unmarshal(fixture.raw, &document); err != nil {
		t.Fatal(err)
	}
	document["network"] = map[string]any{"allow_lan": false, "allow_tailscale": false}
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixture.source, append(raw, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestManagedServiceNoPairSucceedsWithoutPairingNetwork(t *testing.T) {
	// 安装器覆盖安装依次调用 up 与 restart，托盘调用 start/restart，三者都只需要本机就绪。
	for _, command := range []string{"up", "restart", "start"} {
		t.Run(command, func(t *testing.T) {
			fixture := prepareMainLegacyConfigFixture(t)
			disableAllPairingNetworks(t, fixture)
			prepareBrewSideEffectProbe(t)
			stdout, stderr, err := captureMainCommandOutput(t, func() error {
				return run([]string{"agentd", command, "--wait", "0", "--no-pair"})
			})
			if err != nil {
				t.Fatalf("%s --no-pair 不能因为没有配对网络而失败：%v stderr=%s", command, err, stderr)
			}
			for _, forbidden := range []string{fixture.token, "Token：", "访问码：", serveConnectionQRHeading} {
				if strings.Contains(stdout, forbidden) || strings.Contains(stderr, forbidden) {
					t.Fatalf("%s --no-pair 泄漏长期凭据或二维码 %q：stdout=%q stderr=%q", command, forbidden, stdout, stderr)
				}
			}
		})
	}
}

func TestManagedServiceWithPairingStillExplainsMissingNetwork(t *testing.T) {
	for _, command := range []string{"up", "restart"} {
		t.Run(command, func(t *testing.T) {
			fixture := prepareMainLegacyConfigFixture(t)
			disableAllPairingNetworks(t, fixture)
			prepareBrewSideEffectProbe(t)
			_, _, err := captureMainCommandOutput(t, func() error {
				return run([]string{"agentd", command, "--wait", "0"})
			})
			if err == nil || !strings.Contains(err.Error(), "没有可用的 Tailscale 或局域网连接") {
				t.Fatalf("%s 需要输出二维码时必须先说明没有可用连接：%v", command, err)
			}
		})
	}
}
