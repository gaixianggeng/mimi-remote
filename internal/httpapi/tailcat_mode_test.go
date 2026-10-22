package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

const testOfficialRelayURL = "https://official.example.invalid/derp-map.json"

func buildModeTestSidecar(t *testing.T) string {
	t.Helper()
	name := "faketailcat"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	binary := filepath.Join(t.TempDir(), name)
	command := exec.Command("go", "build", "-o", binary, "./testdata/faketailcat")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("构建本机假 sidecar：%v\n%s", err, output)
	}
	return binary
}

func newModeTestHost(t *testing.T, binary, previous string, enabled bool) (*tailcatSidecarSupervisor, *managedPairingController) {
	t.Helper()
	// 控制 socket 路径必须低于 macOS 的长度上限。
	dir, err := os.MkdirTemp("", "tc-mode-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "config.json")
	cfg := config.Config{Listen: "127.0.0.1:8787", Tailcat: config.TailcatConfig{
		Enabled: enabled, SidecarBin: binary, DERPMapURL: previous, ManagedDERPMapURL: testOfficialRelayURL,
	}}
	cfg.Auth.Token = testToken
	data, _ := json.Marshal(cfg)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	s := newTailcatSidecarSupervisor(cfg, path)
	t.Cleanup(s.Close)
	if enabled {
		if err := s.Start(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	controller := modeTestController(t, s)
	return s, controller
}

func modeTestController(t *testing.T, s *tailcatSidecarSupervisor) *managedPairingController {
	t.Helper()
	c, err := newManagedPairingController(managedPairingControllerOptions{
		BaseURL: "https://control.example.invalid", StatePath: filepath.Join(s.stateDir, managedPairingStateFileName),
		InstallationID: testManagedInstallationID, Tailcat: s,
		HTTPClient: &http.Client{Transport: rejectModeTestNetwork{}},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c
}

type rejectModeTestNetwork struct{}

func (rejectModeTestNetwork) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("模式测试禁止访问网络")
}

func readModeTestConfig(t *testing.T, path string) config.Config {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var cfg config.Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	if err := cfg.Tailcat.Validate(); err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestTailcatManagedModeTransitionsAndRestart(t *testing.T) {
	binary := buildModeTestSidecar(t)
	for _, original := range []string{"", "https://custom.example.invalid/map", testOfficialRelayURL} {
		for _, enabled := range []bool{false, true} {
			t.Run(original+"/enabled="+map[bool]string{false: "false", true: "true"}[enabled], func(t *testing.T) {
				s, c := newModeTestHost(t, binary, original, enabled)
				old := s.Status(context.Background())
				if err := os.WriteFile(filepath.Join(s.stateDir, "clients.json"), []byte(`["free-client"]`), 0o600); err != nil {
					t.Fatal(err)
				}
				status, err := c.ConfigureMode(context.Background(), true)
				if err != nil {
					t.Fatal(err)
				}
				if status.Mode != config.TailcatModeManaged || status.DERPMapURL != testOfficialRelayURL || status.Enabled != enabled {
					t.Fatalf("进入托管模式失败：%+v", status)
				}
				if _, err := os.Stat(filepath.Join(s.stateDir, "clients.json")); !os.IsNotExist(err) {
					t.Fatalf("模式切换必须清空免费配对：%v", err)
				}
				if enabled {
					if status.PublicKey == old.PublicKey {
						t.Fatal("切换模式必须重建稳定身份")
					}
					assertManagedModePairQR(t, s)
					seedModeTestPolicy(t, c, s)
				}
				// 重复进入不覆盖进入前的原值，也不轮换身份。
				again, err := c.ConfigureMode(context.Background(), true)
				if err != nil || again.PublicKey != status.PublicKey {
					t.Fatalf("重复进入：%+v %v", again, err)
				}
				persisted := readModeTestConfig(t, s.configPath)
				if persisted.Tailcat.PreviousDERPMapURL != original {
					t.Fatal("进入前的中继未持久化")
				}
				s.Close()
				restarted := newTailcatSidecarSupervisor(persisted, s.configPath)
				t.Cleanup(restarted.Close)
				if enabled {
					if err := restarted.Start(context.Background()); err != nil {
						t.Fatal(err)
					}
					if got := restarted.Status(context.Background()); got.PublicKey != status.PublicKey {
						t.Fatal("重启不能轮换身份")
					}
				}
				restoredController := modeTestController(t, restarted)
				if enabled {
					if restoredController.state.HostID != testManagedHostID {
						t.Fatal("重启丢失托管注册")
					}
					// 不访问控制面，验证已有策略仍能按离线语义恢复到新进程。
					if err := restoredController.Sync(context.Background()); err == nil {
						t.Fatal("测试控制面应被禁止访问")
					}
					if restarted.Status(context.Background()).PairedDeviceCount != 1 {
						t.Fatal("重启后未恢复托管授权")
					}
				}
				status, err = restoredController.ConfigureMode(context.Background(), false)
				if err != nil {
					t.Fatal(err)
				}
				if status.Mode != config.TailcatModeSelfHosted || status.DERPMapURL != original || status.Enabled != enabled {
					t.Fatalf("退出未恢复原中继：%+v", status)
				}
				persisted = readModeTestConfig(t, s.configPath)
				if persisted.Tailcat.PreviousDERPMapURL != "" {
					t.Fatal("退出后仍保留过期原值")
				}
				again, err = restoredController.ConfigureMode(context.Background(), false)
				if err != nil || again.PublicKey != status.PublicKey {
					t.Fatalf("重复退出不能轮换身份：%v", err)
				}
				restarted.Close()
				afterExit := newTailcatSidecarSupervisor(persisted, s.configPath)
				t.Cleanup(afterExit.Close)
				if got := afterExit.Status(context.Background()); got.Mode != config.TailcatModeSelfHosted || got.DERPMapURL != original {
					t.Fatal("退出后的重启丢失模式")
				}

				if state, err := loadManagedPairingState(c.statePath); err != nil || state.HostID != "" || state.HostDeviceToken != "" {
					t.Fatalf("退出未清空托管注册：%+v %v", state, err)
				}
			})
		}
	}
}

func assertManagedModePairQR(t *testing.T, s *tailcatSidecarSupervisor) {
	t.Helper()
	status, err := s.Pair(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, address := range []string{status.Address, status.PairAddress} {
		parsed, err := url.Parse(address)
		if err != nil || parsed.Query().Get("relay") != testOfficialRelayURL {
			t.Fatalf("地址未使用托管中继：%q %v", address, err)
		}
	}
	result, err := agentsetup.TailcatPairWithManagedHost(s.configPath, status.PairAddress, testManagedInstallationID, status.PublicKey, status.PairPublicKey)
	if err != nil {
		t.Fatal(err)
	}
	link, err := url.Parse(result.PairURL)
	if err != nil {
		t.Fatal(err)
	}
	if link.Query().Get("tailcat_pair_address") != status.PairAddress || link.Query().Get("managed_mac_tailcat_public_key") != status.PublicKey {
		t.Fatal("二维码未绑定托管临时地址与稳定公钥")
	}
}

func seedModeTestPolicy(t *testing.T, c *managedPairingController, s *tailcatSidecarSupervisor) {
	t.Helper()
	state := managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: s.Status(context.Background()).PublicKey,
		PolicyVersion:       1, PolicyFetchedAt: time.Now().UTC().Format(time.RFC3339Nano),
		PolicyValidUntil:  time.Now().Add(time.Hour).UTC().Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}
	if err := c.saveStateLocked(state); err != nil {
		t.Fatal(err)
	}
	if _, err := c.applyRegisteredPolicyLocked(context.Background(), state.AllowedMobileKeys); err != nil {
		t.Fatal(err)
	}
}

func TestTailcatManagedModeFailureRestoresIdentityAndPolicy(t *testing.T) {
	binary := buildModeTestSidecar(t)
	for _, enter := range []bool{true, false} {
		for _, failure := range []string{"snapshot", "cancel", "start", "registration", "config"} {
			t.Run(map[bool]string{true: "enter", false: "exit"}[enter]+"/"+failure, func(t *testing.T) {
				s, c := newModeTestHost(t, binary, "https://custom.example.invalid/map", true)
				if !enter {
					if _, err := c.ConfigureMode(context.Background(), true); err != nil {
						t.Fatal(err)
					}
					seedModeTestPolicy(t, c, s)
				}
				if err := os.WriteFile(filepath.Join(s.stateDir, "clients.json"), []byte(`["free-client"]`), 0o600); err != nil {
					t.Fatal(err)
				}
				before := s.Status(context.Background())
				identity, err := snapshotTailcatIdentityState(s.stateDir)
				if err != nil {
					t.Fatal(err)
				}
				previousState := c.state
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				switch failure {
				case "snapshot":
					path := filepath.Join(s.stateDir, "pair.private.json")
					if err := os.Mkdir(path, 0o700); err != nil {
						t.Fatal(err)
					}
					defer os.Remove(path)
				case "cancel":
					cancel()
				case "start":
					nextURL := testOfficialRelayURL
					if !enter {
						nextURL = s.config.PreviousDERPMapURL
					}
					if err := os.WriteFile(filepath.Join(s.stateDir, "fail-start-url"), []byte(nextURL), 0o600); err != nil {
						t.Fatal(err)
					}
				case "registration":
					failed := false
					c.writeState = func(path string, state managedPairingState) error {
						if !failed {
							failed = true
							return errors.New("injected registration failure")
						}
						return writeManagedPairingState(path, state)
					}
				case "config":
					// 新身份已就绪、注册已清空后，让配置写入遇到真实文件系统错误。
					c.writeState = func(path string, state managedPairingState) error {
						if err := os.Rename(s.configPath, s.configPath+".before"); err != nil {
							return err
						}
						if err := os.Mkdir(s.configPath, 0o700); err != nil {
							return err
						}
						c.writeState = writeManagedPairingState
						return writeManagedPairingState(path, state)
					}

				}
				_, err = c.ConfigureMode(ctx, enter)
				if err == nil {
					t.Fatal("注入失败后不能成功")
				}
				if failure == "snapshot" {
					_ = os.Remove(filepath.Join(s.stateDir, "pair.private.json"))
				}
				if failure == "config" {
					if err := os.Remove(s.configPath); err != nil {
						t.Fatal(err)
					}
					if err := os.Rename(s.configPath+".before", s.configPath); err != nil {
						t.Fatal(err)
					}
				}
				persisted := readModeTestConfig(t, s.configPath)
				if persisted.Tailcat.ConnectionMode() != before.Mode || persisted.Tailcat.DERPMapURL != before.DERPMapURL {
					t.Fatal("失败后配置未恢复")
				}
				after := s.Status(context.Background())
				if !after.Running || after.Mode != before.Mode || after.DERPMapURL != before.DERPMapURL || after.PublicKey != before.PublicKey || after.Address != before.Address {
					t.Fatalf("未恢复运行身份：before=%+v after=%+v err=%v", before, after, err)
				}
				restored, snapErr := snapshotTailcatIdentityState(s.stateDir)
				if snapErr != nil || !reflect.DeepEqual(restored, identity) {
					t.Fatalf("身份或免费配对未恢复：%v", snapErr)
				}
				if !reflect.DeepEqual(c.state, previousState) {
					t.Fatal("原托管注册未恢复")
				}
				if !enter {
					loaded, err := loadManagedPairingState(c.statePath)
					if err != nil || !reflect.DeepEqual(loaded, previousState) {
						t.Fatalf("原策略磁盘记录未恢复：%v", err)
					}
				}
				if !enter {
					expectedCount := before.PairedDeviceCount
					if after.InstanceID != before.InstanceID {
						expectedCount = 2
					}
					if after.PairedDeviceCount != expectedCount {
						t.Fatalf("回滚后未重放托管白名单：got=%d want=%d", after.PairedDeviceCount, expectedCount)
					}
				}
			})
		}
	}
}

func TestTailcatManagedModeRejectsManualRelayConfiguration(t *testing.T) {
	s := &tailcatSidecarSupervisor{config: config.TailcatConfig{Mode: config.TailcatModeManaged, DERPMapURL: testOfficialRelayURL}}
	for _, value := range []string{"", testOfficialRelayURL, "not-a-url"} {
		if _, err := s.ConfigureDERPMap(context.Background(), value); !errors.Is(err, errTailcatManagedRelayLocked) {
			t.Fatalf("托管模式必须拒绝手动改中继：%v", err)
		}
	}
}

func TestManagedTailcatClaimRequiresManagedMode(t *testing.T) {
	server := newTestServer(t)
	fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, Mode: config.TailcatModeSelfHosted}}
	managed := &fakeManagedPairingService{}
	server.router.tailcat = fake
	server.router.managedPairing = managed
	now := time.Now().UTC()
	ticket := auth.NewPairingTicket("http://127.0.0.1:8787", testToken, now.Add(-time.Minute), now.Add(time.Minute))
	for _, fields := range [][2]string{{testManagedSessionID, managedToken('g')}, {testManagedSessionID, ""}, {"", managedToken('g')}} {
		response := performPairingClaim(t, server.handler, pairingClaimRequest{
			Endpoint: ticket.Endpoint, IssuedAt: ticket.IssuedAt, ExpiresAt: ticket.ExpiresAt, Signature: ticket.Signature,
			TailcatClientKey: testManagedMobileKey, ManagedSessionID: fields[0], ManagedGrant: fields[1],
		})
		if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), `"code":"tailcat_managed_mode_required"`) || !strings.Contains(response.Body.String(), "请先在电脑上进入托管模式") {
			t.Fatalf("未返回稳定错误：%d %s", response.Code, response.Body.String())
		}
	}
	if fake.allowCalls != 0 || managed.completeCall != 0 {
		t.Fatal("拒绝请求不能修改授权")
	}
}

func TestTailcatLocalModeActionsAndStatus(t *testing.T) {
	for _, action := range []string{"enter-managed", "exit-managed"} {
		t.Run(action, func(t *testing.T) {
			server := newTestServer(t)
			server.router.tailcat = &fakeTailcatSidecar{}
			mode := config.TailcatModeManaged
			if action == "exit-managed" {
				mode = config.TailcatModeSelfHosted
			}
			server.router.managedPairing = &fakeManagedPairingService{status: tailcatStatus{Mode: mode}}
			server.router.tailcatLocalToken = "local-only-token"
			req := authedRequest(t, http.MethodPost, "/api/local/tailcat", tailcatControlRequest{Action: action})
			req.RemoteAddr = "127.0.0.1:54321"
			req.Host = "127.0.0.1:8787"
			req.Header.Set(TailcatLocalControlHeader, "local-only-token")
			response := httptest.NewRecorder()
			server.handler.ServeHTTP(response, req)
			if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"mode":"`+mode+`"`) {
				t.Fatalf("模式接口失败：%d %s", response.Code, response.Body.String())
			}
		})
	}
}

func TestManagedPairingControllerRequiresModeBeforeCloudCompletion(t *testing.T) {
	fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, Address: "tailcat:stable", PublicKey: testManagedMacKey}}
	c := newManagedControllerForTest(t, "https://control.example.invalid", fake, nil, nil)
	c.httpClient.Transport = rejectModeTestNetwork{}
	fake.status.Mode = config.TailcatModeSelfHosted
	_, err := c.Complete(context.Background(), testManagedSessionID, managedToken('g'), testManagedMobileKey)
	if !errors.Is(err, errTailcatManagedModeRequired) || c.state.HostDeviceToken != "" || fake.managedCalls != 0 {
		t.Fatalf("控制器应在持锁后、生成凭据前拒绝自建模式：%v", err)
	}
}

func TestManagedPairingClearsLegacyRegistrationWithoutChangingMode(t *testing.T) {
	fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, PublicKey: testManagedMacKey}}
	c := newManagedControllerForTest(t, "https://control.example.invalid", fake, nil, nil)
	c.httpClient.Transport = rejectModeTestNetwork{}
	c.state = managedPairingState{Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'), MacTailcatPublicKey: testManagedMacKey, AllowedMobileKeys: []string{testManagedMobileKey}}
	fake.status.Mode = config.TailcatModeSelfHosted
	if err := c.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if c.state.HostID != "" || fake.managedKeys != nil || fake.status.Mode != config.TailcatModeSelfHosted {
		t.Fatal("旧注册未撤销或发生了自动模式切换")
	}
}

func TestManagedPairingResetRevocationAndIdentityMismatchKeepManagedMode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusForbidden, map[string]string{"code": "host_revoked"})
	}))
	defer server.Close()
	for _, action := range []string{"reset", "revocation", "identity"} {
		t.Run(action, func(t *testing.T) {
			fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, PublicKey: testManagedMacKey, DERPMapURL: testOfficialRelayURL}}
			c := newManagedControllerForTest(t, server.URL, fake, nil, nil)
			c.state = managedPairingState{Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'), MacTailcatPublicKey: testManagedMacKey, AllowedMobileKeys: []string{testManagedMobileKey}}
			switch action {
			case "reset":
				if err := c.Reset(context.Background()); err != nil {
					t.Fatal(err)
				}
			case "revocation":
				if err := c.Sync(context.Background()); err == nil {
					t.Fatal("应报告云端撤销")
				}
			case "identity":
				fake.status.PublicKey = "nodekey:" + strings.Repeat("e", 64)
				if err := c.Sync(context.Background()); err == nil {
					t.Fatal("应报告身份变化")
				}
			}
			if fake.status.Mode != config.TailcatModeManaged || fake.status.DERPMapURL != testOfficialRelayURL || len(fake.managedKeys) != 0 {
				t.Fatal("撤销、身份变化或重置不能退出托管模式")
			}
		})
	}
}

func TestTailcatLocalConfigureRejectsManagedRelayWithStableCode(t *testing.T) {
	server := newTestServer(t)
	server.router.tailcat = &fakeTailcatSidecar{operationErr: errTailcatManagedRelayLocked}
	managed := &fakeManagedPairingService{}
	server.router.managedPairing = managed
	request := httptest.NewRequest(http.MethodPost, "/api/local/tailcat", strings.NewReader(`{"action":"configure","derp_map_url":""}`))
	response := httptest.NewRecorder()
	server.router.tailcatLocalAction(response, request)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), `"code":"tailcat_managed_relay_locked"`) {
		t.Fatalf("托管模式应返回明确冲突：%d %s", response.Code, response.Body.String())
	}
	if managed.syncCalls != 0 {
		t.Fatal("拒绝手动改中继不应访问控制面")
	}
}

func TestManagedModeRejectsTailcatClaimWithoutManagedGrant(t *testing.T) {
	server := newTestServer(t)
	fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, Mode: config.TailcatModeManaged, Address: "managed-address"}}
	managed := &fakeManagedPairingService{}
	server.router.tailcat = fake
	server.router.managedPairing = managed
	now := time.Now().UTC()
	ticket := auth.NewPairingTicket("http://127.0.0.1:8787", testToken, now.Add(-time.Minute), now.Add(time.Minute))
	// 签名票据不覆盖托管字段：去掉它们的托管二维码 claim 不能落进免费白名单。
	response := performPairingClaim(t, server.handler, pairingClaimRequest{
		Endpoint: ticket.Endpoint, IssuedAt: ticket.IssuedAt, ExpiresAt: ticket.ExpiresAt, Signature: ticket.Signature,
		TailcatClientKey: testManagedMobileKey,
	})
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), `"code":"tailcat_managed_grant_required"`) {
		t.Fatalf("托管模式下未拒绝不带授权的 claim：%d %s", response.Code, response.Body.String())
	}
	if fake.allowCalls != 0 || managed.completeCall != 0 {
		t.Fatal("拒绝请求不能修改授权")
	}
}

func TestManagedModeSidecarRefusesFreeAllowlistAndReconcilesChangedRelay(t *testing.T) {
	binary := buildModeTestSidecar(t)
	s, c := newModeTestHost(t, binary, "https://custom.example.invalid/map", true)
	entered, err := c.ConfigureMode(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	// 绕过路由直接调用也不能写免费白名单：检查与写入都在 operationMu 内。
	if _, err := s.AllowClient(context.Background(), testManagedMobileKey); !errors.Is(err, errTailcatManagedGrantRequired) {
		t.Fatalf("托管模式下 AllowClient 必须拒绝：%v", err)
	}
	if _, err := os.Stat(filepath.Join(s.stateDir, "clients.json")); !os.IsNotExist(err) {
		t.Fatalf("托管模式不能留下免费白名单：%v", err)
	}

	// 以后的版本或配置覆盖换了托管地址：启动容忍不一致，再次进入托管模式时收敛到新地址。
	const changedRelay = "https://official-next.example.invalid/derp-map.json"
	raw, err := os.ReadFile(s.configPath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	document["tailcat"].(map[string]any)["managed_derp_map_url"] = changedRelay
	updated, _ := json.Marshal(document)
	if err := os.WriteFile(s.configPath, updated, 0o600); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	s.config.ManagedDERPMapURL = changedRelay
	s.mu.Unlock()

	reconciled, err := c.ConfigureMode(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	if reconciled.Mode != config.TailcatModeManaged || reconciled.DERPMapURL != changedRelay {
		t.Fatalf("未收敛到新的托管中继：%+v", reconciled)
	}
	if reconciled.PublicKey == entered.PublicKey {
		t.Fatal("更换托管中继必须重建身份")
	}
	persisted := readModeTestConfig(t, s.configPath)
	if persisted.Tailcat.DERPMapURL != changedRelay || persisted.Tailcat.PreviousDERPMapURL != "https://custom.example.invalid/map" {
		t.Fatalf("收敛后持久化不对：%+v", persisted.Tailcat)
	}
	again, err := c.ConfigureMode(context.Background(), true)
	if err != nil || again.PublicKey != reconciled.PublicKey {
		t.Fatalf("地址一致时再次进入不能轮换身份：%+v %v", again, err)
	}
}
