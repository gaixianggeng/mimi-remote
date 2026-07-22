package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

func TestAppServerConfigRequiresAuthAndReturnsSanitizedMetadata(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/app-server/config", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("config metadata 必须要求 Bearer Token，got=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}
	if connections.Load() != 0 {
		t.Fatalf("读取 metadata 不应连接 app-server upstream，connections=%d", connections.Load())
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/config", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("config metadata 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
	}
	bodyText := rec.Body.String()
	if strings.Contains(bodyText, testToken) || strings.Contains(bodyText, "real_path") || strings.Contains(bodyText, "RealPath") {
		t.Fatalf("config metadata 不应泄漏 token 或 RealPath：%s", bodyText)
	}
	body := decodeJSON(t, rec)
	if got, _ := body["gateway_ws_url"].(string); got == "" || !strings.HasPrefix(got, "ws://") || !strings.Contains(got, appServerGatewayPath) {
		t.Fatalf("config metadata 应返回 gateway ws url：%v", body)
	}
	runtime, ok := body["runtime"].(map[string]any)
	if !ok || runtime["managed"] != true || runtime["transport"] != "ws" || runtime["gateway_available"] != true {
		t.Fatalf("runtime metadata 异常：%v", body)
	}
	projects, ok := body["projects"].([]any)
	if !ok || len(projects) != 1 {
		t.Fatalf("projects metadata 异常：%v", body)
	}
	project := projects[0].(map[string]any)
	if project["id"] != "demo" || project["path"] == "" {
		t.Fatalf("projects 应只返回安全字段：%v", project)
	}
	policy, ok := body["policy"].(map[string]any)
	if !ok {
		t.Fatalf("policy metadata 异常：%v", body)
	}
	allowedMethods, ok := policy["allowed_methods"].([]any)
	if !ok {
		t.Fatalf("allowed_methods metadata 异常：%v", policy)
	}
	for _, method := range []string{
		"thread/turns/list", "thread/name/set", "thread/compact/start", "thread/unsubscribe",
		"thread/goal/get", "thread/goal/set", "thread/goal/clear", "review/start", "turn/steer", "skills/list", "plugin/installed",
	} {
		if !containsAnyString(allowedMethods, method) {
			t.Fatalf("allowed_methods 应包含 %s：%v", method, allowedMethods)
		}
	}
	channels, ok := body["channels"].([]any)
	if !ok || len(channels) < 1 {
		t.Fatalf("config metadata 应返回 Codex channel：%v", body)
	}
	capabilities, ok := channels[0].(map[string]any)["capabilities"].(map[string]any)
	if !ok || capabilities["rename"] != true || capabilities["compact"] != true || capabilities["review"] != true {
		t.Fatalf("Codex channel 应声明 rename/compact/review 能力：%v", channels[0])
	}
}

func TestAppServerConfigIncludesClaudeChannelWhenEnabled(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	bridgePath := writeTestBridge(t, "#!/bin/sh\nwhile IFS= read -r line; do :; done\n")
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
		cfg.Claude.MaxConcurrentBridges = 3
	})

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/config", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("config metadata 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	channels, ok := body["channels"].([]any)
	if !ok || len(channels) != 2 {
		t.Fatalf("enabled Claude 时应返回 Codex + Claude channels：%v", body)
	}
	claude := channels[1].(map[string]any)
	if claude["runtime_id"] != "claude" || claude["experimental"] != true || claude["lifecycle"] != "per_connection" {
		t.Fatalf("Claude channel metadata 异常：%v", claude)
	}
	if claude["gateway_available"] != true {
		t.Fatalf("Claude bridge 可执行时 gateway_available 应为 true：%v", claude)
	}
	bridge := claude["bridge"].(map[string]any)
	if bridge["status"] != "ready" || bridge["healthy"] != true {
		t.Fatalf("Claude bridge metadata 异常：%v", bridge)
	}
	capabilities := claude["capabilities"].(map[string]any)
	if capabilities["rename"] != false || capabilities["compact"] != false || capabilities["review"] != false || capabilities["rate_limits"] != true {
		t.Fatalf("Claude channel 不应声明 Codex 专属能力：%v", capabilities)
	}
	methods := claude["methods"].([]any)
	if !containsAnyString(methods, "account/rateLimits/read") {
		t.Fatalf("兼容 bridge 应开放 Claude 额度读取：%v", methods)
	}
}

func TestAppServerConfigMarksClaudeChannelUnavailableWhenBridgeMissing(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = filepath.Join(t.TempDir(), "missing-bridge")
		cfg.Claude.MaxConcurrentBridges = 3
	})

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/config", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("config metadata 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	channels := body["channels"].([]any)
	claude := channels[1].(map[string]any)
	if claude["gateway_available"] != false {
		t.Fatalf("missing bridge 时 gateway_available 应为 false：%v", claude)
	}
	bridge := claude["bridge"].(map[string]any)
	if bridge["status"] != "missing_command" || bridge["healthy"] != false {
		t.Fatalf("missing bridge metadata 异常：%v", bridge)
	}
}

func TestAppServerConfigRejectsOldClaudeBridgeVersion(t *testing.T) {
	bridgePath := filepath.Join(t.TempDir(), "old-claude-bridge")
	if err := os.WriteFile(bridgePath, []byte("#!/bin/sh\nprintf 'alleycat-claude-bridge 0.1.9\\n'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
	})
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/config", nil))
	body := decodeJSON(t, rec)
	claude := body["channels"].([]any)[1].(map[string]any)
	bridge := claude["bridge"].(map[string]any)
	capabilities := claude["capabilities"].(map[string]any)
	if claude["gateway_available"] != false || bridge["status"] != "unsupported_version" || bridge["version"] != "0.1.9" {
		t.Fatalf("旧 Claude bridge 必须 fail closed：%v", claude)
	}
	if bridge["minimum_version"] != "0.2.1" || !strings.Contains(bridge["fix"].(string), "cargo install") {
		t.Fatalf("旧 bridge 应返回最低版本和可执行修复提示：%v", bridge)
	}
	if capabilities["rate_limits"] != false {
		t.Fatalf("旧 bridge 不应声明 Claude 额度能力：%v", capabilities)
	}
	if containsAnyString(claude["methods"].([]any), "account/rateLimits/read") {
		t.Fatalf("旧 bridge 不应声明 Claude 额度方法：%v", claude["methods"])
	}

	server := httptest.NewServer(handler)
	defer server.Close()
	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer conn.Close()
	raw := readGatewayRaw(t, conn)
	if !bytes.Contains(raw, []byte(`"code":"CLAUDE_BRIDGE_VERSION_UNSUPPORTED"`)) ||
		!bytes.Contains(raw, []byte(`"bridgeVersion":"0.1.9"`)) ||
		!bytes.Contains(raw, []byte(`"minimumVersion":"0.2.1"`)) ||
		!bytes.Contains(raw, []byte(`"fix":"cargo install`)) {
		t.Fatalf("旧 bridge WS 错误应包含结构化版本诊断：%s", raw)
	}
}

func TestClaudeBridgeProbeRejectsMissingStandardVersion(t *testing.T) {
	bridgePath := filepath.Join(t.TempDir(), "unversioned-claude-bridge")
	if err := os.WriteFile(bridgePath, []byte("#!/bin/sh\nprintf 'bridge starting\\n'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	router := &Router{cfg: config.Config{Claude: config.ClaudeConfig{Enabled: true, BridgeBin: bridgePath}}}
	probe := router.refreshClaudeBridgeProbe(true)
	if probe.Healthy || probe.Status != "missing_version" || !strings.Contains(probe.Error, "需要 >= 0.2.1") {
		t.Fatalf("无标准 --version 的 bridge 必须 fail closed：%+v", probe)
	}
}

func TestAppServerGatewayRejectsMissingBearerTokenBeforeUpstreamDial(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), nil)
	if err == nil {
		_ = conn.Close()
		t.Fatal("未带 Bearer Token 的 gateway WS 不应连接成功")
	}
	if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("未授权 gateway WS 应返回 401，resp=%v err=%v", resp, err)
	}
	if connections.Load() != 0 {
		t.Fatalf("未授权请求必须在连接 upstream 前被拒绝，connections=%d", connections.Load())
	}
}

func TestAppServerGatewayRejectsUnknownRuntime(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath)+"?runtime=bad", http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err == nil {
		_ = conn.Close()
		t.Fatal("unknown runtime 不应连接成功")
	}
	if resp == nil || resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("unknown runtime 应返回 400，resp=%v err=%v", resp, err)
	}
}

