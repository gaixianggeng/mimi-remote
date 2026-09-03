package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
)

type fakeTailcatSidecar struct {
	status         tailcatStatus
	allowedKey     string
	allowCalls     int
	managedKeys    []string
	managedCalls   int
	managedStatus  *tailcatStatus
	startCalls     int
	stopCalls      int
	pairCalls      int
	resetCalls     int
	configureCalls int
	configuredURL  string
	operationErr   error
}

type fakeManagedPairingService struct {
	status       tailcatStatus
	sessionID    string
	grant        string
	mobileKey    string
	completeCall int
	operationErr error
}

func (f *fakeManagedPairingService) Start()                      {}
func (f *fakeManagedPairingService) Sync(context.Context) error  { return f.operationErr }
func (f *fakeManagedPairingService) Reset(context.Context) error { return f.operationErr }
func (f *fakeManagedPairingService) Close()                      {}
func (f *fakeManagedPairingService) Complete(
	_ context.Context,
	sessionID string,
	grant string,
	mobileKey string,
) (tailcatStatus, error) {
	f.completeCall++
	f.sessionID = sessionID
	f.grant = grant
	f.mobileKey = mobileKey
	return f.status, f.operationErr
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
func (f *fakeTailcatSidecar) ReplaceManagedClients(_ context.Context, keys []string) (tailcatStatus, error) {
	f.managedCalls++
	f.managedKeys = append([]string(nil), keys...)
	if f.managedStatus != nil {
		f.status = *f.managedStatus
		f.managedStatus = nil
	}
	return f.status, f.operationErr
}
func (f *fakeTailcatSidecar) Reset(context.Context) (tailcatStatus, error) {
	f.resetCalls++
	return f.status, f.operationErr
}
func (f *fakeTailcatSidecar) ConfigureDERPMap(_ context.Context, rawURL string) (tailcatStatus, error) {
	f.configureCalls++
	f.configuredURL = rawURL
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

func TestManagedTailcatClaimCompletesCloudPairingWithoutFreeAllowlistWrite(t *testing.T) {
	server := newTestServer(t)
	fakeTailcat := &fakeTailcatSidecar{status: tailcatStatus{Running: true}}
	fakeManaged := &fakeManagedPairingService{status: tailcatStatus{
		Enabled: true, Running: true, Address: "tailcat-managed-address",
	}}
	server.router.tailcat = fakeTailcat
	server.router.managedPairing = fakeManaged
	now := time.Now().UTC()
	ticket := auth.NewPairingTicket("http://127.0.0.1:8787", testToken, now.Add(-time.Minute), now.Add(time.Minute))
	payload := pairingClaimRequest{
		Endpoint:         ticket.Endpoint,
		IssuedAt:         ticket.IssuedAt,
		ExpiresAt:        ticket.ExpiresAt,
		Signature:        ticket.Signature,
		TailcatClientKey: testManagedMobileKey,
		ManagedSessionID: testManagedSessionID,
		ManagedGrant:     managedToken('g'),
	}

	response := performPairingClaim(t, server.handler, payload)
	if response.Code != http.StatusOK {
		t.Fatalf("托管 Tailcat 配对失败：status=%d body=%s", response.Code, response.Body.String())
	}
	if fakeManaged.completeCall != 1 || fakeManaged.sessionID != payload.ManagedSessionID ||
		fakeManaged.grant != payload.ManagedGrant || fakeManaged.mobileKey != payload.TailcatClientKey {
		t.Fatalf("托管配对参数未完整传递：%+v", fakeManaged)
	}
	if fakeTailcat.allowCalls != 0 {
		t.Fatal("托管配对不能写入永久免费的 clients.json 白名单")
	}
}

func TestManagedTailcatClaimRejectsPartialGrantBeforeAnyAllowlistWrite(t *testing.T) {
	server := newTestServer(t)
	fakeTailcat := &fakeTailcatSidecar{status: tailcatStatus{Running: true}}
	fakeManaged := &fakeManagedPairingService{}
	server.router.tailcat = fakeTailcat
	server.router.managedPairing = fakeManaged
	now := time.Now().UTC()
	ticket := auth.NewPairingTicket("http://127.0.0.1:8787", testToken, now.Add(-time.Minute), now.Add(time.Minute))
	payload := pairingClaimRequest{
		Endpoint:         ticket.Endpoint,
		IssuedAt:         ticket.IssuedAt,
		ExpiresAt:        ticket.ExpiresAt,
		Signature:        ticket.Signature,
		TailcatClientKey: testManagedMobileKey,
		ManagedSessionID: testManagedSessionID,
	}

	response := performPairingClaim(t, server.handler, payload)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("不完整托管授权必须拒绝：status=%d body=%s", response.Code, response.Body.String())
	}
	if fakeManaged.completeCall != 0 || fakeTailcat.allowCalls != 0 {
		t.Fatal("不完整托管授权不能修改任何白名单")
	}
}

func TestTailcatLocalResetContinuesAfterManagedCleanupFailure(t *testing.T) {
	server := newTestServer(t)
	fakeTailcat := &fakeTailcatSidecar{status: tailcatStatus{Running: true}}
	fakeManaged := &fakeManagedPairingService{operationErr: errors.New("disk full")}
	server.router.tailcat = fakeTailcat
	server.router.managedPairing = fakeManaged
	server.router.tailcatLocalToken = "local-only-token"

	request := authedRequest(t, http.MethodPost, "/api/local/tailcat", tailcatControlRequest{Action: "reset"})
	request.RemoteAddr = "127.0.0.1:54321"
	request.Host = "127.0.0.1:8787"
	request.Header.Set(TailcatLocalControlHeader, "local-only-token")
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), "disk full") {
		t.Fatalf("托管清理失败应返回明确错误：status=%d body=%s", response.Code, response.Body.String())
	}
	if fakeTailcat.resetCalls != 1 {
		t.Fatalf("托管清理失败后仍应重置底层 Tailcat：calls=%d", fakeTailcat.resetCalls)
	}
}

