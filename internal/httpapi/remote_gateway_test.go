package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestRemoteGatewayUsesRootAuthIndependentLimitAndFilteredConfig(t *testing.T) {
	const oldToken = "remote-cli-token-0000000000000001"
	const newToken = "remote-cli-token-0000000000000002"
	var projectDir string
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame appServerGatewayFrame
		if json.Unmarshal(payload, &frame) != nil || frame.Method != "config/read" {
			return
		}
		var semanticID any
		if json.Unmarshal(*frame.ID, &semanticID) != nil {
			return
		}
		response, err := json.Marshal(map[string]any{
			"id": semanticID,
			"result": map[string]any{
				"config": map[string]any{
					"model":       "gpt-test",
					"mcp_servers": map[string]any{"secret": map[string]any{"env": map[string]any{"TOKEN": "leak"}}},
					"projects": map[string]any{
						projectDir:   map[string]any{"trust_level": "trusted"},
						"/tmp/other": map[string]any{"trust_level": "trusted"},
					},
				},
				"origins": map[string]any{"secret": "leak"},
				"layers":  []any{map[string]any{"name": "user", "config": map[string]any{"env": map[string]any{"TOKEN": "leak"}}}},
			},
		})
		if err == nil {
			_ = conn.WriteMessage(messageType, response)
		}
	})
	tokenFile := filepath.Join(t.TempDir(), "remote-token")
	if err := os.WriteFile(tokenFile, []byte(oldToken+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, router, dir := buildAppServerGatewayFixture(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.RemoteGateway = config.RemoteGatewayConfig{
			Enabled:   true,
			Listen:    "127.0.0.1:8788",
			TokenFile: tokenFile,
		}
	})
	projectDir = dir
	server := httptest.NewServer(router.RemoteGatewayHandler())
	defer server.Close()

	conn := dialRemoteGateway(t, server.URL, oldToken)
	// upstream 会把转义字符串 ID 解码后重新编码；关联键必须按 JSON 值规范化。
	request := []byte(fmt.Sprintf(`{"id":"\u0078","method":"config/read","params":{"cwd":%q,"includeLayers":true}}`, projectDir))
	if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
		t.Fatal(err)
	}
	forwarded := readUpstreamFrame(t, received)
	params := decodeGatewayParamsForTest(t, forwarded)
	if params["cwd"] != projectDir || params["includeLayers"] != false {
		t.Fatalf("config/read must force safe params: %v", params)
	}
	_, response, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if json.Unmarshal(response, &envelope) != nil {
		t.Fatalf("invalid response: %s", response)
	}
	result := envelope["result"].(map[string]any)
	if len(result["origins"].(map[string]any)) != 0 || len(result["layers"].([]any)) != 0 {
		t.Fatalf("config origins/layers leaked: %v", result)
	}
	safeConfig := result["config"].(map[string]any)
	if _, exists := safeConfig["mcp_servers"]; exists {
		t.Fatalf("MCP config leaked: %v", safeConfig)
	}
	if safeConfig["approval_policy"] != "on-request" {
		t.Fatalf("remote config must start from an approval-capable policy: %v", safeConfig)
	}
	projects := safeConfig["projects"].(map[string]any)
	if len(projects) != 1 || projects[projectDir] == nil {
		t.Fatalf("only requested project trust may pass: %v", projects)
	}

	if _, response, err := websocket.DefaultDialer.Dial(wsURL(server.URL, "/"), http.Header{
		"Authorization": []string{"Bearer " + oldToken},
	}); err == nil || response == nil || response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("second remote connection should be limited: response=%v err=%v", response, err)
	}
	_ = conn.Close()
	time.Sleep(20 * time.Millisecond)

	tempToken := tokenFile + ".new"
	if err := os.WriteFile(tempToken, []byte(newToken+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tempToken, tokenFile); err != nil {
		t.Fatal(err)
	}
	if _, response, err := websocket.DefaultDialer.Dial(wsURL(server.URL, "/"), http.Header{
		"Authorization": []string{"Bearer " + oldToken},
	}); err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("old token must fail immediately: response=%v err=%v", response, err)
	}
	rotated := dialRemoteGateway(t, server.URL, newToken)
	_ = rotated.Close()
}

