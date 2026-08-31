package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func TestAppServerGatewayForkSupportsLastTurnAndPreservedPermissions(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-fork")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-fork")

	writeJSON := func(frame map[string]any) {
		t.Helper()
		payload, err := json.Marshal(frame)
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
			t.Fatal(err)
		}
	}

	writeJSON(map[string]any{
		"id":     20801,
		"method": "thread/fork",
		"params": map[string]any{
			"threadId":                            "thread-fork",
			"cwd":                                 projectDir,
			"lastTurnId":                          "turn-completed",
			gatewayPreserveThreadPermissionsParam: true,
		},
	})
	params := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
	assertGatewayParamsOnly(t, params, "threadId", "cwd", "lastTurnId")
	if params["threadId"] != "thread-fork" || params["cwd"] != projectDir || params["lastTurnId"] != "turn-completed" {
		t.Fatalf("thread/fork 应保留授权 Thread、工作区和结束轮次：%v", params)
	}
	for _, key := range []string{"approvalPolicy", "approvalsReviewer", "permissions", "sandbox", "sandboxPolicy", gatewayPreserveThreadPermissionsParam} {
		if _, exists := params[key]; exists {
			t.Fatalf("thread/fork 权限继承模式不得上传 %s：%v", key, params)
		}
	}

	invalidLastTurnIDs := []any{"", "   ", nil, 42, true, []any{"turn-completed"}}
	for index, lastTurnID := range invalidLastTurnIDs {
		writeJSON(map[string]any{
			"id":     20810 + index,
			"method": "thread/fork",
			"params": map[string]any{
				"threadId":   "thread-fork",
				"cwd":        projectDir,
				"lastTurnId": lastTurnID,
			},
		})
		if errFrame := readGatewayError(t, conn); !strings.Contains(errFrame.message, "lastTurnId 必须是非空字符串") {
			t.Fatalf("thread/fork 非法 lastTurnId 应被拒绝：value=%v error=%+v", lastTurnID, errFrame)
		}
		assertNoUpstreamFrame(t, received)
	}

	overrides := map[string]any{
		"approvalPolicy":    "on-request",
		"approvalsReviewer": "user",
		"permissions":       ":workspace",
		"sandbox":           "workspace-write",
		"sandboxPolicy":     map[string]any{"type": "workspaceWrite"},
	}
	requestID := 20830
	for key, value := range overrides {
		writeJSON(map[string]any{
			"id":     requestID,
			"method": "thread/fork",
			"params": map[string]any{
				"threadId":                            "thread-fork",
				"cwd":                                 projectDir,
				gatewayPreserveThreadPermissionsParam: true,
				key:                                   value,
			},
		})
		requestID++
		if errFrame := readGatewayError(t, conn); !strings.Contains(errFrame.message, fmt.Sprintf("不能与 %s 同时发送", key)) {
			t.Fatalf("thread/fork 权限继承模式应拒绝 %s 覆盖：%+v", key, errFrame)
		}
		assertNoUpstreamFrame(t, received)
	}

	writeJSON(map[string]any{
		"id":     20840,
		"method": "thread/read",
		"params": map[string]any{
			"threadId":     "thread-fork",
			"includeTurns": true,
			"lastTurnId":   "must-not-forward",
		},
	})
	readParams := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
	assertGatewayParamsOnly(t, readParams, "threadId", "includeTurns")
	if _, exists := readParams["lastTurnId"]; exists {
		t.Fatalf("非 thread/fork 方法不得透传 lastTurnId：%v", readParams)
	}
}
