package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// relay-set 是 Mac 和 Windows 客户端共用的中转切换事务，顺序和回读校验都在这里定死。
func newRelayTestServer(t *testing.T) testServer {
	t.Helper()
	server := newTestServer(t)
	// enableTailcat 会持久化开关，测试必须在临时目录准备自己的配置。
	server.router.configPath = filepath.Join(t.TempDir(), "config.json")
	raw, err := json.Marshal(server.router.cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(server.router.configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return server
}

func TestTailcatRelaySetRoutesEachChoice(t *testing.T) {
	previous := "https://self-hosted.example.invalid/derp-map.json"
	custom := "https://custom.example.invalid/derp-map.json"

	t.Run("mimi", func(t *testing.T) {
		server := newRelayTestServer(t)
		fake := &fakeTailcatSidecar{status: tailcatStatus{Mode: config.TailcatModeManaged, Enabled: true, Running: true}}
		managed := &fakeManagedPairingService{status: tailcatStatus{Mode: config.TailcatModeManaged, Running: true}}
		server.router.tailcat = fake
		server.router.managedPairing = managed

		body := postTailcatRelaySet(t, server, "mimi", "")

		if strings.Contains(body, "tailcat_relay") {
			t.Fatalf("进入 Mimi 中转不应报错：%s", body)
		}
		if managed.modeCalls != 1 || !managed.modeManaged {
			t.Fatalf("必须进入托管模式：calls=%d managed=%v", managed.modeCalls, managed.modeManaged)
		}
		if fake.configureCalls != 0 {
			t.Fatalf("Mimi 中转不能写自定义中继：%d", fake.configureCalls)
		}
		if fake.startCalls == 0 {
			t.Fatal("切换后必须开启 sidecar")
		}
	})

	t.Run("custom_from_self_hosted", func(t *testing.T) {
		server := newRelayTestServer(t)
		fake := &fakeTailcatSidecar{status: tailcatStatus{Mode: config.TailcatModeSelfHosted, DERPMapURL: previous, Enabled: true, Running: true}, configureApplies: true}
		managed := &fakeManagedPairingService{status: tailcatStatus{Mode: config.TailcatModeSelfHosted}}
		server.router.tailcat = fake
		server.router.managedPairing = managed

		body := postTailcatRelaySet(t, server, "custom", custom)

		if strings.Contains(body, "tailcat_relay") {
			t.Fatalf("自建中转不应报错：%s", body)
		}
		if fake.configureCalls != 1 || fake.configuredURL != custom {
			t.Fatalf("必须写入自定义中继：calls=%d url=%s", fake.configureCalls, fake.configuredURL)
		}
		if managed.modeCalls != 0 {
			t.Fatalf("已在自建模式时不该再切换托管：%d", managed.modeCalls)
		}
	})

	t.Run("custom_from_managed_uses_one_transaction", func(t *testing.T) {
		server := newRelayTestServer(t)
		fake := &fakeTailcatSidecar{status: tailcatStatus{Mode: config.TailcatModeManaged, DERPMapURL: testOfficialRelayURL, Enabled: true, Running: true}, configureApplies: true}
		managed := &fakeManagedPairingService{status: tailcatStatus{Mode: config.TailcatModeManaged}}
		managed.onConfigureRelay = func(ctx context.Context, url string) (tailcatStatus, error) {
			return fake.ConfigureRelay(ctx, url, func() error { return nil })
		}
		server.router.tailcat = fake
		server.router.managedPairing = managed

		body := postTailcatRelaySet(t, server, "custom", custom)

		if strings.Contains(body, "tailcat_relay") {
			t.Fatalf("从托管切自建不应报错：%s", body)
		}
		if managed.modeCalls != 0 || managed.relayCalls != 1 {
			t.Fatalf("必须直接执行完整中转事务：mode=%d relay=%d", managed.modeCalls, managed.relayCalls)
		}
		if fake.configureCalls != 1 || fake.configuredURL != custom {
			t.Fatalf("退出托管后必须写入中继：calls=%d url=%s", fake.configureCalls, fake.configuredURL)
		}
	})

	t.Run("default", func(t *testing.T) {
		server := newRelayTestServer(t)
		fake := &fakeTailcatSidecar{status: tailcatStatus{Mode: config.TailcatModeSelfHosted, Enabled: true, Running: true}}
		server.router.tailcat = fake
		server.router.managedPairing = &fakeManagedPairingService{status: tailcatStatus{Mode: config.TailcatModeSelfHosted}}

		body := postTailcatRelaySet(t, server, "default", "")

		if strings.Contains(body, "tailcat_relay") {
			t.Fatalf("恢复默认中继不应报错：%s", body)
		}
		if fake.configureCalls != 1 || fake.configuredURL != "" {
			t.Fatalf("默认中继必须显式写空地址：calls=%d url=%q", fake.configureCalls, fake.configuredURL)
		}
	})
}

func TestTailcatRelaySetRejectsInvalidInput(t *testing.T) {
	cases := []struct {
		name      string
		choice    string
		url       string
		wantCode  string
		wantState int
	}{
		{"未知选择", "wireguard", "", "tailcat_relay_choice_invalid", http.StatusBadRequest},
		{"自建缺少地址", "custom", "", "tailcat_relay_url_invalid", http.StatusBadRequest},
		{"自建不是 HTTPS", "custom", "http://custom.example.invalid/derp.json", "tailcat_relay_url_invalid", http.StatusBadRequest},
		{"自建填了官方地址", "custom", config.DefaultManagedTailcatDERPMapURL, "tailcat_relay_url_invalid", http.StatusBadRequest},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := newRelayTestServer(t)
			fake := &fakeTailcatSidecar{status: tailcatStatus{Mode: config.TailcatModeSelfHosted, Enabled: true, Running: true}}
			managed := &fakeManagedPairingService{status: tailcatStatus{Mode: config.TailcatModeSelfHosted}}
			server.router.tailcat = fake
			server.router.managedPairing = managed

			response := tailcatRelaySetResponse(t, server, tc.choice, tc.url)

			if response.Code != tc.wantState || !strings.Contains(response.Body.String(), tc.wantCode) {
				t.Fatalf("期望 %d/%s，实际 %d %s", tc.wantState, tc.wantCode, response.Code, response.Body.String())
			}
			if fake.configureCalls != 0 || fake.startCalls != 0 || managed.modeCalls != 0 {
				t.Fatal("校验失败时不能改动任何状态")
			}
		})
	}
}

