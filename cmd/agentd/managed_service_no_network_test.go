package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
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

func stubPairingUnavailablePreflight(t *testing.T) {
	t.Helper()
	orig := runHostPreflight
	t.Cleanup(func() { runHostPreflight = orig })
	runHostPreflight = func(_ context.Context, _ agentsetup.PreflightOptions, _ func(agentsetup.PreflightCheck)) agentsetup.PreflightReport {
		return agentsetup.PreflightReport{
			Schema: "mimi.onboarding.preflight/v1",
			Stage:  "pair",
			OK:     false,
			Checks: []agentsetup.PreflightCheck{
				{ID: "assistant_any", Group: "assistant", State: "action_needed", Blocking: true, Code: "no_enabled_assistant"},
				{ID: "network_any", Group: "network", State: "action_needed", Blocking: true, Code: "network_selection_required"},
			},
		}
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
	fixture := prepareMainLegacyConfigFixture(t)
	disableAllPairingNetworks(t, fixture)
	prepareBrewSideEffectProbe(t)
	_, _, err := captureMainCommandOutput(t, func() error {
		return run([]string{"agentd", "up", "--wait", "0"})
	})
	if err == nil || !strings.Contains(err.Error(), "没有可用的 Tailscale 或局域网连接") {
		t.Fatalf("up 需要输出二维码时必须先说明没有可用连接：%v", err)
	}
}

func TestManagedServiceStartAndRestartWarnOnPairingFailure(t *testing.T) {
	for _, command := range []string{"start", "restart"} {
		t.Run(command+"/human", func(t *testing.T) {
			fixture := prepareMainLegacyConfigFixture(t)
			disableAllPairingNetworks(t, fixture)
			prepareBrewSideEffectProbe(t)
			stubPairingUnavailablePreflight(t)

			var stdout, stderr bytes.Buffer
			if status := commandExit([]string{"agentd", command, "--wait", "0"}, &stdout, &stderr); status != 0 {
				t.Fatalf("%s 在服务已启动但配对失败时应退出 0，实际=%d stdout=%q stderr=%q", command, status, stdout.String(), stderr.String())
			}
			for _, want := range []string{
				"警告：服务已启动，但暂时无法生成配对信息：",
				"没有可用的 Tailscale 或局域网连接",
				"配对：暂不可用",
				"没有可用助手",
				"没有可达的手机连接方式",
			} {
				if !strings.Contains(stderr.String(), want) {
					t.Fatalf("%s stderr 缺少 %q：stderr=%q", command, want, stderr.String())
				}
			}
			if strings.Contains(stdout.String(), fixture.token) || strings.Contains(stderr.String(), fixture.token) {
				t.Fatalf("%s 泄漏了长期 Token：stdout=%q stderr=%q", command, stdout.String(), stderr.String())
			}
		})

		t.Run(command+"/json_sanitized", func(t *testing.T) {
			fixture := prepareMainLegacyConfigFixture(t)
			disableAllPairingNetworks(t, fixture)
			prepareBrewSideEffectProbe(t)

			origIssue := issuePairingForCommand
			t.Cleanup(func() { issuePairingForCommand = origIssue })
			issuePairingForCommand = func(context.Context, string, agentsetup.PairingNetwork) (agentsetup.Result, error) {
				return agentsetup.Result{}, errors.New("配对失败 token=" + fixture.token)
			}

			var stdout, stderr bytes.Buffer
			if status := commandExit([]string{"agentd", command, "--wait", "0", "--json"}, &stdout, &stderr); status != 0 {
				t.Fatalf("%s --json 配对失败时应退出 0，实际=%d stdout=%q stderr=%q", command, status, stdout.String(), stderr.String())
			}
			if stderr.Len() != 0 {
				t.Fatalf("%s --json 不应向 stderr 输出内容：%q", command, stderr.String())
			}
			var payload map[string]any
			if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
				t.Fatalf("解析 JSON 失败：%v raw=%q", err, stdout.String())
			}
			if payload["ok"] != true || payload["start_submitted"] != true {
				t.Fatalf("JSON 缺少成功字段：%v", payload)
			}
			if payload["pair_ok"] != false {
				t.Fatalf("JSON 应包含 pair_ok=false：%v", payload)
			}
			pairErr, _ := payload["pair_error"].(string)
			if !strings.Contains(pairErr, "<redacted>") || strings.Contains(pairErr, fixture.token) {
				t.Fatalf("pair_error 必须脱敏且不泄露 Token：%q", pairErr)
			}
		})
	}
}