func TestClaudeGatewayStartsBridgeAndProxiesJSONLines(t *testing.T) {
	receivedPath := filepath.Join(t.TempDir(), "received.jsonl")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
IFS= read -r line
printf '%%s\n' "$line" > %q
printf '{"jsonrpc":"2.0","id":99,"result":{"models":[]}}\n'
while IFS= read -r line; do :; done
`, receivedPath))
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = 3
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer conn.Close()
	pretty := []byte("{\n  \"jsonrpc\":\"2.0\",\n  \"id\":99,\n  \"method\":\"model/list\",\n  \"params\":{\"unsafe\":\"field\"}\n}")
	if err := conn.WriteMessage(websocket.TextMessage, pretty); err != nil {
		t.Fatal(err)
	}
	raw := readGatewayRaw(t, conn)
	if !bytes.Contains(raw, []byte(`"id":99`)) ||
		!bytes.Contains(raw, []byte(`"model":"claude-fable-5"`)) ||
		!bytes.Contains(raw, []byte(`"model":"sonnet"`)) ||
		!bytes.Contains(raw, []byte(`"model":"opus"`)) ||
		!bytes.Contains(raw, []byte(`"Claude Fable 5"`)) ||
		!bytes.Contains(raw, []byte(`"Claude Opus 4.8"`)) ||
		bytes.Contains(raw, []byte(`"models":[]`)) {
		t.Fatalf("Claude model/list 应由 gateway 覆盖成当前模型目录：%s", raw)
	}
	received, err := os.ReadFile(receivedPath)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(bytes.TrimSpace(received), []byte("\n")) {
		t.Fatalf("stdio bridge 输入必须是单行 JSONL，got=%q", received)
	}
	if !bytes.Contains(received, []byte(`"params":{}`)) {
		t.Fatalf("model/list 应按 gateway policy 清空 params 后写入 bridge，got=%s", received)
	}
}

func TestClaudeGatewayPassesThroughRateLimitAvailabilityWithoutFabrication(t *testing.T) {
	receivedPath := filepath.Join(t.TempDir(), "received.jsonl")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
IFS= read -r line
printf '%%s\n' "$line" > %q
printf '{"jsonrpc":"2.0","id":100,"result":{"rateLimits":{"limitId":"claude","limitName":"Claude","availability":"unavailable","unavailableReason":"headless_statusline_unavailable"}}}\n'
while IFS= read -r line; do :; done
`, receivedPath))
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer conn.Close()
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"id":100,"method":"account/rateLimits/read","params":{"secret":"drop"}}`)); err != nil {
		t.Fatal(err)
	}
	raw := readGatewayRaw(t, conn)
	if !bytes.Contains(raw, []byte(`"limitId":"claude"`)) ||
		!bytes.Contains(raw, []byte(`"availability":"unavailable"`)) ||
		!bytes.Contains(raw, []byte(`"unavailableReason":"headless_statusline_unavailable"`)) ||
		bytes.Contains(raw, []byte(`"usedPercent"`)) {
		t.Fatalf("Claude headless 无百分比时必须透明返回不可用状态，不能伪造 0%%：%s", raw)
	}
	received := readTestFileEventually(t, receivedPath)
	if !bytes.Contains(received, []byte(`"params":{}`)) || bytes.Contains(received, []byte("secret")) {
		t.Fatalf("Claude 额度读取 params 必须被清空：%s", received)
	}
}

func TestClaudeGatewayPassesThroughObservedRateLimitResetWithoutPercent(t *testing.T) {
	policy := &appServerGatewayPolicy{runtimeID: "claude"}
	payload := []byte(`{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"claude","limitName":"Claude","availability":"partial","unavailableReason":"usage_percentage_unavailable","rateLimitReachedType":"rejected","primary":{"resetsAt":1770000000,"windowDurationMins":300}}}}`)
	forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
	if policyErr != nil || !forward || !bytes.Equal(forwarded, payload) || bytes.Contains(forwarded, []byte("usedPercent")) {
		t.Fatalf("Claude rate_limit_event 只能透传真正观测到的窗口和重置时间：forward=%t err=%+v payload=%s", forward, policyErr, forwarded)
	}
}

func TestClaudeGatewayPassesThroughObservedRateLimitUtilization(t *testing.T) {
	policy := &appServerGatewayPolicy{runtimeID: "claude"}
	payload := []byte(`{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"claude","limitName":"Claude","availability":"partial","primary":{"usedPercent":57,"resetsAt":1770000000,"windowDurationMins":300}}}}`)
	forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
	if policyErr != nil || !forward || !bytes.Equal(forwarded, payload) || !bytes.Contains(forwarded, []byte(`"usedPercent":57`)) {
		t.Fatalf("Claude rate_limit_event 的真实 utilization 必须透明透传：forward=%t err=%+v payload=%s", forward, policyErr, forwarded)
	}
}

func TestClaudeGatewayForcesBypassPermissionsOff(t *testing.T) {
	env := buildClaudeBridgeEnv(map[string]string{
		"CLAUDE_BRIDGE_BYPASS_PERMISSIONS": "true",
		"SAFE_VALUE":                       "ok",
	})
	foundSafeValue := false
	for _, value := range env {
		if value == "CLAUDE_BRIDGE_BYPASS_PERMISSIONS=false" {
			foundSafeValue = true
		}
		if value == "CLAUDE_BRIDGE_BYPASS_PERMISSIONS=true" {
			t.Fatalf("危险 bypass 配置不应进入 bridge：%v", env)
		}
	}
	if !foundSafeValue {
		t.Fatalf("Claude bridge 环境必须强制关闭 bypass permissions：%v", env)
	}
}

func TestClaudeGatewayLimitReturnsJSONRPCErrorFrame(t *testing.T) {
	bridge := writeTestBridge(t, `#!/bin/sh
while IFS= read -r line; do sleep 10; done
`)
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = 1
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	first := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer first.Close()
	second := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer second.Close()
	raw := readGatewayRaw(t, second)
	if !bytes.Contains(raw, []byte("CLAUDE_BRIDGE_LIMIT_EXCEEDED")) {
		t.Fatalf("超出 Claude bridge 并发上限应返回 JSON-RPC error frame，got=%s", raw)
	}
}

func TestClaudeGatewayDisconnectTerminatesBridgeProcessGroup(t *testing.T) {
	childPIDPath := filepath.Join(t.TempDir(), "child.pid")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
sleep 30 &
echo $! > %q
while IFS= read -r line; do sleep 30; done
`, childPIDPath))
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = 3
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	childPID := parseTestPID(t, string(readTestFileEventually(t, childPIDPath)))
	t.Cleanup(func() { _ = syscall.Kill(childPID, syscall.SIGKILL) })
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	waitForProcessExit(t, childPID)
}

func TestClaudeGatewayRejectsUnsupportedMethod(t *testing.T) {
	receivedPath := filepath.Join(t.TempDir(), "received.jsonl")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
while IFS= read -r line; do
  printf '%%s\n' "$line" >> %q
done
`, receivedPath))
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = 3
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer conn.Close()
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"id":77,"method":"thread/goal/get","params":{"threadId":"thr"}}`)); err != nil {
		t.Fatal(err)
	}
	if got := readGatewayError(t, conn); !strings.Contains(got.message, "method 不允许") {
		t.Fatalf("Claude 未声明 method 应被 gateway 拒绝：%+v", got)
	}
	time.Sleep(150 * time.Millisecond)
	if raw, err := os.ReadFile(receivedPath); err == nil && len(bytes.TrimSpace(raw)) > 0 {
		t.Fatalf("被拒绝的 Claude frame 不应写入 bridge stdin：%s", raw)
	}
}

// 回归：iPad 老版本/默认草稿会在 thread/resume 和 turn/start 上携带 dangerFullAccess。
// gateway 必须改写降级后转发，而不是硬拒——硬拒会让会话恢复陷入确定性失败的重连死循环。
func TestClaudeGatewayCoercesDangerSandboxOnResumeAndTurn(t *testing.T) {
	receivedPath := filepath.Join(t.TempDir(), "received.jsonl")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
while IFS= read -r line; do
  printf '%%s\n' "$line" >> %q
  case "$line" in
  *'"method":"thread/list"'*)
    printf '{"jsonrpc":"2.0","id":81,"result":{"data":[{"id":"thr-danger"}]}}\n'
    ;;
  esac
done
`, receivedPath))
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = 3
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer conn.Close()
	// 先用 thread/list 响应把 thread 绑定到当前连接，模拟 iPad 打开会话列表后进入历史会话。
	listPayload := fmt.Sprintf(`{"id":81,"method":"thread/list","params":{"cwd":%q}}`, projectDir)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(listPayload)); err != nil {
		t.Fatal(err)
	}
	listResponse := readGatewayRaw(t, conn)
	if !bytes.Contains(listResponse, []byte("thr-danger")) {
		t.Fatalf("thread/list 响应应回流客户端：%s", listResponse)
	}

	resumePayload := fmt.Sprintf(
		`{"id":82,"method":"thread/resume","params":{"threadId":"thr-danger","cwd":%q,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"danger-full-access"}}`,
		projectDir,
	)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(resumePayload)); err != nil {
		t.Fatal(err)
	}
	resumeFrame := readTestFileLineEventually(t, receivedPath, `"thread/resume"`)
	resumeParams := decodeGatewayParamsForTest(t, resumeFrame)
	if resumeParams["sandbox"] != "workspace-write" {
		t.Fatalf("Claude thread/resume 的危险 sandbox 应被改写为 workspace-write：%s", resumeFrame)
	}
	if bytes.Contains(resumeFrame, []byte("danger-full-access")) {
		t.Fatalf("Claude thread/resume 不应把 danger-full-access 透传给 bridge：%s", resumeFrame)
	}

	turnPayload := fmt.Sprintf(
		`{"id":83,"method":"turn/start","params":{"threadId":"thr-danger","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","sandboxPolicy":{"type":"dangerFullAccess","networkAccess":false}}}`,
		projectDir,
	)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(turnPayload)); err != nil {
		t.Fatal(err)
	}
	turnFrame := readTestFileLineEventually(t, receivedPath, `"turn/start"`)
	turnParams := decodeGatewayParamsForTest(t, turnFrame)
	sandboxPolicy, _ := turnParams["sandboxPolicy"].(map[string]any)
	if sandboxPolicy["type"] != "workspaceWrite" || sandboxPolicy["networkAccess"] != false {
		t.Fatalf("Claude turn/start 的危险 sandboxPolicy 应被改写为 workspaceWrite：%s", turnFrame)
	}
}

func TestClaudeGatewayDefaultsSandboxToWorkspaceWrite(t *testing.T) {
	receivedPath := filepath.Join(t.TempDir(), "received.jsonl")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
IFS= read -r line
printf '%%s\n' "$line" > %q
sleep 1
`, receivedPath))
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = 3
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer conn.Close()
	payload := fmt.Sprintf(`{"id":79,"method":"thread/start","params":{"cwd":%q,"approvalPolicy":"on-request"}}`, projectDir)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(payload)); err != nil {
		t.Fatal(err)
	}
	received := readTestFileEventually(t, receivedPath)
	params := decodeGatewayParamsForTest(t, received)
	if params["sandbox"] != "workspace-write" {
		t.Fatalf("Claude thread/start 默认 sandbox 应降到 workspace-write，got=%s params=%v", received, params)
	}
	if bytes.Contains(received, []byte("danger-full-access")) {
		t.Fatalf("Claude 默认 sandbox 不应写入 danger-full-access：%s", received)
	}
}

