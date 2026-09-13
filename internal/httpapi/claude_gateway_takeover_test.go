package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gorilla/websocket"
)

// #451：thread/takeover 只对 0.2.11 起的 bridge 声明；旧 bridge 会回 method not found，
// iOS 据 channel methods 决定是否显示"在此设备上接管"。
func TestAppServerConfigDeclaresClaudeTakeoverOnlyForBridgeThatSupportsIt(t *testing.T) {
	cases := []struct {
		version string
		want    bool
	}{
		{version: "alleycat-claude-bridge 0.2.11", want: true},
		{version: "alleycat-claude-bridge 0.2.10", want: false},
	}
	for _, tc := range cases {
		bridgePath := writeTestBridgeWithVersion(t, tc.version)
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
			t.Fatalf("%s 满足最低版本，gateway 应可用：%v", tc.version, claude)
		}
		methods := claude["methods"].([]any)
		if got := containsAnyString(methods, "thread/takeover"); got != tc.want {
			t.Fatalf("%s 的 channel 声明 thread/takeover=%t，期望 %t：%v", tc.version, got, tc.want, methods)
		}
		if !containsAnyString(methods, "thread/resume") || !containsAnyString(methods, "turn/start") {
			t.Fatalf("其余 Claude 方法不应受影响：%v", methods)
		}
	}
}

// #451：被 Mac 上的 claude 持有的会话在本连接里是 canAcceptDirectInput=false。turn/start 必须
// 继续被拒，但 thread/takeover 恰恰是为这类会话准备的：只查线程授权和工作区绑定，不套只读
// 拒写；参数只透传 threadId / cwd；bridge 回 canAcceptDirectInput=true 后同一连接立刻可写。
func TestClaudeGatewayTakeoverSkipsReadOnlyGateButKeepsThreadAuthorization(t *testing.T) {
	receivedPath := filepath.Join(t.TempDir(), "received.jsonl")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
while IFS= read -r line; do
  printf '%%s\n' "$line" >> %q
  case "$line" in
  *'"method":"thread/list"'*)
    printf '{"jsonrpc":"2.0","id":81,"result":{"data":[{"id":"thr-held","canAcceptDirectInput":false,"claudeOwner":{"entrypoint":"cli","kind":"interactive","status":"busy","pid":4242}}]}}\n'
    ;;
  *'"method":"thread/takeover"'*)
    printf '{"jsonrpc":"2.0","id":84,"result":{"thread":{"id":"thr-held","canAcceptDirectInput":true},"model":"claude-opus-5","modelProvider":"anthropic","takeover":{"released":true,"holder":{"entrypoint":"cli","pid":4242},"signal":"SIGINT"}}}\n'
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
	listPayload := fmt.Sprintf(`{"id":81,"method":"thread/list","params":{"cwd":%q}}`, projectDir)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(listPayload)); err != nil {
		t.Fatal(err)
	}
	listResponse := readGatewayRaw(t, conn)
	if !bytes.Contains(listResponse, []byte(`"claudeOwner"`)) {
		t.Fatalf("thread/list 响应应带回持有方摘要：%s", listResponse)
	}

	turnPayload := fmt.Sprintf(
		`{"id":82,"method":"turn/start","params":{"threadId":"thr-held","cwd":%q,"input":[{"type":"text","text":"hi"}],"approvalPolicy":"on-request"}}`,
		projectDir,
	)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(turnPayload)); err != nil {
		t.Fatal(err)
	}
	if got := readGatewayError(t, conn); !strings.Contains(got.message, "不能接受直接输入") {
		t.Fatalf("被别处持有的会话 turn/start 仍应被拒：%+v", got)
	}

	strangerPayload := fmt.Sprintf(`{"id":83,"method":"thread/takeover","params":{"threadId":"thr-stranger","cwd":%q}}`, projectDir)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(strangerPayload)); err != nil {
		t.Fatal(err)
	}
	if got := readGatewayError(t, conn); !strings.Contains(got.message, "threadId 未由当前 gateway 连接授权") {
		t.Fatalf("未授权线程不能接管：%+v", got)
	}

	takeoverPayload := fmt.Sprintf(
		`{"id":84,"method":"thread/takeover","params":{"threadId":"thr-held","cwd":%q,"sandbox":"danger-full-access","input":[{"type":"text","text":"smuggled"}],"excludeTurns":false}}`,
		projectDir,
	)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(takeoverPayload)); err != nil {
		t.Fatal(err)
	}
	takeoverFrame := readTestFileLineEventually(t, receivedPath, `"thread/takeover"`)
	takeoverParams := decodeGatewayParamsForTest(t, takeoverFrame)
	assertGatewayParamsOnly(t, takeoverParams, "threadId", "cwd", "excludeTurns")
	if takeoverParams["threadId"] != "thr-held" || takeoverParams["cwd"] != projectDir || takeoverParams["excludeTurns"] != true {
		t.Fatalf("thread/takeover 只应透传 threadId / cwd 并强制 excludeTurns：%s", takeoverFrame)
	}
	takeoverResponse := readGatewayRaw(t, conn)
	if !bytes.Contains(takeoverResponse, []byte(`"released":true`)) ||
		!bytes.Contains(takeoverResponse, []byte(`"canAcceptDirectInput":true`)) {
		t.Fatalf("接管响应应原样回流客户端：%s", takeoverResponse)
	}

	// 响应里的 canAcceptDirectInput=true 必须覆盖本连接缓存的 false。
	if err := conn.WriteMessage(websocket.TextMessage, []byte(strings.Replace(turnPayload, `"id":82`, `"id":85`, 1))); err != nil {
		t.Fatal(err)
	}
	turnFrame := readTestFileLineEventually(t, receivedPath, `"turn/start"`)
	if !bytes.Contains(turnFrame, []byte(`"id":85`)) {
		t.Fatalf("接管后的 turn/start 应转发给 bridge：%s", turnFrame)
	}
}

// 接管会结束用户 Mac 上的一个进程，gateway 留一条审计日志；但只允许出现脱敏 thread token
// 和工作区 basename。
func TestGatewayTakeoverSummaryLogRedactsThreadIDAndPath(t *testing.T) {
	var buf bytes.Buffer
	previousOutput := log.Writer()
	previousFlags := log.Flags()
	previousPrefix := log.Prefix()
	log.SetOutput(&buf)
	log.SetFlags(0)
	log.SetPrefix("")
	t.Cleanup(func() {
		log.SetOutput(previousOutput)
		log.SetFlags(previousFlags)
		log.SetPrefix(previousPrefix)
	})

	params := map[string]any{
		"threadId":     "thread-takeover-secret-id-value",
		"cwd":          "/private/secret/takeover-repo",
		"excludeTurns": true,
	}
	frame := appServerGatewayFrame{Method: "thread/takeover", Params: mustRawMessageForGatewayTest(t, params)}
	payload, err := json.Marshal(frame)
	if err != nil {
		t.Fatal(err)
	}
	logGatewayForwardedClientTurnSummary("thread/takeover", payload)
	got := buf.String()
	if !strings.Contains(got, "forwarded takeover") || !strings.Contains(got, "threadId=thread-t...alue") {
		t.Fatalf("接管日志应带脱敏 thread token：%s", got)
	}
	if strings.Contains(got, "thread-takeover-secret-id-value") || strings.Contains(got, "/private/secret") {
		t.Fatalf("接管日志不应泄漏完整 thread id 或路径：%s", got)
	}
	if !strings.Contains(got, "cwdBase=takeover-repo") {
		t.Fatalf("接管日志应只保留工作区 basename：%s", got)
	}
}
