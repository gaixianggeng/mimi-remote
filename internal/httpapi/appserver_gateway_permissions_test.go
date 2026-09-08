package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func TestAppServerGatewayUpdatesThreadPermissions(t *testing.T) {
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		respondToThreadListAuthorization(t, conn, payload, projectDir, "thread-permissions")
	})
	handler, dir := appServerGatewayRouterFixture(t, upstreamURL)
	projectDir = dir
	server := httptest.NewServer(handler)
	defer server.Close()
	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	authorizeGatewayThread(t, conn, received, projectDir, "thread-permissions")

	cases := []struct {
		name     string
		policy   string
		reviewer string
		sandbox  string
		profile  string
	}{
		{"request approval", "on-request", "user", "workspaceWrite", ""},
		{"read only", "on-request", "user", "readOnly", ""},
		{"auto review", "on-request", "auto_review", "workspaceWrite", ""},
		{"full access", "never", "user", "dangerFullAccess", ""},
		{"named profile", "on-request", "user", "", "project-restricted"},
		{"full access profile", "never", "user", "", ":danger-full-access"},
	}
	for index, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			params := map[string]any{
				"threadId": "thread-permissions", "cwd": projectDir,
				"approvalPolicy": tc.policy, "approvalsReviewer": tc.reviewer,
			}
			if tc.profile != "" {
				params["permissions"] = tc.profile
			} else {
				sandbox := map[string]any{"type": tc.sandbox, "networkAccess": false}
				if tc.sandbox == "workspaceWrite" {
					sandbox["writableRoots"] = []any{projectDir}
				}
				params["sandboxPolicy"] = sandbox
			}
			request, err := json.Marshal(map[string]any{
				"id": 4010 + index, "method": "thread/settings/update", "params": params,
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
				t.Fatal(err)
			}
			forwarded := decodeGatewayParamsForTest(t, readUpstreamFrame(t, received))
			if !reflect.DeepEqual(forwarded, params) {
				t.Fatalf("明确选择的线程权限必须到达上游：got=%v want=%v", forwarded, params)
			}
		})
	}

	// 允许 settings/update 显式完全访问，不能同时放开其他无审批组合。
	for index, override := range []map[string]any{
		{},
		{"sandboxPolicy": map[string]any{"type": "workspaceWrite", "networkAccess": false}},
		{"permissions": "project-restricted"},
	} {
		params := map[string]any{
			"threadId": "thread-permissions", "cwd": projectDir,
			"approvalPolicy": "never", "approvalsReviewer": "user",
		}
		for key, value := range override {
			params[key] = value
		}
		request, err := json.Marshal(map[string]any{
			"id": 4020 + index, "method": "thread/settings/update", "params": params,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
			t.Fatal(err)
		}
		if failure := readGatewayError(t, conn); !strings.Contains(failure.message, "never") {
			t.Fatalf("缺少显式完全访问时应拒绝关闭审批：%+v", failure)
		}
	}
}
