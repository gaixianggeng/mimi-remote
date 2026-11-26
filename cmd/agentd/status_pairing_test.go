package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync/atomic"
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
			name:     "config_restart_required_blocks_pairing_even_when_report_ok",
			platform: "linux",
			report: agentsetup.PreflightReport{
				Stage:                 "pair",
				OK:                    true,
				ConfigRestartRequired: true,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_any", State: "ok"},
					{ID: "network_lan", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
					{ID: "network_any", State: "ok"},
				},
			},
			wantContain: []string{
				"配对：暂不可用",
				"已保存的配置尚未应用到运行中的后台服务",
				"agentd restart --no-pair",
			},
			wantAbsent: []string{"配对：可用"},
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
				"agentd runtime --codex=enabled",
				"claude login",
				"agentd runtime --claude=enabled",
				"agentd runtime --agy=enabled",
				"agentd runtime --deepseek=connect --json",
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
			if status := commandExit([]string{"agentd", "status", "--pairing"}, &stdout, &stderr); status != 0 {
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

func TestStatusPairingCustomConfigQuotesPathAndUsesForegroundRestart(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	useManagedServicePlatform(t, "linux")
	customDir := filepath.Join(t.TempDir(), "my dir '1'")
	if err := os.MkdirAll(customDir, 0o700); err != nil {
		t.Fatal(err)
	}
	customConfig := filepath.Join(customDir, "config.json")
	quoted := shellQuoteArgument(customConfig)

	orig := runHostPreflight
	t.Cleanup(func() { runHostPreflight = orig })

	t.Run("ready_direct_preserves_quoted_config", func(t *testing.T) {
		runHostPreflight = func(_ context.Context, opts agentsetup.PreflightOptions, _ func(agentsetup.PreflightCheck)) agentsetup.PreflightReport {
			if opts.ConfigPath != customConfig {
				t.Errorf("preflight ConfigPath=%q, want %q", opts.ConfigPath, customConfig)
			}
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
		if status := commandExit([]string{"agentd", "status", "--pairing", "--config", customConfig}, &stdout, &stderr); status != 0 {
			t.Fatalf("status --pairing 退出码=%d stderr=%q", status, stderr.String())
		}
		want := "配对：可用，运行 agentd pair --config " + quoted + " --qr-only"
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("输出缺少 %q：\n%s", want, stdout.String())
		}
	})

	t.Run("ready_tailcat_preserves_quoted_config", func(t *testing.T) {
		runHostPreflight = func(context.Context, agentsetup.PreflightOptions, func(agentsetup.PreflightCheck)) agentsetup.PreflightReport {
			return agentsetup.PreflightReport{
				Stage: "pair",
				OK:    true,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_any", State: "ok"},
					{ID: "network_tailcat", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
					{ID: "network_any", State: "ok"},
				},
			}
		}
		var stdout, stderr bytes.Buffer
		if status := commandExit([]string{"agentd", "status", "--pairing", "--config", customConfig}, &stdout, &stderr); status != 0 {
			t.Fatalf("status --pairing 退出码=%d stderr=%q", status, stderr.String())
		}
		want := "配对：可用，运行 agentd tailcat pair --config " + quoted + " --qr-only"
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("输出缺少 %q：\n%s", want, stdout.String())
		}
	})

	t.Run("foreground_blockers_quote_config_and_avoid_managed_restart", func(t *testing.T) {
		runHostPreflight = func(context.Context, agentsetup.PreflightOptions, func(agentsetup.PreflightCheck)) agentsetup.PreflightReport {
			return agentsetup.PreflightReport{
				Stage:                 "pair",
				OK:                    false,
				ConfigRestartRequired: true,
				Checks: []agentsetup.PreflightCheck{
					{ID: "workspace_root", Group: "workspace", State: "action_needed", Blocking: true, Code: "workspace_confirmation_required"},
					{ID: "service_daemon", Group: "service", State: "action_needed", Blocking: true, Code: "service_not_running"},
					{ID: "assistant_codex", Group: "assistant", Code: "codex_not_found", Available: boolPtrPtr(false)},
					{ID: "assistant_claude", Group: "assistant", Code: "claude_not_found", Available: boolPtrPtr(false)},
					{ID: "assistant_any", Group: "assistant", State: "action_needed", Blocking: true, Code: "no_enabled_assistant"},
					{ID: "network_any", Group: "network", State: "action_needed", Blocking: true, Code: "network_selection_required"},
				},
			}
		}
		var stdout, stderr bytes.Buffer
		if status := commandExit([]string{"agentd", "status", "--pairing", "--config", customConfig}, &stdout, &stderr); status != 0 {
			t.Fatalf("status --pairing 退出码=%d stderr=%q", status, stderr.String())
		}
		out := stdout.String()
		for _, want := range []string{
			"agentd workspace --config " + quoted + " --root <代码目录路径>",
			"agentd runtime --config " + quoted + " --codex=enabled",
			"agentd runtime --config " + quoted + " --claude=enabled",
			"agentd network --config " + quoted + " --lan-enabled=true",
			"agentd network --config " + quoted + " --tailscale-enabled=true",
			"agentd tailcat enable --config " + quoted,
			"agentd tailcat pair --config " + quoted,
			"agentd serve --config " + quoted,
			"重启匹配该配置的前台进程",
			"已保存的配置尚未应用到运行中的服务进程",
		} {
			if !strings.Contains(out, want) {
				t.Fatalf("自定义配置输出缺少 %q：\n%s", want, out)
			}
		}
		for _, forbidden := range []string{"agentd restart", "agentd start"} {
			if strings.Contains(out, forbidden) {
				t.Fatalf("自定义配置不应推荐受管服务命令 %q：\n%s", forbidden, out)
			}
		}
	})

	t.Run("managed_default_with_overridden_env_preserves_config_flag", func(t *testing.T) {
		defaultPath := config.PlatformDefaultPath()
		t.Setenv("AGENTD_CONFIG", customConfig)
		runHostPreflight = func(context.Context, agentsetup.PreflightOptions, func(agentsetup.PreflightCheck)) agentsetup.PreflightReport {
			return agentsetup.PreflightReport{
				Stage:                 "pair",
				OK:                    true,
				ConfigRestartRequired: true,
				Checks: []agentsetup.PreflightCheck{
					{ID: "assistant_any", State: "ok"},
					{ID: "network_lan", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
					{ID: "network_any", State: "ok"},
				},
			}
		}
		var stdout, stderr bytes.Buffer
		if status := commandExit([]string{"agentd", "status", "--pairing", "--config", defaultPath}, &stdout, &stderr); status != 0 {
			t.Fatalf("status --pairing 退出码=%d stderr=%q", status, stderr.String())
		}
		want := "agentd restart --config " + shellQuoteArgument(defaultPath) + " --no-pair"
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("受管默认配置受 AGENTD_CONFIG 覆盖时应保留 --config：%q\n%s", want, stdout.String())
		}
	})

	t.Run("double_quote_path_escaping_without_creating_dir", func(t *testing.T) {
		syntheticPath := filepath.Join(t.TempDir(), `my "dir" '1'`, "config.json")
		syntheticQuoted := shellQuoteArgument(syntheticPath)
		readiness := summarizePairingReadiness(agentsetup.PreflightReport{
			Stage: "pair",
			OK:    true,
			Checks: []agentsetup.PreflightCheck{
				{ID: "assistant_any", State: "ok"},
				{ID: "network_lan", State: "ok", Enabled: boolPtr(true), Available: boolPtrPtr(true)},
				{ID: "network_any", State: "ok"},
			},
		}, syntheticPath, "linux")
		want := "agentd pair --config " + syntheticQuoted + " --qr-only"
		if readiness.PairCommand != want {
			t.Fatalf("含双引号路径的命令未正确转义：got=%q want=%q", readiness.PairCommand, want)
		}
	})

	t.Run("windows_foreground_custom_config_does_not_recommend_installer", func(t *testing.T) {
		winCustomConfig := `C:\Users\Alice\my dir '1'\config.json`
		winQuoted := powerShellQuoteArgument(winCustomConfig)
		readiness := summarizePairingReadiness(agentsetup.PreflightReport{
			Stage: "pair",
			OK:    false,
			Checks: []agentsetup.PreflightCheck{
				{ID: "assistant_any", Group: "assistant", State: "ok"},
				{ID: "network_any", Group: "network", State: "action_needed", Blocking: true, Code: "network_selection_required"},
			},
		}, winCustomConfig, "windows")
		if readiness.Ready || len(readiness.Blockers) != 1 {
			t.Fatalf("Windows 自定义配置网络阻塞应返回 1 条阻塞项：%+v", readiness)
		}
		fix := readiness.Blockers[0].Fix
		wantLanCmd := "agentd network --config " + winQuoted + " --lan-enabled=true"
		for _, want := range []string{
			"PowerShell",
			wantLanCmd,
			"agentd network --config " + winQuoted + " --tailscale-enabled=true",
			"agentd serve --config " + winQuoted,
			"agentd tailcat enable --config " + winQuoted,
			"agentd tailcat pair --config " + winQuoted,
		} {
			if !strings.Contains(fix, want) {
				t.Fatalf("Windows 前台自定义配置网络提示缺少 %q：\n%s", want, fix)
			}
		}
		for _, forbidden := range []string{"重新运行安装器", "agentd restart", "&&", "'\"'\"'"} {
			if strings.Contains(fix, forbidden) {
				t.Fatalf("Windows 前台自定义配置不应包含 %q：\n%s", forbidden, fix)
			}
		}
		wantArgs := []string{"agentd", "network", "--config", winCustomConfig, "--lan-enabled=true"}
		gotArgs := parsePowerShellSingleQuotedCommand(t, wantLanCmd)
		if !reflect.DeepEqual(gotArgs, wantArgs) {
			t.Fatalf("PowerShell 参数解析结果不匹配：got=%#v want=%#v", gotArgs, wantArgs)
		}
		if runtime.GOOS == "windows" {
			if ps, err := exec.LookPath("powershell.exe"); err == nil {
				psArgsPart := strings.TrimPrefix(wantLanCmd, "agentd ")
				out, err := exec.Command(ps, "-NoProfile", "-NonInteractive", "-Command", "& { $args } "+psArgsPart).CombinedOutput()
				if err != nil {
					t.Fatalf("powershell.exe 验证参数失败：%v output=%q", err, string(out))
				}
				lines := strings.Split(strings.TrimSpace(strings.ReplaceAll(string(out), "\r\n", "\n")), "\n")
				if !reflect.DeepEqual(lines, wantArgs[1:]) {
					t.Fatalf("powershell.exe 实测参数不匹配：got=%#v want=%#v", lines, wantArgs[1:])
				}
			}
		}
	})
}

