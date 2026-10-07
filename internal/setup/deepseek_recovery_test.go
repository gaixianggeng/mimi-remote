package setup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// deepSeekTestDependencies 的发现候选固定在这个地址上。
const deepSeekDiscoveredBaseURL = "http://127.0.0.1:5173"

// acceptOnlyDeepSeekToken 模拟重启后的 Harness：只接受本次进程的 token，旧 token 一律 401。
func acceptOnlyDeepSeekToken(valid string) func(context.Context, deepSeekConnectionCandidate) error {
	return func(_ context.Context, candidate deepSeekConnectionCandidate) error {
		if candidate.Token != valid {
			return fmt.Errorf("%w，status=401", harnessclient.ErrCredentialsRejected)
		}
		return nil
	}
}

// writeStaleDeepSeekConnection 写一份已启用或已关闭的连接，token 是上一次 Harness 进程的。
func writeStaleDeepSeekConnection(t *testing.T, enabled bool, baseURL string, autoDiscover bool) (string, string) {
	t.Helper()
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	tokenPath := filepath.Join(dir, managedDeepSeekTokenFilename)
	writeDeepSeekConfigAtPath(t, configPath, enabled, baseURL, tokenPath)
	setDeepSeekAutoDiscover(t, configPath, autoDiscover)
	if err := os.WriteFile(tokenPath, []byte("stale-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return configPath, tokenPath
}

func storedDeepSeekFlags(t *testing.T, configPath string) (enabled, autoDiscover bool) {
	t.Helper()
	var deepSeek map[string]json.RawMessage
	if err := json.Unmarshal(readJSONDocument(t, configPath)["deepseek"], &deepSeek); err != nil {
		t.Fatal(err)
	}
	_ = json.Unmarshal(deepSeek["enabled"], &enabled)
	_ = json.Unmarshal(deepSeek["auto_discover"], &autoDiscover)
	return enabled, autoDiscover
}

func TestConfigureDeepSeekConnectRenewsRejectedCredentialAtSameAddress(t *testing.T) {
	configPath, tokenPath := writeStaleDeepSeekConnection(t, false, deepSeekDiscoveredBaseURL, false)
	dependencies := deepSeekTestDependencies()
	dependencies.probe = acceptOnlyDeepSeekToken(deepSeekTestToken)

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeConnect, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Available || !result.Discovered || !result.RestartRequired {
		t.Fatalf("同一地址上的新凭据应被采用：%+v", result)
	}
	assertDeepSeekFile(t, tokenPath, []byte(deepSeekTestToken+"\n"), true)
	if enabled, autoDiscover := storedDeepSeekFlags(t, configPath); !enabled || !autoDiscover {
		t.Fatalf("采用发现的凭据后应成为受管自动发现连接：enabled=%v auto=%v", enabled, autoDiscover)
	}
	if strings.Contains(result.Message, deepSeekTestToken) || strings.Contains(result.Message, "stale-token") {
		t.Fatalf("结果消息不得回显凭据：%q", result.Message)
	}
}

func TestConfigureDeepSeekConnectNeverAdoptsServiceAtAnotherAddress(t *testing.T) {
	configPath, tokenPath := writeStaleDeepSeekConnection(t, false, "http://127.0.0.1:4000", false)
	dependencies := deepSeekTestDependencies()
	dependencies.probe = acceptOnlyDeepSeekToken(deepSeekTestToken)

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeConnect, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || result.Available || result.Discovered {
		t.Fatalf("另一地址上的服务不能替换已保存的连接：%+v", result)
	}
	if !strings.Contains(result.Message, "拒绝了保存的启动凭据") {
		t.Fatalf("凭据被拒时应给出可执行的恢复说明：%q", result.Message)
	}
	assertDeepSeekFile(t, tokenPath, []byte("stale-token\n"), true)
	if _, autoDiscover := storedDeepSeekFlags(t, configPath); autoDiscover {
		t.Fatal("未采用发现结果时不得改成自动发现")
	}
}

func TestConfigureDeepSeekManualRefreshRenewsRejectedCredentialAtSameAddress(t *testing.T) {
	configPath, tokenPath := writeStaleDeepSeekConnection(t, true, deepSeekDiscoveredBaseURL, false)
	dependencies := deepSeekTestDependencies()
	dependencies.probe = acceptOnlyDeepSeekToken(deepSeekTestToken)

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeRefresh, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Available || !result.Discovered || !result.RestartRequired {
		t.Fatalf("手动连接的凭据被拒时，重新检测应换上同一地址的新凭据：%+v", result)
	}
	assertDeepSeekFile(t, tokenPath, []byte(deepSeekTestToken+"\n"), true)
	if _, autoDiscover := storedDeepSeekFlags(t, configPath); !autoDiscover {
		t.Fatal("换上发现的凭据后应改为受管自动发现，后续 Harness 重启才能自动跟上")
	}
}

func TestConfigureDeepSeekManagedRefreshKeepsWorkingCredentialWhenDiscoveryFails(t *testing.T) {
	configPath, tokenPath := writeStaleDeepSeekConnection(t, true, deepSeekDiscoveredBaseURL, true)
	original := mustReadFile(t, configPath)
	dependencies := deepSeekTestDependencies()
	// 启动日志被清理后发现失败，但已保存的凭据仍被当前 Harness 接受。
	dependencies.discover = func(context.Context) (deepSeekConnectionCandidate, error) {
		return deepSeekConnectionCandidate{}, errDeepSeekNotDiscovered
	}
	dependencies.probe = acceptOnlyDeepSeekToken("stale-token")

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeRefresh, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Enabled || !result.Available || result.RestartRequired {
		t.Fatalf("发现失败不应把仍然可用的连接报成不可用：%+v", result)
	}
	assertDeepSeekFile(t, configPath, original, false)
	assertDeepSeekFile(t, tokenPath, []byte("stale-token\n"), true)
}

func TestConfigureDeepSeekEnabledInspectExplainsRejectedCredential(t *testing.T) {
	configPath, _ := writeStaleDeepSeekConnection(t, true, deepSeekDiscoveredBaseURL, true)
	original := mustReadFile(t, configPath)
	dependencies := deepSeekTestDependencies()
	dependencies.probe = acceptOnlyDeepSeekToken(deepSeekTestToken)
	dependencies.discover = func(context.Context) (deepSeekConnectionCandidate, error) {
		t.Fatal("inspect 保持只读，不运行自动发现")
		return deepSeekConnectionCandidate{}, nil
	}

	result, err := configureDeepSeek(t.Context(), configPath, DeepSeekRuntimeInspect, "", dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if result.Available || !strings.Contains(result.Message, "拒绝了保存的启动凭据") {
		t.Fatalf("inspect 应区分凭据被拒：%+v", result)
	}
	assertDeepSeekFile(t, configPath, original, false)
}

func TestRotateDeepSeekCredentialReplacesManagedTokenAtSameAddress(t *testing.T) {
	configPath, tokenPath := writeStaleDeepSeekConnection(t, true, deepSeekDiscoveredBaseURL, true)
	original := mustReadFile(t, configPath)
	dependencies := deepSeekTestDependencies()
	dependencies.probe = acceptOnlyDeepSeekToken(deepSeekTestToken)

	if err := rotateDeepSeekCredential(t.Context(), configPath, deepSeekDiscoveredBaseURL+"/", dependencies); err != nil {
		t.Fatalf("受管连接应能换上同一地址的新凭据：%v", err)
	}
	assertDeepSeekFile(t, tokenPath, []byte(deepSeekTestToken+"\n"), true)
	// 只换凭据：地址、开关和发现偏好都没变，运行中的 agentd 不需要重载。
	assertDeepSeekFile(t, configPath, original, false)
}

func TestRotateDeepSeekCredentialRefusesIneligibleConnections(t *testing.T) {
	for _, tc := range []struct {
		name         string
		enabled      bool
		autoDiscover bool
		baseURL      string
		expected     string
		external     bool
		discoveredAt string
	}{
		{name: "手动连接", enabled: true, baseURL: deepSeekDiscoveredBaseURL},
		{name: "已关闭", autoDiscover: true, baseURL: deepSeekDiscoveredBaseURL},
		{name: "配置地址已不是 agentd 加载的地址", enabled: true, autoDiscover: true,
			baseURL: deepSeekDiscoveredBaseURL, expected: "http://127.0.0.1:4000"},
		{name: "外部 token 文件", enabled: true, autoDiscover: true, baseURL: deepSeekDiscoveredBaseURL, external: true},
		{name: "发现的服务在另一地址", enabled: true, autoDiscover: true,
			baseURL: deepSeekDiscoveredBaseURL, discoveredAt: "http://127.0.0.1:4000"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			configPath, tokenPath := writeStaleDeepSeekConnection(t, tc.enabled, tc.baseURL, tc.autoDiscover)
			if tc.external {
				tokenPath = filepath.Join(filepath.Dir(configPath), "external.token")
				writeDeepSeekConfigAtPath(t, configPath, tc.enabled, tc.baseURL, tokenPath)
				setDeepSeekAutoDiscover(t, configPath, tc.autoDiscover)
				if err := os.WriteFile(tokenPath, []byte("stale-token\n"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			original := mustReadFile(t, configPath)
			dependencies := deepSeekTestDependencies()
			dependencies.probe = acceptOnlyDeepSeekToken(deepSeekTestToken)
			if tc.discoveredAt != "" {
				dependencies.discover = func(context.Context) (deepSeekConnectionCandidate, error) {
					return deepSeekConnectionCandidate{BaseURL: tc.discoveredAt, Token: deepSeekTestToken, PID: 777}, nil
				}
			} else if !tc.external {
				dependencies.discover = func(context.Context) (deepSeekConnectionCandidate, error) {
					t.Fatal("不符合条件的连接不应运行自动发现")
					return deepSeekConnectionCandidate{}, nil
				}
			}
			expected := tc.expected
			if expected == "" {
				expected = tc.baseURL
			}

			err := rotateDeepSeekCredential(t.Context(), configPath, expected, dependencies)
			if !errors.Is(err, errDeepSeekRecoveryNotEligible) {
				t.Fatalf("应拒绝自动换凭据：%v", err)
			}
			assertDeepSeekFile(t, configPath, original, false)
			assertDeepSeekFile(t, tokenPath, []byte("stale-token\n"), true)
		})
	}
}
