package httpapi

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func writeTestAdapterBridge(t *testing.T, capabilities string) string {
	t.Helper()
	path := writeTestBridgeWithVersion(t, "mimi-claude-adapter 0.3.0")
	if capabilities != "" {
		if err := os.WriteFile(path+".capabilities", []byte(capabilities), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

// SDK 适配器的版本号与旧 bridge 不在同一序列：能力必须按它自己的声明裁剪，
// 不能因为 0.3.0 高于旧 bridge 的全部门槛就声明接管、完全访问等它没实现的能力。
func TestAppServerConfigUsesClaudeAdapterCapabilityDeclaration(t *testing.T) {
	bridgePath := writeTestAdapterBridge(t, `{"name":"mimi-claude-adapter","version":"0.3.0","methods":["initialize","thread/list","thread/read","thread/turns/list","thread/items/list"],"fullAccess":false}`)
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
	})
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/config", nil))
	body := decodeJSON(t, rec)
	claude := body["channels"].([]any)[1].(map[string]any)
	if claude["gateway_available"] != true {
		t.Fatalf("声明有效的适配器应可用：%v", claude)
	}
	methods := claude["methods"].([]any)
	for _, expected := range []string{"thread/list", "thread/read", "thread/turns/list", "thread/items/list"} {
		if !containsAnyString(methods, expected) {
			t.Fatalf("适配器声明的方法 %s 应保留：%v", expected, methods)
		}
	}
	for _, unexpected := range []string{"thread/start", "turn/start", "thread/takeover", "account/rateLimits/read"} {
		if containsAnyString(methods, unexpected) {
			t.Fatalf("适配器未实现的方法 %s 不应声明：%v", unexpected, methods)
		}
	}
	capabilities := claude["capabilities"].(map[string]any)
	// idle_takeover 为 false 时按 omitempty 省略。
	if capabilities["idle_takeover"] == true || capabilities["rate_limits"] != false {
		t.Fatalf("适配器未声明的能力必须关闭：%v", capabilities)
	}
	policy := claude["policy"].(map[string]any)
	sandboxModes, _ := policy["sandbox_modes"].([]any)
	if containsAnyString(sandboxModes, "danger-full-access") {
		t.Fatalf("适配器未声明完全访问，不应开放该档位：%v", policy)
	}
	if bridge := claude["bridge"].(map[string]any); bridge["name"] != "mimi-claude-adapter" {
		t.Fatalf("bridge 元数据应标明适配器：%v", bridge)
	}
}

func TestClaudeBridgeProbeFailsClosedWithoutAdapterDeclaration(t *testing.T) {
	bridgePath := writeTestAdapterBridge(t, "")
	router := &Router{cfg: config.Config{Claude: config.ClaudeConfig{Enabled: true, BridgeBin: bridgePath}}}
	probe := router.refreshClaudeBridgeProbe(true)
	if probe.Healthy || probe.Status != "missing_capabilities" || !strings.Contains(probe.Error, "能力声明") {
		t.Fatalf("读不到能力声明的适配器必须 fail closed：%+v", probe)
	}
}

func TestClaudeAdapterWithoutFullAccessRejectsNoApprovalRequests(t *testing.T) {
	bridgePath := writeTestAdapterBridge(t, `{"methods":["initialize","thread/start","turn/start"],"fullAccess":false}`)
	router := &Router{cfg: config.Config{Claude: config.ClaudeConfig{Enabled: true, BridgeBin: bridgePath}}}
	probe := router.refreshClaudeBridgeProbe(true)
	if !probe.Healthy || probe.fullAccessAvailable() {
		t.Fatalf("未声明完全访问的适配器不应开放完全访问：%+v", probe)
	}
	probe.Adapter.FullAccess = true
	if !probe.fullAccessAvailable() {
		t.Fatalf("声明了完全访问的适配器应开放：%+v", probe)
	}
}
