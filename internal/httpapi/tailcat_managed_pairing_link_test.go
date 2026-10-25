package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

const managedPairingLinkPath = "/api/tailcat/managed-pairing-link"

type linkTestSidecar struct {
	fakeTailcatSidecar
	startHook func(context.Context) error
	pairHook  func(context.Context) error
	stopHook  func(context.Context) error
}

func (s *linkTestSidecar) Start(ctx context.Context) error {
	s.startCalls++
	if s.startHook != nil {
		return s.startHook(ctx)
	}
	s.status.Enabled, s.status.Running = true, true
	return nil
}

func (s *linkTestSidecar) Stop(ctx context.Context) error {
	s.stopCalls++
	if s.stopHook != nil {
		return s.stopHook(ctx)
	}
	s.status.Enabled, s.status.Running = false, false
	return nil
}

func (s *linkTestSidecar) Pair(ctx context.Context) (tailcatStatus, error) {
	s.pairCalls++
	if s.pairHook != nil {
		if err := s.pairHook(ctx); err != nil {
			return tailcatStatus{}, err
		}
	}
	return s.status, nil
}

func newLinkTestServer(t *testing.T) (testServer, *linkTestSidecar, *managedPairingController) {
	t.Helper()
	server := newTestServer(t)
	r := server.router
	r.configPath = filepath.Join(t.TempDir(), "config.json")
	r.installationID = testManagedInstallationID
	raw, err := json.Marshal(r.cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(r.configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	s := &linkTestSidecar{fakeTailcatSidecar: fakeTailcatSidecar{status: tailcatStatus{
		Enabled: true, Running: true, Mode: config.TailcatModeSelfHosted,
		Address: "tailcat:test-stable", PublicKey: testManagedMacKey,
		PairAddress: "tailcat:test-pair", PairPublicKey: testManagedMobileKey,
		PairExpiresAt: time.Now().Add(10 * time.Minute).UTC().Format(time.RFC3339Nano),
	}}}
	c, err := newManagedPairingController(managedPairingControllerOptions{
		BaseURL: "https://control.example.invalid", StatePath: filepath.Join(t.TempDir(), managedPairingStateFileName),
		InstallationID: r.installationID, Tailcat: s, HTTPClient: &http.Client{Transport: rejectModeTestNetwork{}},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	r.tailcat, r.managedPairing = s, c
	return server, s, c
}

func requestManagedPairingLink(t *testing.T, server testServer, confirm bool) *httptest.ResponseRecorder {
	t.Helper()
	req := authedRequest(t, http.MethodPost, managedPairingLinkPath, tailcatManagedPairingLinkRequest{ConfirmResetSelfHosted: confirm})
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, req)
	return response
}

func assertLinkFailure(t *testing.T, response *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if response.Code != status || body["code"] != code || body["pair_url"] != nil {
		t.Fatalf("错误响应不符：status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestTailcatManagedPairingLinkRequiresBearer(t *testing.T) {
	for _, insecure := range []bool{false, true} {
		server := newTestServerWithConfig(t, func(cfg *config.Config) {
			cfg.DevInsecure = insecure
			cfg.Auth.AllowQueryToken = true
		})
		server.router.tailcatControlMu.Lock()
		for _, authorization := range []string{"", "Basic " + testToken, "Bearer wrong", "Bearer " + testToken} {
			req := httptest.NewRequest(http.MethodPost, managedPairingLinkPath+"?token="+testToken, strings.NewReader(`{}`))
			req.Header.Set("Authorization", authorization)
			req.Header.Set(TailcatLocalControlHeader, "local-only-token")
			response := httptest.NewRecorder()
			server.handler.ServeHTTP(response, req)
			if authorization == "Bearer "+testToken {
				assertLinkFailure(t, response, http.StatusConflict, "tailcat_operation_in_progress")
			} else if response.Code != http.StatusUnauthorized || response.Header().Get("WWW-Authenticate") != "Bearer" {
				t.Fatalf("insecure=%t 时未强制 Bearer：%d %s", insecure, response.Code, response.Body.String())
			}
		}
		server.router.tailcatControlMu.Unlock()
	}
}

func TestTailcatManagedPairingLinkConfirmsAllSelfHostedClients(t *testing.T) {
	// Tailcat 转发和本机调用的来源都可能为 loopback。伪造的转发头不能绕过确认。
	for _, remote := range []string{"127.0.0.1:54321", "[::1]:54321", "192.0.2.1:54321"} {
		server, s, c := newLinkTestServer(t)
		s.status.PairedDeviceCount = 2
		req := authedRequest(t, http.MethodPost, managedPairingLinkPath, map[string]bool{})
		req.RemoteAddr, req.Host = remote, "localhost:8787"
		req.Header.Set("Forwarded", "for=192.0.2.2")
		req.Header.Set("X-Forwarded-For", "192.0.2.2")
		response := httptest.NewRecorder()
		server.handler.ServeHTTP(response, req)
		assertLinkFailure(t, response, http.StatusConflict, "tailcat_self_hosted_clients_present")
		body := decodeJSON(t, response)
		if body["paired_device_count"] != float64(2) || s.status.Mode != config.TailcatModeSelfHosted ||
			s.status.PublicKey != testManagedMacKey || s.pairCalls != 0 || c.state.HostID != "" {
			t.Fatal("未确认请求修改了模式、身份或配对")
		}
	}
}

func TestTailcatManagedPairingLinkEnablesAndSwitchesRealSidecar(t *testing.T) {
	binary := buildModeTestSidecar(t)
	for _, tc := range []struct {
		name    string
		enabled bool
		clients bool
		confirm bool
	}{
		{name: "disabled"},
		{name: "enabled", enabled: true},
		{name: "disabled-with-clients", clients: true},
		{name: "enabled-with-clients", enabled: true, clients: true},
		{name: "confirmed", enabled: true, clients: true, confirm: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, c := newModeTestHost(t, binary, "https://custom.example.invalid/map", false)
			if tc.clients {
				if err := os.WriteFile(filepath.Join(s.stateDir, "clients.json"), []byte(`["free-client"]`), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if tc.enabled {
				if _, err := agentsetup.ConfigureTailcat(s.configPath, true); err != nil {
					t.Fatal(err)
				}
				if err := s.Start(context.Background()); err != nil {
					t.Fatal(err)
				}
			}
			server := newTestServer(t)
			r := server.router
			r.tailcat, r.managedPairing, r.configPath, r.installationID = s, c, s.configPath, testManagedInstallationID
			response := requestManagedPairingLink(t, server, tc.confirm)
			if tc.clients && !tc.confirm {
				assertLinkFailure(t, response, http.StatusConflict, "tailcat_self_hosted_clients_present")
				if s.Status(context.Background()).Mode != config.TailcatModeSelfHosted {
					t.Fatal("未确认就切换了模式")
				}
				return
			}
			assertManagedPairingLink(t, response, s.configPath, r.decorateTailcatStatus(s.Status(context.Background())))
			if persisted := readModeTestConfig(t, s.configPath); !persisted.Tailcat.Enabled || persisted.Tailcat.Mode != config.TailcatModeManaged {
				t.Fatal("未开启并持久化托管模式")
			}
			if tc.clients {
				if _, err := os.Stat(filepath.Join(s.stateDir, "clients.json")); !os.IsNotExist(err) {
					t.Fatalf("确认后未清空自建配对：%v", err)
				}
			}
			seedModeTestPolicy(t, c, s)
			before, state := s.Status(context.Background()), c.state
			response = requestManagedPairingLink(t, server, false)
			assertManagedPairingLink(t, response, s.configPath, r.decorateTailcatStatus(s.Status(context.Background())))
			after := s.Status(context.Background())
			if after.PublicKey != before.PublicKey || after.InstanceID != before.InstanceID || !reflect.DeepEqual(c.state, state) {
				t.Fatal("已托管时重复请求轮换了身份或清空了授权")
			}
		})
	}
}

func assertManagedPairingLink(t *testing.T, response *httptest.ResponseRecorder, configPath string, status tailcatStatus) {
	t.Helper()
	if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("生成链接失败：%d %s", response.Code, response.Body.String())
	}
	var body tailcatManagedPairingLinkResponse
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	got, err := url.Parse(body.PairURL)
	if err != nil {
		t.Fatal(err)
	}
	// CLI 使用相同构造器。仅签发时间不同；逐项比较其余字段，再独立验证真实签名。
	cli, err := agentsetup.TailcatPairWithManagedHost(configPath, status.PairAddress, status.MacInstallationID, status.PublicKey, status.PairPublicKey)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := url.Parse(cli.PairURL)
	gotQuery, wantQuery := got.Query(), want.Query()
	ticket := auth.PairingTicket{
		Endpoint: gotQuery.Get("endpoint"), IssuedAt: gotQuery.Get("issued_at"),
		ExpiresAt: gotQuery.Get("expires_at"), Signature: gotQuery.Get("pair_sig"),
	}
	if err := auth.ValidatePairingTicket(testToken, ticket, time.Now()); err != nil {
		t.Fatal(err)
	}
	expires, parseErr := time.Parse(time.RFC3339Nano, body.PairExpiresAt)
	ticketExpiry, _ := time.Parse(time.RFC3339Nano, ticket.ExpiresAt)
	nodeExpiry, _ := time.Parse(time.RFC3339Nano, status.PairExpiresAt)
	if body.Mode != config.TailcatModeManaged || parseErr != nil || !expires.After(time.Now()) ||
		expires.After(ticketExpiry) || expires.After(nodeExpiry) || strings.Contains(body.PairURL, testToken) {
		t.Fatal("链接的模式、过期时间或凭证边界不符")
	}
	for _, field := range []string{"issued_at", "expires_at", "pair_sig"} {
		gotQuery.Del(field)
		wantQuery.Del(field)
	}
	got.RawQuery, want.RawQuery = gotQuery.Encode(), wantQuery.Encode()
	if got.String() != want.String() || gotQuery.Get("managed_mac_installation_id") != status.MacInstallationID ||
		gotQuery.Get("managed_mac_tailcat_public_key") != status.PublicKey || gotQuery.Get("managed_pair_tailcat_public_key") != status.PairPublicKey {
		t.Fatal("返回链接与 CLI 二维码内容不一致")
	}
}

func TestTailcatManagedPairingLinkModeFailureRollsBackRealSidecar(t *testing.T) {
	binary := buildModeTestSidecar(t)
	s, c := newModeTestHost(t, binary, "https://custom.example.invalid/map", false)
	if err := os.WriteFile(filepath.Join(s.stateDir, "clients.json"), []byte(`["free-client"]`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	before := s.Status(context.Background())
	identity, err := snapshotTailcatIdentityState(s.stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.stateDir, "fail-start-url"), []byte(testOfficialRelayURL), 0o600); err != nil {
		t.Fatal(err)
	}
	server := newTestServer(t)
	r := server.router
	r.tailcat, r.managedPairing, r.configPath = s, c, s.configPath
	response := requestManagedPairingLink(t, server, true)
	assertLinkFailure(t, response, http.StatusServiceUnavailable, "tailcat_managed_mode_failed")
	after := s.Status(context.Background())
	restored, err := snapshotTailcatIdentityState(s.stateDir)
	if err != nil || !reflect.DeepEqual(restored, identity) || !after.Running ||
		after.PublicKey != before.PublicKey || after.Mode != before.Mode || after.PairedDeviceCount != 1 {
		t.Fatalf("未恢复身份和自建配对：%v", err)
	}
	if persisted := readModeTestConfig(t, s.configPath); persisted.Tailcat.ConnectionMode() != config.TailcatModeSelfHosted {
		t.Fatal("失败后模式已提交")
	}
}

func TestTailcatManagedPairingLinkEnableRollbackSurvivesCancellation(t *testing.T) {
	server, s, _ := newLinkTestServer(t)
	s.status.Enabled, s.status.Running = false, false
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.startHook = func(context.Context) error {
		cancel()
		return errors.New("injected start failure")
	}
	var stopContextError error
	s.stopHook = func(ctx context.Context) error { stopContextError = ctx.Err(); return nil }
	req := authedRequest(t, http.MethodPost, managedPairingLinkPath, map[string]bool{})
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, req.WithContext(ctx))
	assertLinkFailure(t, response, http.StatusServiceUnavailable, "tailcat_enable_failed")
	if persisted := readModeTestConfig(t, server.router.configPath); persisted.Tailcat.Enabled || s.stopCalls != 1 || stopContextError != nil || s.pairCalls != 0 {
		t.Fatal("enable 失败后未用独立上下文恢复关闭状态")
	}
}

func TestTailcatManagedPairingLinkUsesReusedNodeExpiry(t *testing.T) {
	server, s, _ := newLinkTestServer(t)
	s.status.PairExpiresAt = time.Now().Add(6 * time.Minute).UTC().Format(time.RFC3339Nano)
	response := requestManagedPairingLink(t, server, false)
	assertManagedPairingLink(t, response, server.router.configPath, server.router.decorateTailcatStatus(s.status))
	if body := decodeJSON(t, response); body["pair_expires_at"] != s.status.PairExpiresAt {
		t.Fatal("复用节点时必须返回较早的节点有效期")
	}
}

func TestTailcatManagedPairingLinkFailures(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(testServer, *linkTestSidecar, *managedPairingController)
		status int
		code   string
	}{
		{"uninitialized", func(server testServer, _ *linkTestSidecar, _ *managedPairingController) {
			server.router.managedPairing = nil
		}, 503, "tailcat_managed_pairing_unavailable"},
		{"disabled-agents", func(server testServer, _ *linkTestSidecar, _ *managedPairingController) {
			disabled := false
			server.router.cfg.Codex.Enabled = &disabled
		}, 503, "tailcat_agents_disabled"},
		{"unknown-count", func(_ testServer, s *linkTestSidecar, _ *managedPairingController) {
			s.status.Error = "injected status failure"
		}, 503, "tailcat_status_unavailable"},
		{"enable-config", func(server testServer, s *linkTestSidecar, _ *managedPairingController) {
			s.status.Enabled = false
			server.router.configPath += ".missing"
		}, 500, "tailcat_enable_failed"},
		{"enable-rollback", func(_ testServer, s *linkTestSidecar, _ *managedPairingController) {
			s.status.Enabled = false
			s.startHook = func(context.Context) error { return errors.New("injected start failure") }
			s.stopHook = func(context.Context) error { return errors.New("injected stop failure") }
		}, 503, "tailcat_enable_rollback_failed"},
		{"mode", func(_ testServer, _ *linkTestSidecar, c *managedPairingController) {
			c.stateLoadError = errors.New("injected state failure")
		}, 503, "tailcat_managed_mode_failed"},
		{"pair", func(_ testServer, s *linkTestSidecar, _ *managedPairingController) {
			s.pairHook = func(context.Context) error { return errors.New("injected pair failure") }
		}, 503, "tailcat_pair_failed"},
		{"incomplete-pair", func(_ testServer, s *linkTestSidecar, _ *managedPairingController) { s.status.PairPublicKey = "" }, 503, "tailcat_pair_failed"},
		{"expired-pair", func(_ testServer, s *linkTestSidecar, _ *managedPairingController) {
			s.status.PairExpiresAt = time.Now().Add(-time.Minute).Format(time.RFC3339Nano)
		}, 503, "tailcat_pair_failed"},
		{"link", func(server testServer, _ *linkTestSidecar, _ *managedPairingController) {
			server.router.configPath += ".missing"
		}, 500, "tailcat_pair_link_failed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server, s, c := newLinkTestServer(t)
			tc.mutate(server, s, c)
			response := requestManagedPairingLink(t, server, false)
			assertLinkFailure(t, response, tc.status, tc.code)
			if tc.code == "tailcat_pair_failed" || tc.code == "tailcat_pair_link_failed" {
				if s.status.Mode != config.TailcatModeManaged {
					t.Fatal("配对失败不应撤销已经提交的模式切换")
				}
			} else if s.pairCalls != 0 {
				t.Fatal("前置步骤失败后仍发起了配对")
			}
		})
	}
}

func TestTailcatManagedPairingLinkSerializesLocalActionsAndClaims(t *testing.T) {
	server, s, _ := newLinkTestServer(t)
	entered, release := make(chan struct{}), make(chan struct{})
	var enterOnce sync.Once
	s.pairHook = func(context.Context) error { enterOnce.Do(func() { close(entered) }); <-release; return nil }
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	first := make(chan *httptest.ResponseRecorder, 1)
	go func() { first <- requestManagedPairingLink(t, server, false) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("配对未开始")
	}
	assertLinkFailure(t, requestManagedPairingLink(t, server, false), 409, "tailcat_operation_in_progress")
	// 本机模式切换和 claim 都必须等完整远程流程退出。锁在该请求期间一直不可获取。
	localDone, claimDone := make(chan struct{}), make(chan *httptest.ResponseRecorder, 1)
	go func() {
		defer close(localDone)
		req := authedRequest(t, http.MethodPost, "/api/local/tailcat", tailcatControlRequest{Action: "enter-managed"})
		server.router.tailcatLocalAction(httptest.NewRecorder(), req)
	}()
	ticket := auth.NewPairingTicket("http://127.0.0.1:8787", testToken, time.Now().Add(-time.Minute), time.Now().Add(time.Minute))
	go func() {
		claimDone <- performPairingClaim(t, server.handler, pairingClaimRequest{
			Endpoint: ticket.Endpoint, IssuedAt: ticket.IssuedAt, ExpiresAt: ticket.ExpiresAt, Signature: ticket.Signature,
			TailcatClientKey: testManagedOtherMobileKey,
		})
	}()
	select {
	case <-localDone:
		t.Fatal("本机控制越过了正在配对的远程请求")
	case <-claimDone:
		t.Fatal("claim 越过了正在配对的远程请求")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	response := <-first
	if response.Code != http.StatusOK {
		t.Fatalf("首个配对失败：%s", response.Body.String())
	}
	<-localDone
	assertLinkFailure(t, <-claimDone, 409, "tailcat_managed_grant_required")
}

func TestTailcatManagedPairingLinkValidationAndOperationLog(t *testing.T) {
	server, s, _ := newLinkTestServer(t)
	for _, body := range []string{``, `{"confirm_reset_self_hosted":"true"}`, `{"unknown":true}`, `{} {}`} {
		req := httptest.NewRequest(http.MethodPost, managedPairingLinkPath, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+testToken)
		response := httptest.NewRecorder()
		server.handler.ServeHTTP(response, req)
		if response.Code != http.StatusBadRequest || s.pairCalls != 0 {
			t.Fatal("非法请求触发了配对")
		}
	}
	var logs bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(previous) })
	response := requestManagedPairingLink(t, server, false)
	assertManagedPairingLink(t, response, server.router.configPath, server.router.decorateTailcatStatus(s.status))
	s.pairHook = func(context.Context) error {
		return errors.New(testToken + s.status.Address + s.status.PairAddress + s.status.PublicKey)
	}
	assertLinkFailure(t, requestManagedPairingLink(t, server, false), 503, "tailcat_pair_failed")
	if !strings.Contains(logs.String(), "tailcat managed pairing link: result=ok") {
		t.Fatal("缺少脱敏操作日志")
	}
	for _, secret := range []string{testToken, s.status.Address, s.status.PairAddress, s.status.PublicKey, s.status.PairPublicKey, server.router.configPath} {
		if strings.Contains(logs.String(), secret) {
			t.Fatal("操作日志泄露了敏感内容")
		}
	}
}
