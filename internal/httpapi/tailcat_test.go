package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
)

type fakeTailcatSidecar struct {
	status       tailcatStatus
	allowedKey   string
	allowCalls   int
	startCalls   int
	stopCalls    int
	pairCalls    int
	resetCalls   int
	operationErr error
}

func (f *fakeTailcatSidecar) Status(context.Context) tailcatStatus { return f.status }
func (f *fakeTailcatSidecar) Start(context.Context) error {
	f.startCalls++
	return f.operationErr
}
func (f *fakeTailcatSidecar) Stop(context.Context) error {
	f.stopCalls++
	return f.operationErr
}
func (f *fakeTailcatSidecar) Pair(context.Context) (tailcatStatus, error) {
	f.pairCalls++
	return f.status, f.operationErr
}
func (f *fakeTailcatSidecar) AllowClient(_ context.Context, key string) (tailcatStatus, error) {
	f.allowCalls++
	f.allowedKey = key
	return f.status, f.operationErr
}
func (f *fakeTailcatSidecar) Reset(context.Context) (tailcatStatus, error) {
	f.resetCalls++
	return f.status, f.operationErr
}
func (f *fakeTailcatSidecar) Close() {}

func TestTailcatLocalStatusRequiresLoopbackAndLocalToken(t *testing.T) {
	server := newTestServer(t)
	fake := &fakeTailcatSidecar{status: tailcatStatus{Enabled: true, Running: true, PairedDeviceCount: 2}}
	server.router.tailcat = fake
	server.router.tailcatLocalToken = "local-only-token"

	request := authedRequest(t, http.MethodGet, "/api/local/tailcat", nil)
	request.RemoteAddr = "127.0.0.1:54321"
	request.Host = "127.0.0.1:8787"
	request.Header.Set(TailcatLocalControlHeader, "local-only-token")
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("可信本机状态请求失败：status=%d body=%s", response.Code, response.Body.String())
	}

	for _, testCase := range []struct {
		name   string
		remote string
		token  string
		origin string
	}{
		{name: "remote", remote: "100.64.0.2:54321", token: "local-only-token"},
		{name: "wrong token", remote: "127.0.0.1:54321", token: "wrong"},
		{name: "browser origin", remote: "127.0.0.1:54321", token: "local-only-token", origin: "https://example.com"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			req := authedRequest(t, http.MethodGet, "/api/local/tailcat", nil)
			req.RemoteAddr = testCase.remote
			req.Host = "127.0.0.1:8787"
			req.Header.Set(TailcatLocalControlHeader, testCase.token)
			req.Header.Set("Origin", testCase.origin)
			rec := httptest.NewRecorder()
			server.handler.ServeHTTP(rec, req)
			if rec.Code != http.StatusForbidden {
				t.Fatalf("非可信请求必须拒绝：status=%d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestTailcatPairingClaimAuthorizesClientAndReturnsStableAddress(t *testing.T) {
	server := newTestServer(t)
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Enabled: true,
		Running: true,
		Address: "tailcat-stable-address",
	}}
	server.router.tailcat = fake
	now := time.Now().UTC()
	ticket := auth.NewPairingTicket("http://127.0.0.1:8787", testToken, now.Add(-time.Minute), now.Add(time.Minute))
	payload := pairingClaimRequest{
		Endpoint:         ticket.Endpoint,
		IssuedAt:         ticket.IssuedAt,
		ExpiresAt:        ticket.ExpiresAt,
		Signature:        ticket.Signature,
		TailcatClientKey: "nodekey:client-public-key",
	}
	response := performPairingClaim(t, server.handler, payload)
	if response.Code != http.StatusOK {
		t.Fatalf("Tailcat 配对失败：status=%d body=%s", response.Code, response.Body.String())
	}
	var claimed pairingClaimResponse
	if err := json.NewDecoder(response.Body).Decode(&claimed); err != nil {
		t.Fatal(err)
	}
	if claimed.TailcatAddress != "tailcat-stable-address" {
		t.Fatalf("未返回稳定地址：%+v", claimed)
	}
	if fake.allowCalls != 1 || fake.allowedKey != payload.TailcatClientKey {
		t.Fatalf("客户端公钥未写入白名单：calls=%d key=%q", fake.allowCalls, fake.allowedKey)
	}

	invalid := payload
	invalid.Signature = strings.Repeat("0", len(payload.Signature))
	invalidResponse := performPairingClaim(t, server.handler, invalid)
	if invalidResponse.Code != http.StatusUnauthorized {
		t.Fatalf("无效票据必须拒绝：status=%d", invalidResponse.Code)
	}
	if fake.allowCalls != 1 {
		t.Fatalf("无效票据不能修改白名单：calls=%d", fake.allowCalls)
	}
}