func TestClaudeGatewaySanitizersForceClaudeWorkspaceWrite(t *testing.T) {
	threadParams := sanitizedGatewayThreadParams("claude", "thread/start", map[string]any{
		"cwd":            "/tmp/repo",
		"model":          "claude-explicit",
		"modelProvider":  "anthropic",
		"approvalPolicy": "on-request",
		"sandbox":        "danger-full-access",
	})
	assertGatewayParamsOnly(t, threadParams, "cwd", "approvalPolicy", "approvalsReviewer", "sandbox")
	if threadParams["sandbox"] != "workspace-write" {
		t.Fatalf("Claude thread sanitizer 应把危险 sandbox 压到 workspace-write：%v", threadParams)
	}

	turnSandbox := sanitizedGatewaySandboxPolicy("claude", map[string]any{
		"type":          "dangerFullAccess",
		"networkAccess": true,
	}, "/tmp/repo")
	if turnSandbox["type"] != "workspaceWrite" || turnSandbox["networkAccess"] != false {
		t.Fatalf("Claude turn sanitizer 应做 defense-in-depth 降权：%v", turnSandbox)
	}
}

func TestClaudeBridgeProbeRefreshesCheapResultWhenStale(t *testing.T) {
	bridgePath := filepath.Join(t.TempDir(), "fake-claude-bridge")
	router := &Router{cfg: config.Config{Claude: config.ClaudeConfig{
		Enabled:   true,
		BridgeBin: bridgePath,
	}}}
	first := router.refreshClaudeBridgeProbe(false)
	if first.Healthy || first.Status != "missing_command" {
		t.Fatalf("缺失 bridge 应标记为不可用：%+v", first)
	}
	if err := os.WriteFile(bridgePath, []byte("#!/bin/sh\nprintf 'alleycat-claude-bridge 0.2.1\\n'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	router.refreshClaudeBridgeProbeIfStale()
	if got := router.claudeBridgeProbe(); got.Healthy {
		t.Fatalf("未过期 probe 不应被 config cheap path 立即刷新：%+v", got)
	}
	router.claudeMu.Lock()
	router.claudeProbe.CheckedAt = time.Now().Add(-claudeBridgeProbeCacheTTL - time.Millisecond)
	router.claudeMu.Unlock()
	router.refreshClaudeBridgeProbeIfStale()
	if got := router.claudeBridgeProbe(); !got.Healthy || got.Status != "ready" {
		t.Fatalf("过期 probe 应通过 cheap stat/LookPath 刷新：%+v", got)
	}
}

func TestAppServerGatewaySendsConfiguredUpstreamToken(t *testing.T) {
	upstreamToken := "upstream-capability-token"
	upstreamURL, received, _ := fakeAppServerUpstreamWithAuth(t, upstreamToken, nil)
	handler, projectDir := appServerGatewayRouterFixtureWithTokenFile(t, upstreamURL, upstreamToken)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	authorized := []byte(fmt.Sprintf(
		`{"id":8,"method":"thread/start","params":{"cwd":%q,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}}`,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, authorized); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-received:
		params := decodeGatewayParamsForTest(t, got)
		if params["cwd"] != projectDir ||
			params["approvalPolicy"] != "on-request" ||
			params["approvalsReviewer"] != "user" ||
			params["sandbox"] != "workspace-write" {
			t.Fatalf("合法帧必须保留安全参数后转发：got=%s want-base=%s", got, authorized)
		}
		if _, ok := params["model"]; ok {
			t.Fatalf("默认模型应由 app-server rollout 决定，gateway 不应补 model：got=%s", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到合法帧，可能 upstream Authorization 未发送")
	}
}

func TestRelayDiagnosticsReportsAppServerGatewayMetrics(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-monitor")
	})
	handler, fixtureProjectDir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = fixtureProjectDir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-monitor")

	var body map[string]any
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/diagnostics/relay", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("relay diagnostics 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
		}
		body = decodeJSON(t, rec)
		gateway := body["app_server_gateway"].(map[string]any)
		clientToUpstream := gateway["client_to_upstream"].(map[string]any)
		upstreamToClient := gateway["upstream_to_client"].(map[string]any)
		rpc := gateway["rpc"].(map[string]any)
		if clientToUpstream["frames"].(float64) >= 1 && upstreamToClient["frames"].(float64) >= 1 && rpc["responses"].(float64) >= 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if body == nil {
		t.Fatal("未读取到 relay diagnostics")
	}
	gateway := body["app_server_gateway"].(map[string]any)
	if got := int(gateway["total_connections"].(float64)); got < 1 {
		t.Fatalf("gateway total_connections 应记录连接，got=%d body=%v", got, gateway)
	}
	if got := int(gateway["active_connections"].(float64)); got < 1 {
		t.Fatalf("gateway active_connections 应包含当前 WS，got=%d body=%v", got, gateway)
	}
	clientToUpstream := gateway["client_to_upstream"].(map[string]any)
	if got := int(clientToUpstream["bytes"].(float64)); got == 0 {
		t.Fatalf("client_to_upstream 应记录转发字节：%v", clientToUpstream)
	}
	upstreamToClient := gateway["upstream_to_client"].(map[string]any)
	if got := int(upstreamToClient["bytes"].(float64)); got == 0 {
		t.Fatalf("upstream_to_client 应记录转发字节：%v", upstreamToClient)
	}
	rpc := gateway["rpc"].(map[string]any)
	if got := int(rpc["responses"].(float64)); got < 1 {
		t.Fatalf("rpc.responses 应记录 app-server 响应：%v", rpc)
	}
	if recent, ok := gateway["recent_rpc"].([]any); !ok || len(recent) == 0 {
		t.Fatalf("recent_rpc 应包含最近 app-server 响应样本：%v", gateway)
	}
	if active, ok := gateway["active_connections_detail"].([]any); !ok || len(active) == 0 {
		t.Fatalf("active_connections_detail 应包含当前连接：%v", gateway)
	}
}

func TestRelayDiagnosticsSanitizesClientWebSocketCloseText(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	secretCloseText := "token=secret prompt=private file=/Users/me/project.txt"
	if err := conn.WriteControl(
		websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.ClosePolicyViolation, secretCloseText),
		time.Now().Add(time.Second),
	); err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/diagnostics/relay", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("relay diagnostics 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "secret") || strings.Contains(rec.Body.String(), "private") || strings.Contains(rec.Body.String(), "/Users/me/project.txt") {
			t.Fatalf("诊断接口不能回显客户端控制的 close text：%s", rec.Body.String())
		}
		body := decodeJSON(t, rec)
		gateway := body["app_server_gateway"].(map[string]any)
		recent, _ := gateway["recent_terminations"].([]any)
		if len(recent) == 0 {
			time.Sleep(10 * time.Millisecond)
			continue
		}
		sample := recent[len(recent)-1].(map[string]any)
		if sample["stage"] != "client_read" || sample["kind"] != "peer_closed" || int(sample["websocket_code"].(float64)) != websocket.ClosePolicyViolation {
			t.Fatalf("客户端关闭应形成结构化样本：%v", sample)
		}
		return
	}
	t.Fatal("超时未观察到客户端关闭诊断样本")
}

func TestAppServerGatewayRejectsEmptyUpstreamTokenFileBeforeDial(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	tokenFile := filepath.Join(t.TempDir(), "empty-token")
	if err := os.WriteFile(tokenFile, []byte(" \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.WSTokenFile = tokenFile
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err == nil {
		_ = conn.Close()
		t.Fatal("空 upstream token file 不应连接成功")
	}
	if resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("空 upstream token file 应返回 503，resp=%v err=%v", resp, err)
	}
	if connections.Load() != 0 {
		t.Fatalf("上游 token 配置无效时不应拨 upstream，connections=%d", connections.Load())
	}
}

func TestAppServerGatewayDoesNotDialUpstreamBeforeValidClientUpgrade(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	// 带 Upgrade 头但缺少 Sec-WebSocket-Key，模拟畸形握手。服务端必须先拒绝外侧握手，
	// 不能为了一个最终不会成立的客户端连接先占用本机 app-server 连接。
	req, err := http.NewRequest(http.MethodGet, server.URL+appServerGatewayPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Version", "13")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("畸形 WebSocket 握手应返回 400，got=%d body=%s", resp.StatusCode, body)
	}
	if connections.Load() != 0 {
		t.Fatalf("客户端 Upgrade 未成功前不能拨 upstream，connections=%d", connections.Load())
	}
}

func TestAppServerGatewayDoesNotExposeTokenFilePath(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	secretPath := filepath.Join(t.TempDir(), "private-machine-secret-token-path")
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.WSTokenFile = secretPath
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err == nil {
		_ = conn.Close()
		t.Fatal("缺失 upstream token file 不应连接成功")
	}
	if resp == nil {
		t.Fatalf("缺失 upstream token file 应返回 HTTP 错误，err=%v", err)
	}
	defer resp.Body.Close()
	body, readErr := io.ReadAll(resp.Body)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("缺失 upstream token file 应返回 503，got=%d body=%s", resp.StatusCode, body)
	}
	if bytes.Contains(body, []byte(secretPath)) || bytes.Contains(body, []byte(filepath.Base(secretPath))) {
		t.Fatalf("移动端错误响应不能泄漏电脑 token file 路径：%s", body)
	}
	if connections.Load() != 0 {
		t.Fatalf("token file 不可用时不应拨 upstream，connections=%d", connections.Load())
	}
}

func TestAppServerGatewayDialFailureDoesNotExposeUpstreamURL(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closedAddress := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	upstreamURL := "ws://" + closedAddress + "/private-upstream-url?access_token=secret-query"
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		if resp != nil {
			defer resp.Body.Close()
		}
		t.Fatalf("外侧 WebSocket 应先完成 Upgrade，再通过安全帧报告 upstream 故障：%v", err)
	}
	defer conn.Close()
	_, payload, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(payload, []byte("CODEX_UPSTREAM_UNAVAILABLE")) {
		t.Fatalf("应返回稳定的 upstream 不可用错误码：%s", payload)
	}
	for _, secret := range []string{upstreamURL, closedAddress, "private-upstream-url", "secret-query"} {
		if bytes.Contains(payload, []byte(secret)) {
			t.Fatalf("移动端 WebSocket 错误不能泄漏 upstream URL，secret=%q payload=%s", secret, payload)
		}
	}
}

