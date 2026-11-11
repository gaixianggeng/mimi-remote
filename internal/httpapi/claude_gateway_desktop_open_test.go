package httpapi

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gorilla/websocket"
)

// #726：thread/desktop/open 只在适配器声明时开放。旧 Rust bridge 的版本再新也没有这个方法，
// 适配器在 Windows / Linux 上也不声明。
func TestAppServerConfigDeclaresClaudeDesktopOpenOnlyWhenAdapterDeclaresIt(t *testing.T) {
	cases := []struct {
		name   string
		bridge func(t *testing.T) string
		want   bool
	}{
		{name: "adapter on macOS", want: true, bridge: func(t *testing.T) string {
			return writeTestAdapterBridge(t, `{"name":"mimi-claude-adapter","version":"0.3.0","methods":["initialize","thread/list","thread/read","thread/desktop/open"],"fullAccess":true}`)
		}},
		{name: "adapter elsewhere", want: false, bridge: func(t *testing.T) string {
			return writeTestAdapterBridge(t, `{"name":"mimi-claude-adapter","version":"0.3.0","methods":["initialize","thread/list","thread/read"],"fullAccess":true}`)
		}},
		{name: "legacy bridge", want: false, bridge: func(t *testing.T) string {
			return writeTestBridgeWithVersion(t, "alleycat-claude-bridge 0.2.14")
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bridgePath := tc.bridge(t)
			upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
			handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
				cfg.Claude.Enabled = true
				cfg.Claude.BridgeBin = bridgePath
			})
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/config", nil))
			claude := decodeJSON(t, rec)["channels"].([]any)[1].(map[string]any)
			methods := claude["methods"].([]any)
			if got := containsAnyString(methods, "thread/desktop/open"); got != tc.want {
				t.Fatalf("channel 声明 thread/desktop/open=%t，期望 %t：%v", got, tc.want, methods)
			}
			if !containsAnyString(methods, "thread/list") {
				t.Fatalf("其余 Claude 方法不应受影响：%v", methods)
			}
		})
	}
}

// 桌面版已经持有的会话在本连接里是 canAcceptDirectInput=false，再打开只是切到前台，所以不套
// 只读拒写；但线程授权不能省，参数也只透传 threadId。
func TestClaudeGatewayDesktopOpenKeepsThreadAuthorizationAndStripsParams(t *testing.T) {
	receivedPath := filepath.Join(t.TempDir(), "received.jsonl")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
while IFS= read -r line; do
  printf '%%s\n' "$line" >> %q
  case "$line" in
  *'"method":"thread/list"'*)
    printf '{"jsonrpc":"2.0","id":91,"result":{"data":[{"id":"thr-held","canAcceptDirectInput":false,"claudeOwner":{"entrypoint":"claude-desktop","kind":"interactive","status":"idle","pid":4242}}]}}\n'
    ;;
  *'"method":"thread/desktop/open"'*)
    printf '{"jsonrpc":"2.0","id":93,"result":{"opened":true,"titleWritten":false,"alreadyInDesktop":true,"desktopVersion":"2.37337.1"}}\n'
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
	listPayload := fmt.Sprintf(`{"id":91,"method":"thread/list","params":{"cwd":%q}}`, projectDir)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(listPayload)); err != nil {
		t.Fatal(err)
	}
	readGatewayRaw(t, conn)

	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"id":92,"method":"thread/desktop/open","params":{"threadId":"thr-stranger"}}`)); err != nil {
		t.Fatal(err)
	}
	if got := readGatewayError(t, conn); !strings.Contains(got.message, "threadId 未由当前 gateway 连接授权") {
		t.Fatalf("未授权线程不能在桌面版打开：%+v", got)
	}

	openPayload := fmt.Sprintf(`{"id":93,"method":"thread/desktop/open","params":{"threadId":"thr-held","cwd":%q,"url":"claude://evil","name":"smuggled"}}`, projectDir)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(openPayload)); err != nil {
		t.Fatal(err)
	}
	openFrame := readTestFileLineEventually(t, receivedPath, `"thread/desktop/open"`)
	params := decodeGatewayParamsForTest(t, openFrame)
	assertGatewayParamsOnly(t, params, "threadId")
	if params["threadId"] != "thr-held" {
		t.Fatalf("thread/desktop/open 只应透传 threadId：%s", openFrame)
	}
	if response := readGatewayRaw(t, conn); !bytes.Contains(response, []byte(`"alreadyInDesktop":true`)) {
		t.Fatalf("打开结果应原样回流客户端：%s", response)
	}
}

func TestClaudeGatewayDesktopOpenRejectsReadOnlyThreads(t *testing.T) {
	policy := newAppServerGatewayPolicy(nil, appServerRuntimeClaudeID)
	policy.allowedThreads["thr-sub"] = appServerGatewayAllowedThread{
		id: "thr-sub", runtimeID: appServerRuntimeClaudeID, scopeID: "scope", readOnly: true, directInputKnown: true,
	}
	err := policy.validateThreadCapability(&appServerGatewayFrame{}, "thread/desktop/open", map[string]any{"threadId": "thr-sub"}, appServerGatewayValidatedParams{})
	if err == nil || !strings.Contains(err.Error(), "只读子会话") {
		t.Fatalf("子会话 / 浏览线程不能在桌面版打开：%v", err)
	}
	if err := policy.validateThreadCapability(&appServerGatewayFrame{}, "thread/desktop/open", map[string]any{}, appServerGatewayValidatedParams{}); err == nil {
		t.Fatal("缺少 threadId 必须拒绝")
	}
}
