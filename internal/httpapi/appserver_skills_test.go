package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestAppServerGatewaySkillsListUsesSingleAuthorizedCWD(t *testing.T) {
	if _, ok := appServerAllowedMethods["skills/list"]; !ok {
		t.Fatal("Codex gateway allowlist 应包含 skills/list")
	}

	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()
	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	payload, err := json.Marshal(map[string]any{
		"id":     71,
		"method": "skills/list",
		"params": map[string]any{
			"cwds":        []any{projectDir},
			"forceReload": true,
			"unsafe":      "drop-me",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
		t.Fatal(err)
	}

	select {
	case forwarded := <-received:
		params := decodeGatewayParamsForTest(t, forwarded)
		assertGatewayParamsOnly(t, params, "cwds", "forceReload")
		cwds, ok := params["cwds"].([]any)
		if !ok || len(cwds) != 1 || cwds[0] != projectDir {
			t.Fatalf("skills/list 只能转发一个授权 cwd：%v", params)
		}
		if forceReload, ok := params["forceReload"].(bool); !ok || !forceReload {
			t.Fatalf("forceReload 应保留布尔值：%v", params)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fake upstream 未收到 skills/list")
	}
}

func TestAppServerGatewaySkillsListRejectsUnsafeScopes(t *testing.T) {
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	handler, projectDir := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	cases := []struct {
		name   string
		params map[string]any
		want   string
	}{
		{name: "missing", params: map[string]any{}, want: "cwds"},
		{name: "multiple", params: map[string]any{"cwds": []any{projectDir, projectDir}}, want: "只能包含一个"},
		{name: "outside", params: map[string]any{"cwds": []any{t.TempDir()}}, want: "allowlist"},
		{name: "bad force", params: map[string]any{"cwds": []any{projectDir}, "forceReload": "true"}, want: "布尔值"},
	}

	for index, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			conn := dialAuthedGateway(t, server.URL)
			defer conn.Close()
			payload, err := json.Marshal(map[string]any{"id": 80 + index, "method": "skills/list", "params": tc.params})
			if err != nil {
				t.Fatal(err)
			}
			if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
				t.Fatal(err)
			}
			raw := readGatewayRaw(t, conn)
			if !strings.Contains(string(raw), tc.want) {
				t.Fatalf("错误应包含 %q，got=%s", tc.want, raw)
			}
			assertNoUpstreamFrame(t, received)
		})
	}
}