func TestAppServerGatewayLimitsConcurrentCodexConnections(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conns := make([]*websocket.Conn, 0, appServerGatewayMaxConnections)
	defer func() {
		for _, conn := range conns {
			_ = conn.Close()
		}
	}()
	for index := 0; index < appServerGatewayMaxConnections; index++ {
		conn, _, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
			"Authorization": []string{"Bearer " + testToken},
		})
		if err != nil {
			t.Fatalf("第 %d 条 gateway 连接应成功：%v", index+1, err)
		}
		conns = append(conns, conn)
	}

	overflow, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err == nil {
		_ = overflow.Close()
		t.Fatal("超过 Codex gateway 并发上限的连接不应成功")
	}
	if resp == nil || resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("超过并发上限应返回 429，resp=%v err=%v", resp, err)
	}
	_ = resp.Body.Close()
	// 外侧 WebSocket 握手完成后，handler 才异步拨 upstream；429 返回时前 8 次拨号
	// 可能尚未全部进入 fake server，先等待已获准的连接完成再核对上限。
	deadline := time.Now().Add(2 * time.Second)
	for connections.Load() < appServerGatewayMaxConnections && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := connections.Load(); got != appServerGatewayMaxConnections {
		t.Fatalf("被限流的外侧连接不能拨 upstream，connections=%d", got)
	}

	// 关闭一条连接后名额应及时归还，避免弱网重连最终把服务永久锁死。
	_ = conns[0].Close()
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		replacement, retryResp, retryErr := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
			"Authorization": []string{"Bearer " + testToken},
		})
		if retryErr == nil {
			conns[0] = replacement
			return
		}
		if retryResp != nil {
			_ = retryResp.Body.Close()
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("关闭连接后 Codex gateway 名额未及时归还")
}

func TestAppServerGatewayRejectsNonLoopbackUpstreamBeforeDial(t *testing.T) {
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, "ws://203.0.113.10:4222", nil)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL(server.URL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err == nil {
		_ = conn.Close()
		t.Fatal("非 loopback upstream 不应连接成功")
	}
	if resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("非 loopback upstream 应返回 503，resp=%v err=%v", resp, err)
	}
}