func TestTailcatRelaySetFailsWhenReadBackMismatches(t *testing.T) {
	server := newRelayTestServer(t)
	// sidecar 接受配置但状态没变，模拟“命令成功但没生效”。
	fake := &fakeTailcatSidecar{status: tailcatStatus{Mode: config.TailcatModeSelfHosted, DERPMapURL: "", Enabled: true, Running: true}}
	server.router.tailcat = fake
	server.router.managedPairing = &fakeManagedPairingService{status: tailcatStatus{Mode: config.TailcatModeSelfHosted}}

	response := tailcatRelaySetResponse(t, server, "custom", "https://custom.example.invalid/derp.json")

	if response.Code != http.StatusInternalServerError || !strings.Contains(response.Body.String(), "tailcat_relay_not_applied") {
		t.Fatalf("回读不一致必须报错：%d %s", response.Code, response.Body.String())
	}
}

func postTailcatRelaySet(t *testing.T, server testServer, choice, url string) string {
	t.Helper()
	return tailcatRelaySetResponse(t, server, choice, url).Body.String()
}

func tailcatRelaySetResponse(t *testing.T, server testServer, choice, url string) *httptest.ResponseRecorder {
	t.Helper()
	server.router.tailcatLocalToken = "local-only-token"
	req := authedRequest(t, http.MethodPost, "/api/local/tailcat", tailcatControlRequest{
		Action:     "relay-set",
		Choice:     choice,
		DERPMapURL: url,
	})
	req.RemoteAddr = "127.0.0.1:54321"
	req.Host = "127.0.0.1:8787"
	req.Header.Set(TailcatLocalControlHeader, "local-only-token")
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, req)
	return response
}
