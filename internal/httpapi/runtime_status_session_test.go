package httpapi

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gorilla/websocket"
)

type sessionUnavailableTestTransport struct{ directWSTestTransport }

func (sessionUnavailableTestTransport) WebSocketDialer(time.Duration) (websocket.Dialer, error) {
	return websocket.Dialer{NetDialContext: func(context.Context, string, string) (net.Conn, error) {
		return nil, fmt.Errorf("session probe: %w", &appserver.SharedLocalSessionError{Kind: "background"})
	}}, nil
}

func TestRuntimeStatusDistinguishesSharedSessionFailureFromHealth(t *testing.T) {
	handler, router := appServerGatewayRouterFixtureWithRouter(t, "ws://127.0.0.1:1", nil)
	router.appServerSSH = sessionUnavailableTestTransport{}
	status := router.probeCodexRuntime(context.Background())
	if status.State != runtimeStateUnavailable || status.Reason != "shared_local_session_unavailable" {
		t.Fatalf("环境校验失败必须保留准确的 Codex unavailable 状态：%+v", status)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("Codex 环境故障不能关闭主服务诊断：%d %s", rec.Code, rec.Body.String())
	}
}