func TestAppServerGatewayRejectsUnsafeMethodWithoutForwarding(t *testing.T) {
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"id":1,"method":"session/delete","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	errFrame := readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "method 不允许") || string(errFrame.id) != "1" {
		t.Fatalf("非法 method 应返回同 id JSON-RPC error：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayRejectsUnauthorizedThreadIDWithoutForwarding(t *testing.T) {
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	cases := []struct {
		name    string
		payload string
		want    string
	}{
		{
			name:    "thread read",
			payload: `{"id":11,"method":"thread/read","params":{"threadId":"thread-outside","includeTurns":true}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread turns list",
			payload: `{"id":110,"method":"thread/turns/list","params":{"threadId":"thread-outside","limit":40,"sortDirection":"desc","itemsView":"full"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread archive",
			payload: `{"id":111,"method":"thread/archive","params":{"threadId":"thread-outside"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread unarchive",
			payload: `{"id":112,"method":"thread/unarchive","params":{"threadId":"thread-outside"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread goal get",
			payload: `{"id":113,"method":"thread/goal/get","params":{"threadId":"thread-outside"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread goal set",
			payload: `{"id":114,"method":"thread/goal/set","params":{"threadId":"thread-outside","objective":"ship","status":"active"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread goal clear",
			payload: `{"id":115,"method":"thread/goal/clear","params":{"threadId":"thread-outside"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread set name",
			payload: `{"id":116,"method":"thread/name/set","params":{"threadId":"thread-outside","name":"outside"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread compact",
			payload: `{"id":117,"method":"thread/compact/start","params":{"threadId":"thread-outside"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "thread unsubscribe",
			payload: `{"id":118,"method":"thread/unsubscribe","params":{"threadId":"thread-outside"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "review start",
			payload: `{"id":119,"method":"review/start","params":{"threadId":"thread-outside","target":{"type":"uncommittedChanges"},"delivery":"inline"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name: "turn start",
			payload: fmt.Sprintf(
				`{"id":12,"method":"turn/start","params":{"threadId":"thread-outside","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
				projectDir,
				projectDir,
			),
			want: "threadId 未由当前 gateway 连接授权",
		},
		{
			name: "thread resume",
			payload: fmt.Sprintf(
				`{"id":13,"method":"thread/resume","params":{"threadId":"thread-outside","cwd":%q,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}}`,
				projectDir,
			),
			want: "threadId 未由当前 gateway 连接授权",
		},
		{
			name: "thread fork",
			payload: fmt.Sprintf(
				`{"id":131,"method":"thread/fork","params":{"threadId":"thread-outside","cwd":%q,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}}`,
				projectDir,
			),
			want: "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "turn interrupt",
			payload: `{"id":14,"method":"turn/interrupt","params":{"threadId":"thread-outside","turnId":"turn-1"}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
		{
			name:    "turn steer",
			payload: `{"id":15,"method":"turn/steer","params":{"threadId":"thread-outside","expectedTurnId":"turn-1","input":[{"type":"text","text":"继续"}]}}`,
			want:    "threadId 未由当前 gateway 连接授权",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := conn.WriteMessage(websocket.TextMessage, []byte(tc.payload)); err != nil {
				t.Fatal(err)
			}
			errFrame := readGatewayError(t, conn)
			if !strings.Contains(errFrame.message, tc.want) {
				t.Fatalf("unauthorized thread error 应包含 %q，got=%+v", tc.want, errFrame)
			}
		})
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayAuthorizesThreadIDsFromThreadListResponse(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame appServerGatewayFrame
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("fake upstream 收到非法 JSON：%v", err)
			return
		}
		if frame.Method != "thread/list" {
			return
		}
		response := fmt.Sprintf(
			`{"id":%s,"result":{"data":[{"id":"thread-authorized","cwd":%q}]}}`,
			string(*frame.ID),
			projectDir,
		)
		if err := conn.WriteMessage(websocket.TextMessage, []byte(response)); err != nil {
			t.Errorf("fake upstream 写 thread/list 响应失败：%v", err)
		}
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	authorizeGatewayThread(t, conn, received, projectDir, "thread-authorized")

	readFrame := []byte(`{"id":31,"method":"thread/read","params":{"threadId":"thread-authorized","includeTurns":true}}`)
	if err := conn.WriteMessage(websocket.TextMessage, readFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if !bytes.Equal(got, readFrame) {
			t.Fatalf("已授权 thread/read 必须原样转发：got=%s want=%s", got, readFrame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到已授权 thread/read")
	}

	turnsFrame := []byte(`{"id":32,"method":"thread/turns/list","params":{"threadId":"thread-authorized","limit":40,"sortDirection":"desc","itemsView":"full"}}`)
	if err := conn.WriteMessage(websocket.TextMessage, turnsFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		params := decodeGatewayParamsForTest(t, got)
		if params["threadId"] != "thread-authorized" ||
			params["limit"] != float64(appServerGatewayThreadTurnsFullMaxLimit) ||
			params["sortDirection"] != "desc" ||
			params["itemsView"] != "full" {
			t.Fatalf("已授权 thread/turns/list 必须降级 full 大页后转发：got=%s", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到已授权 thread/turns/list")
	}
}

func TestAppServerGatewayNormalizesThreadTurnsListLimit(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-limit")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-limit")

	cases := []struct {
		name       string
		payload    string
		wantLimit  float64
		wantView   string
		wantReject string
	}{
		{
			name:      "default safe limit",
			payload:   `{"id":330,"method":"thread/turns/list","params":{"threadId":"thread-limit"}}`,
			wantLimit: float64(appServerGatewayThreadTurnsDefaultLimit),
		},
		{
			name:      "full large page is downgraded",
			payload:   `{"id":331,"method":"thread/turns/list","params":{"threadId":"thread-limit","limit":50,"sortDirection":"desc","itemsView":"full"}}`,
			wantLimit: float64(appServerGatewayThreadTurnsFullMaxLimit),
			wantView:  "full",
		},
		{
			name:      "summary may use hard max",
			payload:   `{"id":332,"method":"thread/turns/list","params":{"threadId":"thread-limit","limit":50,"itemsView":"summary"}}`,
			wantLimit: float64(appServerGatewayThreadTurnsMaxLimit),
			wantView:  "summary",
		},
		{
			name:       "over hard max is rejected",
			payload:    `{"id":333,"method":"thread/turns/list","params":{"threadId":"thread-limit","limit":51,"itemsView":"summary"}}`,
			wantReject: "limit 不能超过 50",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := conn.WriteMessage(websocket.TextMessage, []byte(tc.payload)); err != nil {
				t.Fatal(err)
			}
			if tc.wantReject != "" {
				errFrame := readGatewayError(t, conn)
				if !strings.Contains(errFrame.message, tc.wantReject) {
					t.Fatalf("limit 拒绝错误应包含 %q，got=%+v", tc.wantReject, errFrame)
				}
				assertNoUpstreamFrame(t, received)
				return
			}
			params := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
			if params["threadId"] != "thread-limit" || params["limit"] != tc.wantLimit {
				t.Fatalf("thread/turns/list limit 归一化异常：%v", params)
			}
			if tc.wantView != "" && params["itemsView"] != tc.wantView {
				t.Fatalf("thread/turns/list itemsView 应保留：%v", params)
			}
		})
	}
}

func TestGatewayThreadListAllowsStateDBFastPathWithinLimit(t *testing.T) {
	params := map[string]any{
		"cwd":            "/tmp/project",
		"limit":          json.Number("50"),
		"sortKey":        "recency_at",
		"sortDirection":  "desc",
		"useStateDbOnly": true,
		"unsafe":         "drop-me",
	}
	if err := validateGatewayThreadListParams(params); err != nil {
		t.Fatalf("thread/list 合法快速路径参数不应被拒绝：%v", err)
	}

	sanitized := sanitizedGatewayThreadListParams(params)
	assertGatewayParamsOnly(t, sanitized, "cwd", "limit", "sortKey", "sortDirection", "useStateDbOnly")
	if sanitized["useStateDbOnly"] != true {
		t.Fatalf("thread/list 应保留 useStateDbOnly：%v", sanitized)
	}
	if sanitized["sortKey"] != "recency_at" {
		t.Fatalf("thread/list 应保留 recency_at：%v", sanitized)
	}
}

func TestGatewayThreadListFingerprintIncludesSortKey(t *testing.T) {
	updated, ok := gatewayHistoryRequestFromParams("thread/list", map[string]any{
		"cwd": "/tmp/project", "limit": json.Number("20"), "sortKey": "updated_at",
	})
	if !ok {
		t.Fatal("thread/list 应进入历史请求指纹")
	}
	recency, ok := gatewayHistoryRequestFromParams("thread/list", map[string]any{
		"cwd": "/tmp/project", "limit": json.Number("20"), "sortKey": "recency_at",
	})
	if !ok {
		t.Fatal("thread/list 应进入历史请求指纹")
	}
	if gatewayHistoryRequestFingerprint("codex", updated) == gatewayHistoryRequestFingerprint("codex", recency) {
		t.Fatal("不同 sortKey 的 thread/list 不能共享并发请求指纹")
	}
}

func TestGatewayThreadListRejectsUnsafeFastPathParams(t *testing.T) {
	tests := []struct {
		name   string
		params map[string]any
		want   string
	}{
		{name: "limit over hard max", params: map[string]any{"limit": json.Number("51")}, want: "不能超过 50"},
		{name: "state db flag must be bool", params: map[string]any{"useStateDbOnly": "true"}, want: "必须是布尔值"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateGatewayThreadListParams(tt.params); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("thread/list 非法参数应被拒绝并包含 %q，got=%v", tt.want, err)
			}
		})
	}
}

func TestGatewayThreadResumeSanitizesBoundedInitialTurnsPage(t *testing.T) {
	params := map[string]any{
		"threadId":     "thread-resume",
		"cwd":          "/tmp/project",
		"excludeTurns": false,
		"initialTurnsPage": map[string]any{
			"limit":         json.Number("5"),
			"sortDirection": "desc",
			"itemsView":     "full",
			"unsafe":        "drop-me",
		},
	}
	if err := validateGatewayThreadResumeParams(params); err != nil {
		t.Fatalf("thread/resume 合法最近页参数不应被拒绝：%v", err)
	}

	sanitized := sanitizedGatewayThreadParams("codex", "thread/resume", params)
	if sanitized["excludeTurns"] != true {
		t.Fatalf("thread/resume 必须强制 excludeTurns=true：%v", sanitized)
	}
	page, ok := sanitized["initialTurnsPage"].(map[string]any)
	if !ok {
		t.Fatalf("thread/resume 应保留安全 initialTurnsPage：%v", sanitized)
	}
	assertGatewayParamsOnly(t, page, "limit", "sortDirection", "itemsView")
	if page["limit"] != int64(5) || page["sortDirection"] != "desc" || page["itemsView"] != "full" {
		t.Fatalf("initialTurnsPage 参数被意外改写：%v", page)
	}
}

func TestGatewayThreadResumeDefaultsInitialTurnsPageToSafeRecentPage(t *testing.T) {
	sanitized := sanitizedGatewayThreadParams("codex", "thread/resume", map[string]any{
		"threadId":         "thread-resume",
		"initialTurnsPage": map[string]any{},
	})
	page, ok := sanitized["initialTurnsPage"].(map[string]any)
	if !ok {
		t.Fatalf("thread/resume 空 initialTurnsPage 应归一化为安全最近页：%v", sanitized)
	}
	if page["limit"] != int64(5) || page["sortDirection"] != "desc" || page["itemsView"] != "full" {
		t.Fatalf("thread/resume 最近页安全默认值异常：%v", page)
	}
}

func TestGatewayThreadResumeRejectsUnsafeInitialTurnsPage(t *testing.T) {
	tests := []struct {
		name string
		page any
		want string
	}{
		{name: "page must be object", page: "recent", want: "必须是对象"},
		{name: "limit over hard max", page: map[string]any{"limit": json.Number("6")}, want: "不能超过 5"},
		{name: "direction must be desc", page: map[string]any{"sortDirection": "asc"}, want: "只支持 desc"},
		{name: "view must be bounded", page: map[string]any{"itemsView": "notLoaded"}, want: "只支持 summary/full"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateGatewayThreadResumeParams(map[string]any{"initialTurnsPage": tt.page})
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("thread/resume 非法最近页应被拒绝并包含 %q，got=%v", tt.want, err)
			}
		})
	}
}

func TestAppServerGatewayCapsOversizedHistoryResponses(t *testing.T) {
	oldCap := appServerGatewayHistoryResponseCapBytes
	oldBudgetBytes := appServerGatewayHistoryBudgetMaxResponseBytes
	appServerGatewayHistoryResponseCapBytes = 512
	appServerGatewayHistoryBudgetMaxResponseBytes = 64 << 10
	t.Cleanup(func() {
		appServerGatewayHistoryResponseCapBytes = oldCap
		appServerGatewayHistoryBudgetMaxResponseBytes = oldBudgetBytes
	})

	cases := []struct {
		name    string
		method  string
		request string
	}{
		{
			name:    "turns list",
			method:  "thread/turns/list",
			request: `{"id":710,"method":"thread/turns/list","params":{"threadId":"thread-history","limit":20,"itemsView":"full"}}`,
		},
		{
			name:    "thread read include turns",
			method:  "thread/read",
			request: `{"id":711,"method":"thread/read","params":{"threadId":"thread-history","includeTurns":true}}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var projectDir string
			upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
				var frame appServerGatewayFrame
				if err := json.Unmarshal(payload, &frame); err != nil {
					t.Errorf("fake upstream 收到非法 JSON：%v", err)
					return
				}
				if frame.Method == "thread/list" {
					respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-history")
					return
				}
				if frame.Method != tc.method {
					return
				}
				padding := strings.Repeat("history-block-marker", 80)
				response := fmt.Sprintf(`{"id":%s,"result":{"data":[{"id":"turn-1","content":%q}]}}`, string(*frame.ID), padding)
				if err := conn.WriteMessage(websocket.TextMessage, []byte(response)); err != nil {
					t.Errorf("fake upstream 写 history 大响应失败：%v", err)
				}
			})
			handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
			projectDir = dir
			server := httptest.NewServer(handler)
			defer server.Close()

			conn := dialAuthedGateway(t, server.URL)
			defer conn.Close()
			authorizeGatewayThread(t, conn, received, projectDir, "thread-history")

			if err := conn.WriteMessage(websocket.TextMessage, []byte(tc.request)); err != nil {
				t.Fatal(err)
			}
			_ = readUpstreamFrame(t, received)
			raw := readGatewayRaw(t, conn)
			if len(raw) >= appServerGatewayHistoryResponseCapBytes {
				t.Fatalf("history cap 应只写小 error 给 client，got bytes=%d raw=%s", len(raw), raw)
			}
			if bytes.Contains(raw, []byte("history-block-marker")) {
				t.Fatalf("history 大响应内容不应透传给 client：%s", raw)
			}
			var frame struct {
				ID    json.RawMessage `json:"id"`
				Error struct {
					Code    int            `json:"code"`
					Message string         `json:"message"`
					Data    map[string]any `json:"data"`
				} `json:"error"`
			}
			if err := json.Unmarshal(raw, &frame); err != nil {
				t.Fatalf("history cap error 不是合法 JSON：%v raw=%s", err, raw)
			}
			if frame.Error.Code != appServerPolicyErrorCode || !strings.Contains(frame.Error.Message, "history response 过大") {
				t.Fatalf("history cap error 文案异常：%+v raw=%s", frame, raw)
			}
			if frame.Error.Data["reason"] != "history_response_too_large" {
				t.Fatalf("history cap error 应包含 reason data：%+v raw=%s", frame.Error.Data, raw)
			}
			if got := int(frame.Error.Data["retryAfterSeconds"].(float64)); got <= 0 {
				t.Fatalf("history cap error 应包含 retryAfterSeconds：%+v raw=%s", frame.Error.Data, raw)
			}
			if got := int(frame.Error.Data["responseBytes"].(float64)); got <= appServerGatewayHistoryResponseCapBytes {
				t.Fatalf("history cap error 应包含 responseBytes：%+v raw=%s", frame.Error.Data, raw)
			}
			if got := int(frame.Error.Data["maxResponseBytes"].(float64)); got != appServerGatewayHistoryResponseCapBytes {
				t.Fatalf("history cap error 应包含 maxResponseBytes：%+v raw=%s", frame.Error.Data, raw)
			}

			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/diagnostics/relay", nil))
			if rec.Code != http.StatusOK {
				t.Fatalf("relay diagnostics 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
			}
			body := decodeJSON(t, rec)
			gateway := body["app_server_gateway"].(map[string]any)
			if got := int(gateway["history_responses_blocked"].(float64)); got < 1 {
				t.Fatalf("diagnostics 应记录 history response 阻断：%v", gateway)
			}
			hints := body["hints"].([]any)
			if !containsAnySubstring(hints, "超大历史响应") {
				t.Fatalf("diagnostics hints 应提示超大历史响应：%v", hints)
			}
		})
	}
}

func TestAppServerGatewayRedactsInlineHistoryImagesBeforeCap(t *testing.T) {
	oldCap := appServerGatewayHistoryResponseCapBytes
	appServerGatewayHistoryResponseCapBytes = 1024
	t.Cleanup(func() {
		appServerGatewayHistoryResponseCapBytes = oldCap
	})

	var projectDir string
	imagePayload := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("large-history-image", 120)))
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame appServerGatewayFrame
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("fake upstream 收到非法 JSON：%v", err)
			return
		}
		if frame.Method == "thread/list" {
			respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-image-history")
			return
		}
		if frame.Method != "thread/turns/list" {
			return
		}
		response := fmt.Sprintf(
			`{"id":%s,"result":{"data":[{"id":"turn-image","items":[{"type":"userMessage","id":"user-image","content":[{"type":"text","text":"看这张截图"},{"type":"image","url":"data:image/png;base64,%s","detail":"high"}]}]}]}}`,
			string(*frame.ID),
			imagePayload,
		)
		if err := conn.WriteMessage(websocket.TextMessage, []byte(response)); err != nil {
			t.Errorf("fake upstream 写 inline image history 响应失败：%v", err)
		}
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-image-history")

	request := []byte(`{"id":730,"method":"thread/turns/list","params":{"threadId":"thread-image-history","limit":20,"itemsView":"full"}}`)
	if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
		t.Fatal(err)
	}
	_ = readUpstreamFrame(t, received)
	raw := readGatewayRaw(t, conn)
	if bytes.Contains(raw, []byte(imagePayload)) || bytes.Contains(raw, []byte("data:image/png;base64")) {
		t.Fatalf("history inline 图片不应透传给 iPad：%s", raw)
	}
	if bytes.Contains(raw, []byte(`"error"`)) {
		t.Fatalf("inline 图片应被占位化而不是触发 history cap：%s", raw)
	}
	if len(raw) >= appServerGatewayHistoryResponseCapBytes {
		t.Fatalf("redacted history response 应小于 cap，got=%d raw=%s", len(raw), raw)
	}

	var frame struct {
		Result struct {
			Data []struct {
				Items []struct {
					Content []struct {
						Type        string `json:"type"`
						URL         string `json:"url"`
						ContentType string `json:"contentType"`
						ByteCount   int    `json:"byteCount"`
						Redacted    bool   `json:"redacted"`
					} `json:"content"`
				} `json:"items"`
			} `json:"data"`
		} `json:"result"`
	}
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatalf("redacted history response 不是合法 JSON：%v raw=%s", err, raw)
	}
	content := frame.Result.Data[0].Items[0].Content
	if len(content) != 2 || content[1].Type != "image" {
		t.Fatalf("history 图片占位结构异常：%+v", content)
	}
	if !strings.HasPrefix(content[1].URL, "agentd-history-media://") || !content[1].Redacted {
		t.Fatalf("history 图片应替换为 agentd media URL：%+v", content[1])
	}
	if content[1].ContentType != "image/png" || content[1].ByteCount == 0 {
		t.Fatalf("history 图片应保留类型和大小元数据：%+v", content[1])
	}

	mediaID := strings.TrimPrefix(content[1].URL, "agentd-history-media://")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/history-media/"+mediaID, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("history media 应可按需读取，got=%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["content_type"] != "image/png" {
		t.Fatalf("history media content_type 异常：%v", body)
	}
	if body["content_base64"] != imagePayload {
		t.Fatalf("history media 应返回原始 base64")
	}
}

func TestAppServerHistoryImageRedactionRewritesDataURL(t *testing.T) {
	router := &Router{historyMedia: newAppServerHistoryMediaStore()}
	imagePayload := base64.StdEncoding.EncodeToString([]byte("image-bytes"))
	payload := []byte(`{"id":1,"result":{"data":[{"items":[{"content":[{"type":"image","url":"data:image/png;base64,` + imagePayload + `"}]}]}]}}`)

	rewritten, changed := router.redactInlineHistoryImagesInGatewayResponse(payload)
	if !changed {
		t.Fatalf("redaction 应识别 history data URL")
	}
	if bytes.Contains(rewritten, []byte(imagePayload)) || bytes.Contains(rewritten, []byte("data:image/png;base64")) {
		t.Fatalf("redaction 不应保留 inline base64：%s", rewritten)
	}
	if !bytes.Contains(rewritten, []byte(appServerHistoryMediaURLPrefix)) {
		t.Fatalf("redaction 应写入 history media URL：%s", rewritten)
	}
}

func TestAppServerGatewayForwardsSmallHistoryResponse(t *testing.T) {
	oldCap := appServerGatewayHistoryResponseCapBytes
	appServerGatewayHistoryResponseCapBytes = 1024
	t.Cleanup(func() {
		appServerGatewayHistoryResponseCapBytes = oldCap
	})

	var projectDir string
	smallResponse := []byte(`{"id":720,"result":{"data":[{"id":"turn-small"}]}}`)
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame appServerGatewayFrame
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("fake upstream 收到非法 JSON：%v", err)
			return
		}
		if frame.Method == "thread/list" {
			respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-small-history")
			return
		}
		if frame.Method == "thread/turns/list" {
			if err := conn.WriteMessage(websocket.TextMessage, smallResponse); err != nil {
				t.Errorf("fake upstream 写 small history 响应失败：%v", err)
			}
		}
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-small-history")

	request := []byte(`{"id":720,"method":"thread/turns/list","params":{"threadId":"thread-small-history","limit":20,"itemsView":"summary"}}`)
	if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
		t.Fatal(err)
	}
	_ = readUpstreamFrame(t, received)
	if got := readGatewayRaw(t, conn); !bytes.Equal(got, smallResponse) {
		t.Fatalf("小 history response 应原样返回：got=%s want=%s", got, smallResponse)
	}
}

func TestAppServerGatewayHistoryBudgetSeparatesItemsView(t *testing.T) {
	oldCap := appServerGatewayHistoryResponseCapBytes
	oldBudgetBytes := appServerGatewayHistoryBudgetMaxResponseBytes
	appServerGatewayHistoryResponseCapBytes = 512
	appServerGatewayHistoryBudgetMaxResponseBytes = 512
	t.Cleanup(func() {
		appServerGatewayHistoryResponseCapBytes = oldCap
		appServerGatewayHistoryBudgetMaxResponseBytes = oldBudgetBytes
	})

	var projectDir string
	smallSummaryResponse := []byte(`{"id":721,"result":{"data":[{"id":"turn-summary"}]}}`)
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame appServerGatewayFrame
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("fake upstream 收到非法 JSON：%v", err)
			return
		}
		if frame.Method == "thread/list" {
			respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-split-view")
			return
		}
		if frame.Method != "thread/turns/list" {
			return
		}
		params, err := decodeGatewayParams(frame.Params)
		if err != nil {
			t.Errorf("fake upstream 解析 params 失败：%v", err)
			return
		}
		itemsView, _ := gatewayStringParam(params, "itemsView")
		switch itemsView {
		case "full":
			padding := strings.Repeat("history-block-marker", 80)
			response := fmt.Sprintf(`{"id":%s,"result":{"data":[{"id":"turn-full","content":%q}]}}`, string(*frame.ID), padding)
			if err := conn.WriteMessage(websocket.TextMessage, []byte(response)); err != nil {
				t.Errorf("fake upstream 写 full 大响应失败：%v", err)
			}
		case "summary":
			if err := conn.WriteMessage(websocket.TextMessage, smallSummaryResponse); err != nil {
				t.Errorf("fake upstream 写 summary 小响应失败：%v", err)
			}
		default:
			t.Errorf("unexpected itemsView: %q", itemsView)
		}
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-split-view")

	fullRequest := []byte(`{"id":720,"method":"thread/turns/list","params":{"threadId":"thread-split-view","limit":20,"itemsView":"full"}}`)
	if err := conn.WriteMessage(websocket.TextMessage, fullRequest); err != nil {
		t.Fatal(err)
	}
	_ = readUpstreamFrame(t, received)
	fullErr := readGatewayError(t, conn)
	if !strings.Contains(fullErr.message, "history response 过大") {
		t.Fatalf("full 大响应应被 cap 阻断：%+v", fullErr)
	}
	if fullErr.data["itemsView"] != "full" {
		t.Fatalf("full cap error 应标记 itemsView=full：%+v", fullErr.data)
	}

	summaryRequest := []byte(`{"id":721,"method":"thread/turns/list","params":{"threadId":"thread-split-view","limit":20,"itemsView":"summary"}}`)
	if err := conn.WriteMessage(websocket.TextMessage, summaryRequest); err != nil {
		t.Fatal(err)
	}
	_ = readUpstreamFrame(t, received)
	if got := readGatewayRaw(t, conn); !bytes.Equal(got, smallSummaryResponse) {
		t.Fatalf("full 预算耗尽后 summary 应按独立预算透传：got=%s want=%s", got, smallSummaryResponse)
	}
}

func TestAppServerGatewayRejectsHistoryRetryStormByThreadMethod(t *testing.T) {
	oldWindow := appServerGatewayHistoryBudgetWindow
	oldMaxRequests := appServerGatewayHistoryBudgetMaxRequests
	oldRequestBytes := appServerGatewayHistoryBudgetMaxRequestBytes
	oldResponseBytes := appServerGatewayHistoryBudgetMaxResponseBytes
	appServerGatewayHistoryBudgetWindow = time.Minute
	appServerGatewayHistoryBudgetMaxRequests = 2
	appServerGatewayHistoryBudgetMaxRequestBytes = 64 << 10
	appServerGatewayHistoryBudgetMaxResponseBytes = 64 << 10
	t.Cleanup(func() {
		appServerGatewayHistoryBudgetWindow = oldWindow
		appServerGatewayHistoryBudgetMaxRequests = oldMaxRequests
		appServerGatewayHistoryBudgetMaxRequestBytes = oldRequestBytes
		appServerGatewayHistoryBudgetMaxResponseBytes = oldResponseBytes
	})

	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-retry")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-retry")

	for id := 730; id < 732; id++ {
		request := []byte(fmt.Sprintf(`{"id":%d,"method":"thread/turns/list","params":{"threadId":"thread-retry","limit":20,"itemsView":"summary","cursor":"page-%d"}}`, id, id))
		if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
			t.Fatal(err)
		}
		_ = readUpstreamFrame(t, received)
	}

	overflow := []byte(`{"id":732,"method":"thread/turns/list","params":{"threadId":"thread-retry","limit":20,"itemsView":"summary","cursor":"page-732"}}`)
	if err := conn.WriteMessage(websocket.TextMessage, overflow); err != nil {
		t.Fatal(err)
	}
	errFrame := readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "同一 thread/method 请求过于频繁") {
		t.Fatalf("重试风暴应被同 thread/method 频率预算拒绝：%+v", errFrame)
	}
	if errFrame.data["reason"] != "history_budget_limited" {
		t.Fatalf("重试风暴错误应包含 budget reason：%+v", errFrame.data)
	}
	if got := int(errFrame.data["retryAfterSeconds"].(float64)); got <= 0 {
		t.Fatalf("重试风暴错误应包含 retryAfterSeconds：%+v", errFrame.data)
	}
	assertNoUpstreamFrame(t, received)

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/diagnostics/relay", nil))
	body := decodeJSON(t, rec)
	gateway := body["app_server_gateway"].(map[string]any)
	if got := int(gateway["history_budget_rejections"].(float64)); got < 1 {
		t.Fatalf("diagnostics 应记录 history budget 阻断：%v", gateway)
	}
	if !containsAnySubstring(body["hints"].([]any), "限流") {
		t.Fatalf("diagnostics hints 应提示限流：%v", body["hints"])
	}
}

