package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func boolPtrPtr(value bool) **bool {
	p := &value
	return &p
}

func boolPtr(value bool) *bool {
	return &value
}

func TestStatusPairingRejectsIncompatibleFlags(t *testing.T) {
	for _, args := range [][]string{
		{"status", "--pairing", "--json"},
		{"status", "--pairing", "--runtime"},
		{"status", "--pairing", "--network-policy"},
	} {
		var stdout, stderr bytes.Buffer
		err := runStatusWithWriters(args, &stdout, &stderr)
		if err == nil || !strings.Contains(err.Error(), "status --pairing") {
			t.Fatalf("%v 应拒绝不兼容参数组合：%v", args, err)
		}
	}
}

func TestStatusPairingReadyAndUnavailableStates(t *testing.T) {
	tests := []struct {
		name        string
		platform    string
		report      agentsetup.PreflightReport
		wantContain []string
		wantAbsent  []string
	}{
		{
			name:     "direct_network_ready",
			platform: "linux",
			report: agentsetup.PreflightReport{
				Stage: "pair",
				OK:    true,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_any", State: "ok"},
					{ID: "network_lan", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
					{ID: "network_any", State: "ok"},
				},
			},
			wantContain: []string{"配对：可用，运行 agentd pair --qr-only"},
			wantAbsent:  []string{"暂不可用"},
		},
		{
			name:     "tailcat_only_ready",
			platform: "linux",
			report: agentsetup.PreflightReport{
				Stage: "pair",
				OK:    true,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_any", State: "ok"},
					{ID: "network_lan", State: "optional", Enabled: boolPtr(false), Available: boolPtrPtr(false)},
					{ID: "network_tailscale", State: "optional", Enabled: boolPtr(false), Available: boolPtrPtr(false)},
					{ID: "network_tailcat", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
					{ID: "network_any", State: "ok"},
				},
			},
			wantContain: []string{"配对：可用，运行 agentd tailcat pair --qr-only"},
			wantAbsent:  []string{"暂不可用"},
		},
		{
			name:     "missing_assistant_and_network_offline_linux",
			platform: "linux",
			report: agentsetup.PreflightReport{
				Stage: "pair",
				OK:    false,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_codex", Group: "assistant", Code: "codex_not_found", Available: boolPtrPtr(false)},
					{ID: "assistant_claude", Group: "assistant", Code: "claude_not_found", Available: boolPtrPtr(false)},
					{ID: "assistant_any", Group: "assistant", State: "action_needed", Blocking: true, Code: "no_enabled_assistant"},
					{ID: "network_lan", Group: "network", Code: "lan_disabled", Enabled: boolPtr(false), Available: boolPtrPtr(true)},
					{ID: "network_tailscale", Group: "network", Code: "tailscale_not_installed", Enabled: boolPtr(false), Available: boolPtrPtr(false)},
					{ID: "network_any", Group: "network", State: "action_needed", Blocking: true, Code: "network_selection_required"},
				},
			},
			wantContain: []string{
				"配对：暂不可用",
				"没有可用助手",
				"codex login",
				"没有可达的手机连接方式",
				"agentd network --lan-enabled=true",
				"agentd network --tailscale-enabled=true",
				"agentd restart --no-pair",
				"agentd tailcat enable",
				"agentd tailcat pair",
			},
			wantAbsent: []string{"配对：可用"},
		},
		{
			name:     "missing_assistant_only_disabled_available",
			platform: "linux",
			report: agentsetup.PreflightReport{
				Stage: "pair",
				OK:    false,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_codex", Group: "assistant", Code: "assistant_disabled", Enabled: boolPtr(false), Available: boolPtrPtr(true)},
					{ID: "assistant_any", Group: "assistant", State: "action_needed", Blocking: true, Code: "no_enabled_assistant"},
					{ID: "network_lan", Group: "network", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
					{ID: "network_any", Group: "network", State: "ok", Blocking: false},
				},
			},
			wantContain: []string{
				"配对：暂不可用",
				"没有可用助手（已检测到可用助手但尚未启用）",
				"agentd runtime --codex=enabled",
				"agentd restart --no-pair",
			},
			wantAbsent: []string{"没有可达的手机连接方式"},
		},
		{
			name:     "missing_network_only_linux",
			platform: "linux",
			report: agentsetup.PreflightReport{
				Stage: "pair",
				OK:    false,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_codex", Group: "assistant", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
					{ID: "assistant_any", Group: "assistant", State: "ok", Blocking: false},
					{ID: "network_tailscale", Group: "network", Code: "tailscale_not_connected", Enabled: boolPtr(true), Available: boolPtrPtr(false)},
					{ID: "network_any", Group: "network", State: "action_needed", Blocking: true, Code: "no_network_available"},
				},
			},
			wantContain: []string{
				"配对：暂不可用",
				"没有可达的手机连接方式（Tailscale 尚未连接）",
				"agentd network --lan-enabled=true",
			},
			wantAbsent: []string{"没有可用助手"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			isolateOnboardingCommandEnv(t)
			useManagedServicePlatform(t, tc.platform)
			orig := runHostPreflight
			t.Cleanup(func() { runHostPreflight = orig })
			runHostPreflight = func(_ context.Context, opts agentsetup.PreflightOptions, _ func(agentsetup.PreflightCheck)) agentsetup.PreflightReport {
				if opts.Stage != "pair" {
					t.Errorf("status --pairing 必须使用 pair stage，实际=%q", opts.Stage)
				}
				return tc.report
			}

			var stdout, stderr bytes.Buffer
			if status := commandExit([]string{"agentd", "status", "--pairing", "--config", filepath.Join(t.TempDir(), "config.json")}, &stdout, &stderr); status != 0 {
				t.Fatalf("status --pairing 退出码=%d stderr=%q", status, stderr.String())
			}
			output := stdout.String()
			for _, want := range tc.wantContain {
				if !strings.Contains(output, want) {
					t.Fatalf("输出缺少 %q：\n%s", want, output)
				}
			}
			for _, absent := range tc.wantAbsent {
				if strings.Contains(output, absent) {
					t.Fatalf("输出不应包含 %q：\n%s", absent, output)
				}
			}
		})
	}
}

