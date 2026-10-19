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

// #765：Claude 输入框 `/` 菜单的命令目录。cwd 必须来自授权工作区；sandboxPolicy 只用来选目录，
// 转发时只保留 type，其余字段一律丢弃。
func TestClaudeGatewaySlashCommandListBindsAuthorizedWorkspace(t *testing.T) {
	receivedPath := filepath.Join(t.TempDir(), "received.jsonl")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
while IFS= read -r line; do
  printf '%%s\n' "$line" >> %q
  case "$line" in
  *'"method":"slashCommand/list"'*)
    printf '{"jsonrpc":"2.0","id":91,"result":{"data":[{"name":"compact","description":"Free up context","argumentHint":"<instructions>","aliases":[]}]}}\n'
    ;;
  esac
done
`, receivedPath))
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer conn.Close()
	request := fmt.Sprintf(
		`{"id":91,"method":"slashCommand/list","params":{"cwd":%q,"sandboxPolicy":{"type":"danger-full-access","writableRoots":[%q]},"forceReload":true,"threadId":"smuggled"}}`,
		projectDir, projectDir,
	)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(request)); err != nil {
		t.Fatal(err)
	}
	forwarded := decodeGatewayParamsForTest(t, readTestFileLineEventually(t, receivedPath, `"slashCommand/list"`))
	assertGatewayParamsOnly(t, forwarded, "cwd", "sandboxPolicy", "forceReload")
	policy, _ := forwarded["sandboxPolicy"].(map[string]any)
	if forwarded["cwd"] != projectDir || forwarded["forceReload"] != true || len(policy) != 1 || policy["type"] != "dangerFullAccess" {
		t.Fatalf("slashCommand/list 只应转发授权 cwd、规范化的执行边界类型与刷新标记：%v", forwarded)
	}
	if response := readGatewayRaw(t, conn); !bytes.Contains(response, []byte(`"name":"compact"`)) {
		t.Fatalf("命令目录应原样回流客户端：%s", response)
	}

	outside := t.TempDir()
	rejected := []struct {
		params string
		want   string
	}{
		{params: `{}`, want: "slashCommand/list.cwd 必须来自 projects allowlist"},
		{params: fmt.Sprintf(`{"cwd":%q}`, outside), want: "slashCommand/list.cwd 必须来自 projects allowlist"},
		{params: fmt.Sprintf(`{"cwd":%q,"sandboxPolicy":{"type":"externalSandbox"}}`, projectDir), want: "sandboxPolicy.type"},
		{params: fmt.Sprintf(`{"cwd":%q,"sandboxPolicy":"dangerFullAccess"}`, projectDir), want: "sandboxPolicy.type"},
		{params: fmt.Sprintf(`{"cwd":%q,"forceReload":"yes"}`, projectDir), want: "forceReload 必须是布尔值"},
		{params: fmt.Sprintf(`{"cwd":%q,"sandboxPolicy":{"type":"workspaceWrite","networkAccess":true}}`, projectDir), want: "networkAccess=true"},
	}
	for index, tc := range rejected {
		payload := fmt.Sprintf(`{"id":%d,"method":"slashCommand/list","params":%s}`, 92+index, tc.params)
		if err := conn.WriteMessage(websocket.TextMessage, []byte(payload)); err != nil {
			t.Fatal(err)
		}
		if got := readGatewayError(t, conn); !strings.Contains(got.message, tc.want) {
			t.Fatalf("%s 应被拒（%s）：%+v", tc.params, tc.want, got)
		}
	}
}

// 方法只在 Claude 登记表里：Codex 连接不能借它扫描目录。
func TestCodexGatewayRejectsSlashCommandList(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	payload := fmt.Sprintf(`{"id":101,"method":"slashCommand/list","params":{"cwd":%q}}`, projectDir)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(payload)); err != nil {
		t.Fatal(err)
	}
	if got := readGatewayError(t, conn); !strings.Contains(got.message, "app-server method 不允许：slashCommand/list") {
		t.Fatalf("Codex 通道不应开放 slashCommand/list：%+v", got)
	}
}

// 旧 Rust bridge 没有这个方法；适配器也只在自己声明时开放，iOS 据 channel methods 决定是否请求。
func TestAppServerConfigDeclaresSlashCommandListOnlyForAdapterThatSupportsIt(t *testing.T) {
	cases := []struct {
		name   string
		bridge func(t *testing.T) string
		want   bool
	}{
		{name: "legacy bridge", bridge: func(t *testing.T) string { return writeTestBridgeWithVersion(t, "alleycat-claude-bridge 0.2.14") }, want: false},
		{name: "adapter without declaration", bridge: func(t *testing.T) string {
			return writeTestAdapterBridge(t, `{"methods":["initialize","thread/list","turn/start"],"fullAccess":true}`)
		}, want: false},
		{name: "adapter with declaration", bridge: func(t *testing.T) string {
			return writeTestAdapterBridge(t, `{"methods":["initialize","thread/list","turn/start","slashCommand/list"],"fullAccess":true}`)
		}, want: true},
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
			if got := containsAnyString(methods, "slashCommand/list"); got != tc.want {
				t.Fatalf("channel 声明 slashCommand/list=%t，期望 %t：%v", got, tc.want, methods)
			}
			if !containsAnyString(methods, "turn/start") {
				t.Fatalf("其余 Claude 方法不应受影响：%v", methods)
			}
		})
	}
}