func parsePowerShellSingleQuotedCommand(t *testing.T, command string) []string {
	t.Helper()
	var args []string
	var cur strings.Builder
	inToken := false
	inSingle := false
	for i := 0; i < len(command); i++ {
		ch := command[i]
		if inSingle {
			if ch == '\'' {
				if i+1 < len(command) && command[i+1] == '\'' {
					cur.WriteByte('\'')
					i++
					continue
				}
				inSingle = false
				continue
			}
			cur.WriteByte(ch)
			continue
		}
		switch ch {
		case ' ', '\t':
			if inToken {
				args = append(args, cur.String())
				cur.Reset()
				inToken = false
			}
		case '\'':
			inSingle = true
			inToken = true
		default:
			cur.WriteByte(ch)
			inToken = true
		}
	}
	if inSingle {
		t.Fatalf("PowerShell 命令存在未闭合单引号：%q", command)
	}
	if inToken {
		args = append(args, cur.String())
	}
	return args
}

func TestStatusPairingLegacyConfigReadOnlyAndReportsBlocker(t *testing.T) {
	t.Run("valid_legacy_is_previewed_without_migration", func(t *testing.T) {
		isolateOnboardingCommandEnv(t)
		useManagedServicePlatform(t, "linux")
		codeDir := filepath.Join(t.TempDir(), "code")
		if err := os.Mkdir(codeDir, 0o700); err != nil {
			t.Fatal(err)
		}
		legacyPath := config.LegacyDefaultPath()
		defaultPath := config.PlatformDefaultPath()
		raw, err := json.Marshal(map[string]any{
			"listen":       "127.0.0.1:8787",
			"auth":         map[string]any{"token": "legacy-readonly-preview-token-0123"},
			"codex":        map[string]any{"enabled": false},
			"claude":       map[string]any{"enabled": false},
			"network":      map[string]any{"allow_lan": false, "allow_tailscale": false},
			"scan_roots":   []string{codeDir},
			"browse_roots": []string{codeDir},
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(legacyPath), 0o700); err != nil {
			t.Fatal(err)
		}
		configtest.CreatePrivateFile(t, legacyPath, raw)

		var stdout, stderr bytes.Buffer
		if status := commandExit([]string{"agentd", "status", "--pairing"}, &stdout, &stderr); status != 0 {
			t.Fatalf("status --pairing 退出码=%d stderr=%q", status, stderr.String())
		}
		if _, statErr := os.Lstat(defaultPath); !os.IsNotExist(statErr) {
			t.Fatalf("只读诊断不得复制或迁移旧配置到 %s：statErr=%v", defaultPath, statErr)
		}
		if !strings.Contains(stdout.String(), "配对：暂不可用") {
			t.Fatalf("输出缺少配对暂不可用状态：\n%s", stdout.String())
		}
	})

	t.Run("corrupt_legacy_reports_config_blocker_instead_of_exiting", func(t *testing.T) {
		isolateOnboardingCommandEnv(t)
		useManagedServicePlatform(t, "linux")
		legacyPath := config.LegacyDefaultPath()
		defaultPath := config.PlatformDefaultPath()
		if err := os.MkdirAll(filepath.Dir(legacyPath), 0o700); err != nil {
			t.Fatal(err)
		}
		configtest.CreatePrivateFile(t, legacyPath, []byte("{broken-json"))

		var stdout, stderr bytes.Buffer
		if status := commandExit([]string{"agentd", "status", "--pairing"}, &stdout, &stderr); status != 0 {
			t.Fatalf("旧配置损坏时 status --pairing 仍应报告阻塞项并退出 0，实际=%d stderr=%q", status, stderr.String())
		}
		if _, statErr := os.Lstat(defaultPath); !os.IsNotExist(statErr) {
			t.Fatalf("损坏旧配置不得被复制到 %s：statErr=%v", defaultPath, statErr)
		}
		for _, want := range []string{"配对：暂不可用", "配置文件未就绪"} {
			if !strings.Contains(stdout.String(), want) {
				t.Fatalf("输出缺少 %q：\n%s", want, stdout.String())
			}
		}
	})
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
	quotedConfig := shellQuoteArgument(configPath)
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
		wantNext := "agentd status --config " + quotedConfig + " --pairing"
		if !strings.Contains(firstNextLine, wantNext) {
			t.Fatalf("配对不可用时，下一步第一条应保留 --config 并引导检查配对前提：%q", firstNextLine)
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
		wantPair := "agentd pair --config " + quotedConfig + " --qr-only"
		if !strings.Contains(out, "配对：可用，运行 "+wantPair) {
			t.Fatalf("status 缺少带 --config 的配对可用提示：\n%s", out)
		}
		_, nextSection, ok := strings.Cut(out, "下一步：\n")
		if !ok {
			t.Fatalf("status 缺少下一步小节：\n%s", out)
		}
		firstNextLine, _, _ := strings.Cut(nextSection, "\n")
		if !strings.Contains(firstNextLine, wantPair) {
			t.Fatalf("配对可用时，下一步第一条应推荐 %q：%q", wantPair, firstNextLine)
		}
	})
}