func TestTailcatLocalConfigurePassesDERPMapToSupervisor(t *testing.T) {
	server := newTestServer(t)
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Enabled:    true,
		Running:    true,
		DERPMapURL: "https://relay.example/derpmap/default",
	}}
	server.router.tailcat = fake
	server.router.tailcatLocalToken = "local-only-token"

	request := authedRequest(t, http.MethodPost, "/api/local/tailcat", tailcatControlRequest{
		Action:     "configure",
		DERPMapURL: "https://relay.example/derpmap/default",
	})
	request.RemoteAddr = "127.0.0.1:54321"
	request.Host = "127.0.0.1:8787"
	request.Header.Set(TailcatLocalControlHeader, "local-only-token")
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("配置自定义中继失败：status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.configureCalls != 1 || fake.configuredURL != "https://relay.example/derpmap/default" {
		t.Fatalf("未传递 DERP Map：calls=%d url=%q", fake.configureCalls, fake.configuredURL)
	}
}

func TestTailcatIdentitySnapshotRestoresPrivateState(t *testing.T) {
	stateDir := t.TempDir()
	for _, name := range []string{"host.private.json", "host.address", "clients.json"} {
		if err := os.WriteFile(filepath.Join(stateDir, name), []byte("original-"+name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	snapshot, err := snapshotTailcatIdentityState(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := clearTailcatIdentityState(stateDir); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "host.address"), []byte("replacement"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := restoreTailcatIdentityState(stateDir, snapshot); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"host.private.json", "host.address", "clients.json"} {
		data, err := os.ReadFile(filepath.Join(stateDir, name))
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != "original-"+name {
			t.Fatalf("%s 未恢复：%q", name, data)
		}
		info, err := os.Stat(filepath.Join(stateDir, name))
		if err != nil {
			t.Fatal(err)
		}
		// Windows 不实现 Unix 权限位；这里只在支持该语义的平台验证私钥文件权限。
		if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
			t.Fatalf("%s 权限为 %o，预期 600", name, info.Mode().Perm())
		}
	}
}
