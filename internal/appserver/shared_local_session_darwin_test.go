//go:build darwin

package appserver

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestValidateSharedLocalSessionAqua(t *testing.T) {
	conn := sharedLocalSessionTestConnection(t, func(conn *websocket.Conn, request map[string]any) {
		assertSharedLocalSessionRequest(t, request)
		_ = conn.WriteJSON(map[string]any{
			"method": "account/updated",
			"params": map[string]any{"ignored": true},
		})
		_ = conn.WriteJSON(map[string]any{
			"id": sharedLocalSessionRequestID,
			"result": map[string]any{
				"exitCode": 0,
				"stdout":   "Aqua\n",
				"stderr":   "",
			},
		})
	})
	if err := validateSharedLocalSession(context.Background(), conn); err != nil {
		t.Fatalf("Aqua 会话应通过探针：%v", err)
	}
}

func TestValidateSharedLocalSessionBackground(t *testing.T) {
	conn := sharedLocalSessionResultConnection(t, map[string]any{
		"exitCode": 0,
		"stdout":   "Background\n",
		"stderr":   "",
	})
	err := validateSharedLocalSession(context.Background(), conn)
	var sessionErr *SharedLocalSessionError
	if !errors.As(err, &sessionErr) || sessionErr.Kind != "background" {
		t.Fatalf("Background 应返回可识别的会话错误：%T %v", err, err)
	}
	if !strings.Contains(err.Error(), "无法继承用户登录授权") {
		t.Fatalf("错误应解释后台安全会话的授权限制：%v", err)
	}
}

func TestValidateSharedLocalSessionRejectsInvalidResults(t *testing.T) {
	tests := []struct {
		name   string
		result map[string]any
		kind   string
	}{
		{name: "missing stdout", result: map[string]any{"exitCode": 0, "stderr": ""}, kind: "invalid_response"},
		{name: "unknown manager", result: map[string]any{"exitCode": 0, "stdout": "System\n", "stderr": ""}, kind: "unexpected_manager"},
		{name: "command failed", result: map[string]any{"exitCode": 1, "stdout": "", "stderr": "private output"}, kind: "invalid_response"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			conn := sharedLocalSessionResultConnection(t, test.result)
			err := validateSharedLocalSession(context.Background(), conn)
			var sessionErr *SharedLocalSessionError
			if !errors.As(err, &sessionErr) || sessionErr.Kind != test.kind {
				t.Fatalf("非法结果应返回 %q：%T %v", test.kind, err, err)
			}
			if strings.Contains(err.Error(), "private output") || strings.Contains(err.Error(), "System") {
				t.Fatalf("错误不得泄露 command/exec 输出：%v", err)
			}
		})
	}
}

func TestValidateSharedLocalSessionRPCError(t *testing.T) {
	conn := sharedLocalSessionTestConnection(t, func(conn *websocket.Conn, _ map[string]any) {
		_ = conn.WriteJSON(map[string]any{
			"id": sharedLocalSessionRequestID,
			"error": map[string]any{
				"code":    -32601,
				"message": "private upstream detail",
			},
		})
	})
	err := validateSharedLocalSession(context.Background(), conn)
	var sessionErr *SharedLocalSessionError
	if !errors.As(err, &sessionErr) || sessionErr.Kind != "rpc_error" {
		t.Fatalf("RPC error 应返回可识别的会话错误：%T %v", err, err)
	}
	if strings.Contains(err.Error(), "private upstream detail") {
		t.Fatalf("错误不得泄露 RPC 文本：%v", err)
	}
}

func TestValidateSharedLocalSessionTimeout(t *testing.T) {
	release := make(chan struct{})
	conn := sharedLocalSessionTestConnection(t, func(_ *websocket.Conn, _ map[string]any) {
		<-release
	})
	t.Cleanup(func() { close(release) })
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	started := time.Now()
	err := validateSharedLocalSession(ctx, conn)
	var sessionErr *SharedLocalSessionError
	if !errors.As(err, &sessionErr) || sessionErr.Kind != "timeout" {
		t.Fatalf("超时应返回可识别的会话错误：%T %v", err, err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("超时应保留 context deadline 语义：%v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("调用方更短的 deadline 必须优先，实际耗时 %v", elapsed)
	}
}

func sharedLocalSessionResultConnection(t *testing.T, result map[string]any) *websocket.Conn {
	t.Helper()
	return sharedLocalSessionTestConnection(t, func(conn *websocket.Conn, _ map[string]any) {
		_ = conn.WriteJSON(map[string]any{"id": sharedLocalSessionRequestID, "result": result})
	})
}

func sharedLocalSessionTestConnection(t *testing.T, respond func(*websocket.Conn, map[string]any)) *websocket.Conn {
	t.Helper()
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		conn, err := upgrader.Upgrade(w, request, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		var payload map[string]any
		if conn.ReadJSON(&payload) != nil {
			return
		}
		respond(conn, payload)
	}))
	t.Cleanup(server.Close)
	url := "ws" + strings.TrimPrefix(server.URL, "http")
	conn, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func assertSharedLocalSessionRequest(t *testing.T, request map[string]any) {
	t.Helper()
	if request["id"] != sharedLocalSessionRequestID || request["method"] != "command/exec" {
		t.Fatalf("探针必须使用固定 request：%v", request)
	}
	params, ok := request["params"].(map[string]any)
	if !ok {
		t.Fatalf("command/exec params 缺失：%v", request)
	}
	command, _ := params["command"].([]any)
	if len(command) != 2 || command[0] != "/bin/launchctl" || command[1] != "managername" {
		t.Fatalf("探针命令必须使用固定 argv：%v", params["command"])
	}
	if params["processId"] != sharedLocalSessionRequestID || params["timeoutMs"] != float64(sharedLocalCommandTimeoutMS) {
		t.Fatalf("探针必须设置固定 processId 与超时：%v", params)
	}
	sandbox, _ := params["sandboxPolicy"].(map[string]any)
	if sandbox["type"] != "dangerFullAccess" {
		t.Fatalf("探针必须避免 sandbox 造成假阴性：%v", sandbox)
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"thread/start", "threadId", "turn/start", "token", "Token"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("会话探针不得读取 Token 或创建 thread/turn：%s", encoded)
		}
	}
}