func TestManagedServiceJSONSuccessBackwardCompatibleAndReadyWaitPairFailure(t *testing.T) {
	fixture := prepareMainLegacyConfigFixture(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/readyz" {
			_ = json.NewEncoder(w).Encode(doctor.Results{OK: true, Version: version})
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	// 将配置监听地址指向本机测试 readyz 服务，以覆盖 --wait > 0 的真实就绪路径。
	var document map[string]any
	if err := json.Unmarshal(fixture.raw, &document); err != nil {
		t.Fatal(err)
	}
	document["listen"] = strings.TrimPrefix(server.URL, "http://")
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixture.source, append(raw, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	fakeCoreManager(t, "homebrew", func(string, string) error { return nil })

	origIssue := issuePairingForCommand
	t.Cleanup(func() { issuePairingForCommand = origIssue })

	// 成功路径保持原有字段集合，不额外附带 pair_ok / pair_error。
	issuePairingForCommand = func(context.Context, string, agentsetup.PairingNetwork) (agentsetup.Result, error) {
		return agentsetup.Result{Endpoint: "http://192.168.1.10:8787", Token: fixture.token}, nil
	}
	var stdout, stderr bytes.Buffer
	if status := commandExit([]string{"agentd", "start", "--wait", "2s", "--json"}, &stdout, &stderr); status != 0 {
		t.Fatalf("start --json 成功路径返回 %d stdout=%q stderr=%q", status, stdout.String(), stderr.String())
	}
	var okPayload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &okPayload); err != nil {
		t.Fatalf("解析成功 JSON 失败：%v", err)
	}
	if okPayload["ok"] != true || okPayload["service_ok"] != true || okPayload["version"] != version {
		t.Fatalf("成功路径 JSON 字段变更：%v", okPayload)
	}
	if _, hasPairOK := okPayload["pair_ok"]; hasPairOK {
		t.Fatalf("成功路径不应新增 pair_ok 字段：%v", okPayload)
	}
	if _, hasPairErr := okPayload["pair_error"]; hasPairErr {
		t.Fatalf("成功路径不应新增 pair_error 字段：%v", okPayload)
	}

	// 服务已就绪但可选配对失败时，返回 service_ok:true + pair_ok:false + pair_error。
	issuePairingForCommand = func(context.Context, string, agentsetup.PairingNetwork) (agentsetup.Result, error) {
		return agentsetup.Result{}, agentsetup.NoPairingNetworkError("linux")
	}
	stdout.Reset()
	stderr.Reset()
	if status := commandExit([]string{"agentd", "start", "--wait", "2s", "--json"}, &stdout, &stderr); status != 0 {
		t.Fatalf("start --json 配对失败应退出 0，实际=%d stdout=%q stderr=%q", status, stdout.String(), stderr.String())
	}
	var warnPayload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &warnPayload); err != nil {
		t.Fatalf("解析配对警告 JSON 失败：%v", err)
	}
	if warnPayload["ok"] != true || warnPayload["service_ok"] != true || warnPayload["version"] != version || warnPayload["pair_ok"] != false {
		t.Fatalf("就绪后配对失败 JSON 字段不符合预期：%v", warnPayload)
	}
	if pairErr, _ := warnPayload["pair_error"].(string); !strings.Contains(pairErr, "agentd network --lan-enabled=true") {
		t.Fatalf("pair_error 缺少可执行步骤：%q", pairErr)
	}
}

func TestManagedServiceStartFailureStillReturnsError(t *testing.T) {
	for _, command := range []string{"start", "restart"} {
		for _, asJSON := range []bool{false, true} {
			name := command + "/human"
			args := []string{"agentd", command, "--wait", "0"}
			if asJSON {
				name = command + "/json"
				args = append(args, "--json")
			}
			t.Run(name, func(t *testing.T) {
				prepareMainLegacyConfigFixture(t)
				useManagedServicePlatform(t, "linux")
				unitPath, err := linuxUserServiceUnitPath()
				if err != nil {
					t.Fatal(err)
				}
				if err := os.MkdirAll(filepath.Dir(unitPath), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(unitPath, []byte("[Service]\n"), 0o644); err != nil {
					t.Fatal(err)
				}
				fakeCoreManager(t, "", func(string, string) error {
					return errors.New("injected core start failure")
				})
				var stdout, stderr bytes.Buffer
				if status := commandExit(args, &stdout, &stderr); status == 0 {
					t.Fatalf("%s 服务启动失败必须返回非零，stdout=%q stderr=%q", name, stdout.String(), stderr.String())
				}
				if asJSON {
					assertOnboardingError(t, stdout.Bytes(), stderr.String(), "service_start_failed", "service_daemon")
				} else if !strings.Contains(stderr.String(), "injected core start failure") {
					t.Fatalf("%s 人类输出缺少启动失败原因：%q", name, stderr.String())
				}
			})
		}
	}
}