func TestStatusHumanOutputShowsPairingPrerequisitesAndNextSteps(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	useManagedServicePlatform(t, "linux")
	const token = "status-human-pairing-token-012345"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/healthz":
			w.WriteHeader(http.StatusOK)
		case "/api/readyz":
			if req.Header.Get("Authorization") != "Bearer "+token {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(doctor.Results{OK: true, Version: version})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	root := t.TempDir()
	projectDir := filepath.Join(root, "project")
	if err := os.Mkdir(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(root, "config.json")
	raw, err := json.Marshal(map[string]any{
		"listen":     strings.TrimPrefix(server.URL, "http://"),
		"auth":       map[string]any{"token": token},
		"codex":      map[string]any{"enabled": false},
		"claude":     map[string]any{"enabled": false},
		"network":    map[string]any{"allow_lan": false, "allow_tailscale": false},
		"scan_roots": []string{projectDir},
		"projects":   []config.ProjectConfig{{ID: "p1", Name: "P1", Path: projectDir}},
	})
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, configPath, raw)

	orig := runHostPreflight
	t.Cleanup(func() { runHostPreflight = orig })

	t.Run("unavailable_removes_pair_from_first_next_step", func(t *testing.T) {
		runHostPreflight = func(context.Context, agentsetup.PreflightOptions, func(agentsetup.PreflightCheck)) agentsetup.PreflightReport {
			return agentsetup.PreflightReport{
				Stage: "pair",
				OK:    false,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_any", Group: "assistant", State: "action_needed", Blocking: true, Code: "no_enabled_assistant"},
					{ID: "network_any", Group: "network", State: "action_needed", Blocking: true, Code: "network_selection_required"},
				},
			}
		}
		var stdout, stderr bytes.Buffer
		if err := runStatusWithWriters([]string{"status", "--config", configPath}, &stdout, &stderr); err != nil {
			t.Fatalf("status 失败：%v stderr=%q", err, stderr.String())
		}
		out := stdout.String()
		for _, want := range []string{"环境：检查通过", "配对前提：", "配对：暂不可用", "没有可用助手", "没有可达的手机连接方式"} {
			if !strings.Contains(out, want) {
				t.Fatalf("status 缺少 %q：\n%s", want, out)
			}
		}
		_, nextSection, ok := strings.Cut(out, "下一步：\n")
		if !ok {
			t.Fatalf("status 缺少下一步小节：\n%s", out)
		}
		firstNextLine, _, _ := strings.Cut(nextSection, "\n")
		if strings.Contains(firstNextLine, "agentd pair") {
			t.Fatalf("配对不可用时，下一步第一条不应推荐 agentd pair：%q", firstNextLine)
		}
		if !strings.Contains(firstNextLine, "agentd status --pairing") {
			t.Fatalf("配对不可用时，下一步第一条应引导检查配对前提：%q", firstNextLine)
		}
	})

	t.Run("ready_recommends_pair_qr_only", func(t *testing.T) {
		runHostPreflight = func(context.Context, agentsetup.PreflightOptions, func(agentsetup.PreflightCheck)) agentsetup.PreflightReport {
			return agentsetup.PreflightReport{
				Stage: "pair",
				OK:    true,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_any", State: "ok"},
					{ID: "network_lan", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
					{ID: "network_any", State: "ok"},
				},
			}
		}
		var stdout, stderr bytes.Buffer
		if err := runStatusWithWriters([]string{"status", "--config", configPath}, &stdout, &stderr); err != nil {
			t.Fatalf("status 失败：%v stderr=%q", err, stderr.String())
		}
		out := stdout.String()
		if !strings.Contains(out, "配对：可用，运行 agentd pair --qr-only") {
			t.Fatalf("status 缺少配对可用提示：\n%s", out)
		}
		_, nextSection, ok := strings.Cut(out, "下一步：\n")
		if !ok {
			t.Fatalf("status 缺少下一步小节：\n%s", out)
		}
		firstNextLine, _, _ := strings.Cut(nextSection, "\n")
		if !strings.Contains(firstNextLine, "agentd pair --qr-only") {
			t.Fatalf("配对可用时，下一步第一条应推荐 agentd pair --qr-only：%q", firstNextLine)
		}
	})
}