func TestRemoteGatewayRejectsConfigWritesBeforeUpstream(t *testing.T) {
	const token = "remote-cli-token-0000000000000003"
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	tokenFile := testAppServerTokenFile(t, token)
	_, router, _ := buildAppServerGatewayFixture(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.RemoteGateway = config.RemoteGatewayConfig{Enabled: true, Listen: "127.0.0.1:8788", TokenFile: tokenFile}
	})
	server := httptest.NewServer(router.RemoteGatewayHandler())
	defer server.Close()
	conn := dialRemoteGateway(t, server.URL, token)
	defer conn.Close()
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"id":9,"method":"config/batchWrite","params":{"edits":[]}}`)); err != nil {
		t.Fatal(err)
	}
	_, response, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if !json.Valid(response) || !containsGatewayPolicyError(response, "config/batchWrite") {
		t.Fatalf("config write should be rejected: %s", response)
	}
	select {
	case payload := <-received:
		t.Fatalf("rejected config write reached upstream: %s", payload)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestRemoteGatewayUsesExplicitMethodListAndRejectsBrowseRootCWD(t *testing.T) {
	for _, method := range []string{"review/start", "thread/compact/start", "plugin/installed"} {
		if _, ok := appServerRemoteCLIAllowedMethods[method]; ok {
			t.Fatalf("remote v1 must not inherit work-producing or plugin method %q", method)
		}
	}
	for _, method := range []string{"turn/start", "config/read", "configRequirements/read", "account/read"} {
		if _, ok := appServerRemoteCLIAllowedMethods[method]; !ok {
			t.Fatalf("remote CLI startup/turn method missing: %q", method)
		}
	}

	const token = "remote-cli-token-0000000000000004"
	upstreamURL, received, _ := fakeAppServerUpstream(t, nil)
	tokenFile := testAppServerTokenFile(t, token)
	browseRoot := t.TempDir()
	browseCWD := filepath.Join(browseRoot, "not-a-project")
	if err := os.Mkdir(browseCWD, 0o700); err != nil {
		t.Fatal(err)
	}
	_, router, _ := buildAppServerGatewayFixture(t, upstreamURL, func(cfg *config.Config) {
		cfg.BrowseRoots = []string{browseRoot}
		cfg.AppServer.RemoteGateway = config.RemoteGatewayConfig{Enabled: true, Listen: "127.0.0.1:8788", TokenFile: tokenFile}
	})
	server := httptest.NewServer(router.RemoteGatewayHandler())
	defer server.Close()
	conn := dialRemoteGateway(t, server.URL, token)
	defer conn.Close()
	request := []byte(fmt.Sprintf(`{"id":10,"method":"config/read","params":{"cwd":%q,"includeLayers":false}}`, browseCWD))
	if err := conn.WriteMessage(websocket.TextMessage, request); err != nil {
		t.Fatal(err)
	}
	_, response, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if !containsGatewayPolicyError(response, "config/read") || !containsText(response, "projects allowlist") {
		t.Fatalf("browse-root cwd must be rejected for SSH token: %s", response)
	}
	select {
	case payload := <-received:
		t.Fatalf("browse-root request reached upstream: %s", payload)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestRemoteGatewayFiltersConfigRequirementsAndReadErrors(t *testing.T) {
	policy := &appServerGatewayPolicy{
		clientKind:            appServerGatewayClientRemoteCLI,
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{},
	}
	id := json.RawMessage(`1`)
	if err := policy.rememberPendingClientRequest(&id, "configRequirements/read"); err != nil {
		t.Fatal(err)
	}
	payload := []byte(`{"id":1,"result":{"requirements":{"futureSecret":"must-not-pass"}}}`)
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		t.Fatal("invalid test payload")
	}
	rewritten, handled, err := policy.rewriteRemoteCLIResponse(payload, &frame)
	if err != nil || !handled || string(rewritten) != `{"id":1,"result":{"requirements":null}}` {
		t.Fatalf("config requirements not filtered: handled=%t err=%v payload=%s", handled, err, rewritten)
	}

	id = json.RawMessage(`2`)
	if err := policy.rememberPendingClientRequest(&id, "account/read"); err != nil {
		t.Fatal(err)
	}
	payload = []byte(`{"id":2,"error":{"code":-1,"message":"/secret/path","data":{"token":"leak"}}}`)
	frame = appServerGatewayFrame{}
	if json.Unmarshal(payload, &frame) != nil {
		t.Fatal("invalid test error payload")
	}
	rewritten, handled, err = policy.rewriteRemoteCLIResponse(payload, &frame)
	if err != nil || !handled || string(rewritten) == "" || json.Valid(rewritten) == false {
		t.Fatalf("account error rewrite failed: handled=%t err=%v payload=%s", handled, err, rewritten)
	}
	if string(rewritten) == string(payload) || containsText(rewritten, "secret") || containsText(rewritten, "token") {
		t.Fatalf("upstream error details leaked: %s", rewritten)
	}
}

func TestRemoteCLINormalizesInheritedNeverBeforePolicyValidation(t *testing.T) {
	params := map[string]any{
		"approvalPolicy":    "never",
		"approvalsReviewer": "auto_review",
		"collaborationMode": map[string]any{
			"mode": "default",
			"settings": map[string]any{
				"developer_instructions": "untrusted local instructions",
			},
		},
	}
	normalizeRemoteCLIClientParams("turn/start", params)
	if params["approvalPolicy"] != "on-request" || params["approvalsReviewer"] != "user" {
		t.Fatalf("inherited never must be downgraded before validation: %v", params)
	}
	settings := params["collaborationMode"].(map[string]any)["settings"].(map[string]any)
	if settings["developer_instructions"] != nil {
		t.Fatalf("remote developer instructions must be cleared: %v", settings)
	}
}

func dialRemoteGateway(t *testing.T, serverURL string, token string) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.DefaultDialer.Dial(wsURL(serverURL, "/"), http.Header{
		"Authorization": []string{"Bearer " + token},
	})
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

func containsGatewayPolicyError(payload []byte, method string) bool {
	var frame struct {
		Error struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	return json.Unmarshal(payload, &frame) == nil && frame.Error.Code == appServerPolicyErrorCode && frame.Error.Message != "" && len(method) > 0
}

func containsText(payload []byte, text string) bool {
	return bytes.Contains(payload, []byte(text))
}