func TestStatusPairingIntegratesRealPreflightOffline(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	useManagedServicePlatform(t, "linux")
	const token = "offline-preflight-integration-token"
	var appliedGen atomic.Value
	var authenticatedCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/api/local/preflight" || req.Header.Get("Authorization") != "Bearer "+token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		authenticatedCalls.Add(1)
		applied, _ := appliedGen.Load().(string)
		_ = json.NewEncoder(w).Encode(agentsetup.PreflightHost{
			Generation:        applied,
			AppliedGeneration: &applied,
			Version:           version,
			Ready:             true,
			Assistants:        map[string]bool{"codex": false, "claude": false, "agy": false, "deepseek": false},
			Networks:          map[string]bool{"tailscale": false, "lan": false, "tailcat": false},
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
	savedGen := config.ReadPreflightSnapshot(configPath).Config.SourceGeneration()
	if savedGen == "" {
		t.Fatal("测试配置缺少 SourceGeneration")
	}
	appliedGen.Store(savedGen)

	var stdout, stderr bytes.Buffer
	if status := commandExit([]string{"agentd", "status", "--pairing", "--config", configPath}, &stdout, &stderr); status != 0 {
		t.Fatalf("真实 preflight status --pairing 退出码=%d stderr=%q", status, stderr.String())
	}
	if calls := authenticatedCalls.Load(); calls != 1 {
		t.Fatalf("真实 preflight 必须实际请求已认证的 /api/local/preflight handler，实际调用次数=%d", calls)
	}
	out := stdout.String()
	for _, want := range []string{"配对：暂不可用", "没有可用助手", "没有可达的手机连接方式", shellQuoteArgument(configPath)} {
		if !strings.Contains(out, want) {
			t.Fatalf("真实 preflight 输出缺少 %q：\n%s", want, out)
		}
	}
	for _, forbidden := range []string{"后台服务未就绪", "尚未运行", "尚未应用", token} {
		if strings.Contains(out, forbidden) {
			t.Fatalf("真实 preflight 输出不应包含 %q：\n%s", forbidden, out)
		}
	}

	// 当磁盘配置已修改、daemon 报告 applied_generation 为空时，必须输出未应用配置阻塞项。
	appliedGen.Store("")
	stdout.Reset()
	stderr.Reset()
	if status := commandExit([]string{"agentd", "status", "--pairing", "--config", configPath}, &stdout, &stderr); status != 0 {
		t.Fatalf("未应用配置场景退出码=%d stderr=%q", status, stderr.String())
	}
	if calls := authenticatedCalls.Load(); calls != 2 {
		t.Fatalf("第二次 preflight 也必须到达已认证 handler，实际=%d", calls)
	}
	unappliedOut := stdout.String()
	for _, want := range []string{"配对：暂不可用", "已保存的配置尚未应用到运行中的服务进程", "agentd serve --config " + shellQuoteArgument(configPath)} {
		if !strings.Contains(unappliedOut, want) {
			t.Fatalf("未应用配置输出缺少 %q：\n%s", want, unappliedOut)
		}
	}
}