func TestStatusPairingIntegratesRealPreflightOffline(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	useManagedServicePlatform(t, "linux")
	const token = "offline-preflight-integration-token"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/api/local/preflight" || req.Header.Get("Authorization") != "Bearer "+token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(agentsetup.PreflightHost{
			Version:    version,
			Ready:      true,
			Assistants: map[string]bool{"codex": false, "claude": false, "agy": false, "deepseek": false},
			Networks:   map[string]bool{"tailscale": false, "lan": false, "tailcat": false},
		})
	}))
	defer server.Close()

	root := t.TempDir()
	codeDir := filepath.Join(root, "code")
	if err := os.Mkdir(codeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(root, "config.json")
	raw, err := json.Marshal(map[string]any{
		"listen":       strings.TrimPrefix(server.URL, "http://"),
		"auth":         map[string]any{"token": token},
		"codex":        map[string]any{"enabled": false},
		"claude":       map[string]any{"enabled": false},
		"agy":          map[string]any{"enabled": false},
		"deepseek":     map[string]any{"enabled": false},
		"network":      map[string]any{"allow_lan": false, "allow_tailscale": false},
		"scan_roots":   []string{codeDir},
		"browse_roots": []string{codeDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, configPath, raw)

	var stdout, stderr bytes.Buffer
	if status := commandExit([]string{"agentd", "status", "--pairing", "--config", configPath}, &stdout, &stderr); status != 0 {
		t.Fatalf("真实 preflight status --pairing 退出码=%d stderr=%q", status, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{"配对：暂不可用", "没有可用助手", "没有可达的手机连接方式"} {
		if !strings.Contains(out, want) {
			t.Fatalf("真实 preflight 输出缺少 %q：\n%s", want, out)
		}
	}
	if strings.Contains(out, token) {
		t.Fatalf("status --pairing 不得泄露 Token：\n%s", out)
	}
}