func TestAppServerGatewayRejectsHistoryRequestByteBudget(t *testing.T) {
	oldMaxRequests := appServerGatewayHistoryBudgetMaxRequests
	oldRequestBytes := appServerGatewayHistoryBudgetMaxRequestBytes
	appServerGatewayHistoryBudgetMaxRequests = 100
	appServerGatewayHistoryBudgetMaxRequestBytes = 64 << 10
	t.Cleanup(func() {
		appServerGatewayHistoryBudgetMaxRequests = oldMaxRequests
		appServerGatewayHistoryBudgetMaxRequestBytes = oldRequestBytes
	})

	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-byte-budget")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-byte-budget")
	appServerGatewayHistoryBudgetMaxRequestBytes = 160

	request := []byte(`{"id":740,"method":"thread/turns/list","params":{"threadId":"thread-byte-budget","limit":20,"itemsView":"summary","cursor":"` + strings.Repeat("x", 240) + `"}}`)
	if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
		t.Fatal(err)
	}
	errFrame := readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "请求字节预算") {
		t.Fatalf("history 请求字节预算应被拒绝：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayKeepsAuthorizedThreadAcrossReconnects(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-reconnect")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	first := dialAuthedGateway(t, server.URL)
	authorizeGatewayThread(t, first, received, projectDir, "thread-reconnect")
	_ = first.Close()

	second := dialAuthedGateway(t, server.URL)
	defer second.Close()

	turnFrame := []byte(fmt.Sprintf(
		`{"id":32,"method":"turn/start","params":{"threadId":"thread-reconnect","cwd":%q,"input":[{"type":"text","text":"after reconnect"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		projectDir,
		projectDir,
	))
	if err := second.WriteMessage(websocket.TextMessage, turnFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		params := decodeGatewayParamsForTest(t, got)
		if params["threadId"] != "thread-reconnect" ||
			params["cwd"] != projectDir ||
			params["effort"] != "xhigh" {
			t.Fatalf("重连后已授权 turn/start 必须补默认推理强度后转发：got=%s want-base=%s", got, turnFrame)
		}
		if _, ok := params["model"]; ok {
			t.Fatalf("重连 turn/start 不应补默认 model：got=%s", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到重连后的已授权 turn/start")
	}
}

func TestAppServerGatewayBindsBrowseWorkspaceToExactCWD(t *testing.T) {
	browseRoot := t.TempDir()
	financeDir := filepath.Join(browseRoot, "finance")
	documentsDir := filepath.Join(browseRoot, "Documents")
	for _, dir := range []string{financeDir, documentsDir} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	realFinanceDir, err := filepath.EvalSymlinks(financeDir)
	if err != nil {
		t.Fatal(err)
	}
	realDocumentsDir, err := filepath.EvalSymlinks(documentsDir)
	if err != nil {
		t.Fatal(err)
	}
	financeFile := filepath.Join(realFinanceDir, "report.csv")
	if err := os.WriteFile(financeFile, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	documentsFile := filepath.Join(realDocumentsDir, "note.md")
	if err := os.WriteFile(documentsFile, []byte("note"), 0o644); err != nil {
		t.Fatal(err)
	}

	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, realFinanceDir, "thread-browse")
	})
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.BrowseRoots = []string{browseRoot}
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	// browse_roots 内的目录可以作为 thread/list cwd 并授权线程。
	authorizeGatewayThread(t, conn, received, realFinanceDir, "thread-browse")

	turnFrame := []byte(fmt.Sprintf(
		`{"id":61,"method":"turn/start","params":{"threadId":"thread-browse","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		realFinanceDir,
		realFinanceDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, turnFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		params := decodeGatewayParamsForTest(t, got)
		if params["threadId"] != "thread-browse" ||
			params["cwd"] != realFinanceDir ||
			params["effort"] != "xhigh" {
			t.Fatalf("browse workspace 同 cwd 的 turn/start 应补默认推理强度后转发：got=%s want-base=%s", got, turnFrame)
		}
		if _, ok := params["model"]; ok {
			t.Fatalf("browse workspace turn/start 不应补默认 model：got=%s", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到 browse workspace 的 turn/start")
	}

	// 绑定目录内的结构化输入路径允许通过。
	mentionFrame := []byte(fmt.Sprintf(
		`{"id":62,"method":"turn/start","params":{"threadId":"thread-browse","cwd":%q,"input":[{"type":"mention","name":"report","path":%q}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		realFinanceDir,
		financeFile,
		realFinanceDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, mentionFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		params := decodeGatewayParamsForTest(t, got)
		if params["threadId"] != "thread-browse" ||
			params["cwd"] != realFinanceDir ||
			params["effort"] != "xhigh" {
			t.Fatalf("绑定目录内 mention 输入应补默认推理强度后转发：got=%s want-base=%s", got, mentionFrame)
		}
		if _, ok := params["model"]; ok {
			t.Fatalf("mention turn/start 不应补默认 model：got=%s", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到 mention turn/start")
	}

	// 同一 browse root 下的 sibling 目录：cwd 与输入路径都必须被拒。
	siblingTurn := []byte(fmt.Sprintf(
		`{"id":63,"method":"turn/start","params":{"threadId":"thread-browse","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		realDocumentsDir,
		realDocumentsDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, siblingTurn); err != nil {
		t.Fatal(err)
	}
	errFrame := readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "必须匹配已授权 thread 的工作区") {
		t.Fatalf("sibling 目录 turn/start 应被精确绑定拒绝：%+v", errFrame)
	}

	siblingMention := []byte(fmt.Sprintf(
		`{"id":64,"method":"turn/start","params":{"threadId":"thread-browse","cwd":%q,"input":[{"type":"mention","name":"note","path":%q}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		realFinanceDir,
		documentsFile,
		realFinanceDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, siblingMention); err != nil {
		t.Fatal(err)
	}
	errFrame = readGatewayError(t, conn)
	if !strings.Contains(errFrame.message, "turn/start.input path") {
		t.Fatalf("sibling 目录的输入路径应被拒绝：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)
}

func TestAppServerGatewayThreadCachePrunesExpiredEntries(t *testing.T) {
	router := &Router{gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	expiredAt := time.Now().Add(-appServerGatewayThreadCacheTTL - time.Second)
	router.gatewayThreads[gatewayThreadCacheKey("codex", "thread-expired")] = appServerGatewayAllowedThread{
		id:       "thread-expired",
		scopeID:  "demo",
		lastSeen: expiredAt,
	}

	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-fresh", scopeID: "demo"})

	if _, ok := router.gatewayThreads[gatewayThreadCacheKey("codex", "thread-expired")]; ok {
		t.Fatal("过期 gateway thread 授权应在写入新授权时被裁剪")
	}
	if _, ok := router.gatewayThread("codex", "thread-fresh"); !ok {
		t.Fatal("新写入的 gateway thread 授权不应被裁剪")
	}
}

func TestAppServerGatewayThreadCachePrunesOldestWhenFull(t *testing.T) {
	router := &Router{gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	baseSeen := time.Now().Add(-time.Hour)
	for i := 0; i < appServerGatewayThreadCacheMax; i++ {
		id := fmt.Sprintf("thread-%04d", i)
		router.gatewayThreads[gatewayThreadCacheKey("codex", id)] = appServerGatewayAllowedThread{
			id:       id,
			scopeID:  "demo",
			lastSeen: baseSeen.Add(time.Duration(i) * time.Second),
		}
	}

	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-new", scopeID: "demo"})

	if len(router.gatewayThreads) > appServerGatewayThreadCacheMax {
		t.Fatalf("gateway thread 授权缓存应有容量上限，got=%d max=%d", len(router.gatewayThreads), appServerGatewayThreadCacheMax)
	}
	if _, ok := router.gatewayThreads[gatewayThreadCacheKey("codex", "thread-0000")]; ok {
		t.Fatal("容量超限时应裁剪最久未使用的 gateway thread 授权")
	}
	if _, ok := router.gatewayThread("codex", "thread-new"); !ok {
		t.Fatal("新写入的 gateway thread 授权应保留")
	}
}

func TestAppServerGatewayObservesThreadResponseOnlyWithPendingRequest(t *testing.T) {
	_, registry, _, _, projectDir := appServerGatewayBaseFixture(t)
	router := &Router{
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := &appServerGatewayPolicy{
		router:                router,
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
	payload := []byte(fmt.Sprintf(
		`{"id":42,"result":{"data":[{"id":"thread-pending","cwd":%q}]}}`,
		projectDir,
	))

	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload); !forward || policyErr != nil {
		t.Fatalf("普通上游响应应继续转发：forward=%v err=%+v", forward, policyErr)
	}
	if _, ok := router.gatewayThread("codex", "thread-pending"); ok {
		t.Fatal("没有 pending thread 请求时，上游业务帧不应创建授权")
	}

	id := json.RawMessage("42")
	if err := policy.rememberPendingThreadResponse(&id, "thread/list", projectDir, "demo"); err != nil {
		t.Fatal(err)
	}
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload); !forward || policyErr != nil {
		t.Fatalf("thread/list 响应应继续转发：forward=%v err=%+v", forward, policyErr)
	}
	if _, ok := router.gatewayThread("codex", "thread-pending"); !ok {
		t.Fatal("存在 pending thread 请求时，上游响应仍必须创建授权")
	}
}

func authorizeGatewayThread(t *testing.T, conn *websocket.Conn, received <-chan []byte, projectDir string, threadID string) {
	t.Helper()
	listFrame := []byte(fmt.Sprintf(
		`{"id":30,"method":"thread/list","params":{"cwd":%q,"limit":20}}`,
		projectDir,
	))
	if err := conn.WriteMessage(websocket.TextMessage, listFrame); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if !bytes.Equal(got, listFrame) {
			t.Fatalf("thread/list 授权请求必须原样转发：got=%s want=%s", got, listFrame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到 thread/list 授权请求")
	}
	raw := readGatewayRaw(t, conn)
	if !bytes.Contains(raw, []byte(threadID)) {
		t.Fatalf("thread/list 授权响应应包含 thread id %s：%s", threadID, raw)
	}
}

func respondToThreadListAuthorization(t *testing.T, conn *websocket.Conn, payload []byte, projectDir string, threadID string) {
	t.Helper()
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		t.Errorf("fake upstream 收到非法 JSON：%v", err)
		return
	}
	if frame.Method != "thread/list" {
		return
	}
	response := fmt.Sprintf(
		`{"id":%s,"result":{"data":[{"id":%q,"cwd":%q}]}}`,
		string(*frame.ID),
		threadID,
		projectDir,
	)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(response)); err != nil {
		t.Errorf("fake upstream 写 thread/list 响应失败：%v", err)
	}
}

func appServerGatewayRouterFixture(t *testing.T, upstreamURL string) (http.Handler, string) {
	t.Helper()
	return appServerGatewayRouterFixtureWithConfig(t, upstreamURL, nil)
}

func appServerGatewayRouterFixtureWithTokenFile(t *testing.T, upstreamURL string, token string) (http.Handler, string) {
	t.Helper()
	tokenFile := filepath.Join(t.TempDir(), "app-server-token")
	if err := os.WriteFile(tokenFile, []byte(token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.WSTokenFile = tokenFile
	})
}

func appServerGatewayRouterFixtureWithConfig(t *testing.T, upstreamURL string, customize func(*config.Config)) (http.Handler, string) {
	t.Helper()
	cfg, registry, manager, checker, projectDir := appServerGatewayBaseFixture(t)
	cfg.AppServer = config.AppServerConfig{
		Transport:   "ws",
		Managed:     true,
		Listen:      upstreamURL,
		WSTokenFile: testAppServerTokenFile(t, "test-upstream-token"),
	}
	if customize != nil {
		customize(&cfg)
	}
	return NewRouterWithRuntime(cfg, registry, manager, checker, "test", nil), projectDir
}

func testAppServerTokenFile(t *testing.T, token string) string {
	t.Helper()
	tokenFile := filepath.Join(t.TempDir(), "app-server-token")
	if err := os.WriteFile(tokenFile, []byte(token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return tokenFile
}

func appServerGatewayBaseFixture(t *testing.T) (config.Config, *projects.Registry, *session.Manager, *doctor.Checker, string) {
	t.Helper()
	projectDir := t.TempDir()
	cfg := config.Config{
		Listen: "127.0.0.1:0",
		Auth:   config.AuthConfig{Token: testToken},
		Codex: config.CodexConfig{
			Bin: "/bin/cat",
			Env: map[string]string{"TERM": "xterm-256color"},
		},
		Session: config.SessionConfig{OutputBufferBytes: 8 * 1024},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: projectDir,
		}},
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	manager := session.NewManager(session.Options{
		CodexBin:     cfg.Codex.Bin,
		DefaultArgs:  cfg.Codex.DefaultArgs,
		Env:          cfg.Codex.Env,
		OutputBuffer: cfg.Session.OutputBufferBytes,
	})
	t.Cleanup(manager.Shutdown)
	checker := doctor.NewChecker("test", cfg, registry)
	return cfg, registry, manager, checker, projectDir
}

func fakeAppServerUpstream(t *testing.T, onFrame func(conn *websocket.Conn, messageType int, payload []byte)) (string, <-chan []byte, *atomic.Int64) {
	t.Helper()
	return fakeAppServerUpstreamWithAuth(t, "", onFrame)
}

func fakeAppServerUpstreamWithAuth(t *testing.T, expectedToken string, onFrame func(conn *websocket.Conn, messageType int, payload []byte)) (string, <-chan []byte, *atomic.Int64) {
	t.Helper()
	received := make(chan []byte, 8)
	var connections atomic.Int64
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		connections.Add(1)
		if expectedToken != "" && req.Header.Get("Authorization") != "Bearer "+expectedToken {
			http.Error(w, "missing upstream token", http.StatusUnauthorized)
			return
		}
		conn, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			messageType, payload, err := conn.ReadMessage()
			if err != nil {
				return
			}
			received <- append([]byte(nil), payload...)
			if onFrame != nil {
				onFrame(conn, messageType, payload)
			}
		}
	}))
	t.Cleanup(server.Close)
	return wsURL(server.URL, "/"), received, &connections
}

func wsURL(serverURL string, path string) string {
	parsed, err := url.Parse(serverURL)
	if err != nil {
		return serverURL
	}
	switch parsed.Scheme {
	case "https":
		parsed.Scheme = "wss"
	default:
		parsed.Scheme = "ws"
	}
	parsed.Path = path
	return parsed.String()
}

func dialAuthedGateway(t *testing.T, serverURL string) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.DefaultDialer.Dial(wsURL(serverURL, appServerGatewayPath), http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

func dialAuthedGatewayRuntime(t *testing.T, serverURL string, runtimeID string) *websocket.Conn {
	t.Helper()
	target := wsURL(serverURL, appServerGatewayPath)
	if strings.TrimSpace(runtimeID) != "" {
		target += "?runtime=" + url.QueryEscape(runtimeID)
	}
	conn, _, err := websocket.DefaultDialer.Dial(target, http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

func writeTestBridge(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fake-claude-bridge")
	const shebang = "#!/bin/sh\n"
	if strings.HasPrefix(body, shebang) {
		body = strings.TrimPrefix(body, shebang)
	}
	body = shebang + `if [ "${1:-}" = "--version" ]; then
  printf 'alleycat-claude-bridge 0.2.1\n'
  exit 0
fi
` + body
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

type gatewayErrorFrame struct {
	id      json.RawMessage
	message string
	data    map[string]any
}

func readGatewayError(t *testing.T, conn *websocket.Conn) gatewayErrorFrame {
	t.Helper()
	raw := readGatewayRaw(t, conn)
	var frame struct {
		ID    json.RawMessage `json:"id"`
		Error struct {
			Code    int            `json:"code"`
			Message string         `json:"message"`
			Data    map[string]any `json:"data"`
		} `json:"error"`
	}
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatalf("gateway error 不是合法 JSON：%v raw=%s", err, raw)
	}
	if frame.Error.Code != appServerPolicyErrorCode || frame.Error.Message == "" {
		t.Fatalf("gateway error code/message 异常：%+v raw=%s", frame, raw)
	}
	return gatewayErrorFrame{id: frame.ID, message: frame.Error.Message, data: frame.Error.Data}
}

func readUpstreamFrame(t *testing.T, received <-chan []byte) []byte {
	t.Helper()
	select {
	case payload := <-received:
		return payload
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到帧")
	}
	return nil
}

func readTestFileEventually(t *testing.T, path string) []byte {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(path)
		if err == nil && len(bytes.TrimSpace(raw)) > 0 {
			return raw
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("等待测试文件写入超时：%s", path)
	return nil
}

func readTestFileLineEventually(t *testing.T, path string, needle string) []byte {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(path)
		if err == nil {
			for _, line := range bytes.Split(raw, []byte("\n")) {
				if bytes.Contains(line, []byte(needle)) {
					return append([]byte(nil), line...)
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("等待测试文件出现 %q 超时：%s", needle, path)
	return nil
}

func parseTestPID(t *testing.T, raw string) int {
	t.Helper()
	pid, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || pid <= 0 {
		t.Fatalf("测试 PID 无效：raw=%q err=%v", raw, err)
	}
	return pid
}

func waitForProcessExit(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		err := syscall.Kill(pid, 0)
		if err == syscall.ESRCH {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("进程组关闭后子进程仍在运行 pid=%d", pid)
}

func decodeGatewayParamsForTest(t *testing.T, payload []byte) map[string]any {
	t.Helper()
	var frame struct {
		Params map[string]any `json:"params"`
	}
	if err := json.Unmarshal(payload, &frame); err != nil {
		t.Fatalf("gateway frame 不是合法 JSON：%v raw=%s", err, payload)
	}
	if frame.Params == nil {
		t.Fatalf("gateway frame 缺少 params：%s", payload)
	}
	return frame.Params
}

func mustRawMessageForGatewayTest(t *testing.T, value any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func decodeGatewayResultForTest(t *testing.T, payload []byte) map[string]any {
	t.Helper()
	var frame struct {
		Result map[string]any `json:"result"`
	}
	if err := json.Unmarshal(payload, &frame); err != nil {
		t.Fatalf("gateway frame 不是合法 JSON：%v raw=%s", err, payload)
	}
	if frame.Result == nil {
		t.Fatalf("gateway frame 缺少 result：%s", payload)
	}
	return frame.Result
}

func containsAnyString(values []any, want string) bool {
	for _, value := range values {
		if got, ok := value.(string); ok && got == want {
			return true
		}
	}
	return false
}

func containsAnySubstring(values []any, want string) bool {
	for _, value := range values {
		if got, ok := value.(string); ok && strings.Contains(got, want) {
			return true
		}
	}
	return false
}

func assertGatewayParamAbsent(t *testing.T, params map[string]any, keys ...string) {
	t.Helper()
	for _, key := range keys {
		if _, exists := params[key]; exists {
			t.Fatalf("gateway 不应透传参数 %s：%v", key, params)
		}
	}
}

func assertGatewayParamsOnly(t *testing.T, params map[string]any, allowedKeys ...string) {
	t.Helper()
	allowed := map[string]struct{}{}
	for _, key := range allowedKeys {
		allowed[key] = struct{}{}
	}
	for key := range params {
		if _, ok := allowed[key]; !ok {
			t.Fatalf("gateway method 参数白名单不应包含 %s：%v", key, params)
		}
	}
	for _, key := range allowedKeys {
		if _, ok := params[key]; !ok {
			t.Fatalf("gateway method 参数白名单应保留 %s：%v", key, params)
		}
	}
}

func readGatewayRaw(t *testing.T, conn *websocket.Conn) []byte {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	messageType, payload, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if messageType != websocket.TextMessage {
		t.Fatalf("期望 text message，got=%d payload=%s", messageType, payload)
	}
	return payload
}

func assertNoUpstreamFrame(t *testing.T, received <-chan []byte) {
	t.Helper()
	select {
	case payload := <-received:
		t.Fatalf("非法帧不应转发到 upstream：%s", payload)
	case <-time.After(150 * time.Millisecond):
	}
}

func truncateForLog(raw []byte) string {
	if len(raw) > 512 {
		return string(raw[:512]) + "…"
	}
	return string(raw)
}
