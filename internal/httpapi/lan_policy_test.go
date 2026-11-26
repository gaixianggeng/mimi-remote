package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestResidentLANPolicyNeedsAuthenticatedLoopback(t *testing.T) {
	handler, r := appServerGatewayRouterFixtureWithRouter(t, "ws://127.0.0.1:1", func(c *config.Config) { c.Network.AllowLAN = true })
	calls := 0
	r.confirmLANPolicy = func(context.Context) string { calls++; return "lan_firewall_blocked" }
	for _, tc := range []struct {
		auth           bool
		remote, origin string
		want           int
	}{
		{false, "127.0.0.1:8000", "", 401}, {true, "192.168.50.3:8000", "", 403}, {true, "127.0.0.1:8000", "http://example.invalid", 403}, {true, "127.0.0.1:8000", "", 200},
	} {
		req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1/api/local/lan-policy", nil)
		req.RemoteAddr = tc.remote
		if tc.auth {
			req.Header.Set("Authorization", "Bearer "+testToken)
		}
		if tc.origin != "" {
			req.Header.Set("Origin", tc.origin)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != tc.want {
			t.Fatalf("policy response %d, want %d", rec.Code, tc.want)
		}
		if rec.Code == 200 {
			var reply struct {
				Allowed bool
				Code    string
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &reply); err != nil || reply.Allowed || reply.Code != "lan_firewall_blocked" {
				t.Fatal("unsafe policy reply")
			}
		}
	}
	if calls != 1 {
		t.Fatalf("policy check invoked %d times", calls)
	}
}
