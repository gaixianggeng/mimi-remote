package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

const (
	testManagedInstallationID = "20000000-0000-4000-8000-000000000001"
	testManagedSessionID      = "30000000-0000-4000-8000-000000000001"
	testManagedHostID         = "40000000-0000-4000-8000-000000000001"
	testManagedMacKey         = "nodekey:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testManagedMobileKey      = "nodekey:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	testManagedOtherMobileKey = "nodekey:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
)

func managedToken(fill byte) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strings.Repeat(string([]byte{fill}), 32)))
}

func newManagedControllerForTest(
	t *testing.T,
	serverURL string,
	fake *fakeTailcatSidecar,
	now func() time.Time,
	writeState func(string, managedPairingState) error,
) *managedPairingController {
	t.Helper()
	controller, err := newManagedPairingController(managedPairingControllerOptions{
		BaseURL:        serverURL,
		StatePath:      filepath.Join(t.TempDir(), managedPairingStateFileName),
		InstallationID: testManagedInstallationID,
		Tailcat:        fake,
		Now:            now,
		Random:         strings.NewReader(strings.Repeat("h", 64)),
		WriteState:     writeState,
	})
	if err != nil {
		t.Fatal(err)
	}
	return controller
}

func TestManagedPairingCompletesCloudAuthorizationBeforeApplyingPolicy(t *testing.T) {
	now := time.Date(2026, 9, 4, 10, 0, 0, 0, time.UTC)
	grant := managedToken('g')
	var hostToken string
	var calls []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		calls = append(calls, request.Method+" "+request.URL.Path)
		switch request.URL.Path {
		case "/v1/pairing-sessions/" + testManagedSessionID + "/complete":
			var body map[string]string
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			hostToken = body["hostDeviceToken"]
			if body["macInstallationId"] != testManagedInstallationID ||
				body["macTailcatPublicKey"] != testManagedMacKey ||
				body["managedPairingGrant"] != grant {
				t.Fatalf("完成配对请求异常：%v", body)
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, `{"host":{"id":"`+testManagedHostID+`"},"status":"completed","created":true}`)
		case "/v1/hosts/" + testManagedHostID + "/policy":
			if request.Header.Get("Authorization") != "Bearer "+hostToken {
				t.Fatal("读取策略未使用刚持久化的 Mac 设备凭证")
			}
			_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":1,"validUntil":"2026-09-04T10:10:00Z","allowedMobileTailcatPublicKeys":["`+testManagedMobileKey+`"]}`)
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, Address: "tailcat:stable", PublicKey: testManagedMacKey,
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)

	status, err := controller.Complete(context.Background(), testManagedSessionID, grant, testManagedMobileKey)
	if err != nil {
		t.Fatal(err)
	}
	if status.Address != "tailcat:stable" || !reflect.DeepEqual(fake.managedKeys, []string{testManagedMobileKey}) {
		t.Fatalf("未应用云端授权策略：status=%+v keys=%v", status, fake.managedKeys)
	}
	if !reflect.DeepEqual(calls, []string{
		"POST /v1/pairing-sessions/" + testManagedSessionID + "/complete",
		"GET /v1/hosts/" + testManagedHostID + "/policy",
	}) {
		t.Fatalf("云端调用顺序异常：%v", calls)
	}
	if hostToken == "" || hostToken == grant {
		t.Fatal("Mac 必须生成独立于移动端 Grant 的设备凭证")
	}
	info, err := os.Stat(controller.statePath)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("托管策略权限为 %o，预期 0600", info.Mode().Perm())
	}
	raw, err := os.ReadFile(controller.statePath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), grant) {
		t.Fatal("短期 managed_pairing_grant 不能写入本地策略")
	}
}

func TestManagedPolicyRevocationReplacesRuntimeAllowlist(t *testing.T) {
	now := time.Date(2026, 9, 4, 11, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":2,"validUntil":"2026-09-04T11:10:00Z","allowedMobileTailcatPublicKeys":[]}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, PublicKey: testManagedMacKey}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-5 * time.Minute).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}
	controller.hasApplied = true
	controller.appliedHostKey = testManagedMacKey
	controller.appliedKeys = []string{testManagedMobileKey}

	if err := controller.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 {
		t.Fatalf("撤销后应立即应用空托管白名单：calls=%d keys=%v", fake.managedCalls, fake.managedKeys)
	}
	loaded, err := loadManagedPairingState(controller.statePath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.PolicyVersion != 2 || len(loaded.AllowedMobileKeys) != 0 {
		t.Fatalf("撤销策略未原子持久化：%+v", loaded)
	}
}

func TestManagedPolicyUsesCacheFor24HoursThenFailsClosed(t *testing.T) {
	now := time.Date(2026, 9, 4, 12, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "temporary", http.StatusServiceUnavailable)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, PublicKey: testManagedMacKey}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-23 * time.Hour).Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(3 * time.Hour).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	if err := controller.Sync(context.Background()); err == nil {
		t.Fatal("控制面故障应保留可观察错误")
	}
	if !reflect.DeepEqual(fake.managedKeys, []string{testManagedMobileKey}) {
		t.Fatalf("24 小时内应使用最后有效策略：%v", fake.managedKeys)
	}
	now = now.Add(2 * time.Hour)
	if err := controller.Sync(context.Background()); err == nil {
		t.Fatal("缓存超过 24 小时仍应报告控制面故障")
	}
	if len(fake.managedKeys) != 0 {
		t.Fatalf("缓存超过 24 小时必须清空托管授权：%v", fake.managedKeys)
	}
}

func TestManagedPolicyCacheStopsAtServerValidityDeadline(t *testing.T) {
	now := time.Date(2026, 9, 4, 12, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "temporary", http.StatusServiceUnavailable)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, PublicKey: testManagedMacKey}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-time.Hour).Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(-time.Second).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	if err := controller.Sync(context.Background()); err == nil {
		t.Fatal("服务端策略有效期已过时仍应报告控制面故障")
	}
	if len(fake.managedKeys) != 0 {
		t.Fatalf("服务端策略有效期已过时必须清空托管授权：%v", fake.managedKeys)
	}
}

func TestManagedPolicyWriteFailureNeverAppliesNewAuthorization(t *testing.T) {
	now := time.Date(2026, 9, 4, 13, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Method == http.MethodPost {
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, `{"host":{"id":"`+testManagedHostID+`"}}`)
			return
		}
		_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":1,"validUntil":"2026-09-04T13:10:00Z","allowedMobileTailcatPublicKeys":["`+testManagedMobileKey+`"]}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, Address: "tailcat:stable", PublicKey: testManagedMacKey,
	}}
	writes := 0
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, func(path string, state managedPairingState) error {
		writes++
		if writes == 3 {
			return errors.New("disk full")
		}
		return writeManagedPairingState(path, state)
	})

	_, err := controller.Complete(context.Background(), testManagedSessionID, managedToken('g'), testManagedMobileKey)
	if err == nil || !strings.Contains(err.Error(), "disk full") {
		t.Fatalf("策略写入失败应中止托管配对：%v", err)
	}
	if fake.managedCalls != 0 {
		t.Fatal("新策略落盘失败时不能先修改运行中白名单")
	}
}

func TestManagedPairingCloudRejectionsNeverApplyAuthorization(t *testing.T) {
	for _, testCase := range []struct {
		name   string
		status int
		code   string
	}{
		{name: "invalid grant", status: http.StatusUnauthorized, code: "pairing_grant_invalid"},
		{name: "revoked mobile", status: http.StatusForbidden, code: "pairing_not_authorized"},
		{name: "expired grant", status: http.StatusGone, code: "pairing_session_expired"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(testCase.status)
				_, _ = io.WriteString(w, `{"code":"`+testCase.code+`","message":"request rejected"}`)
			}))
			defer server.Close()
			fake := &fakeTailcatSidecar{status: tailcatStatus{
				Running: true, Address: "tailcat:stable", PublicKey: testManagedMacKey,
			}}
			controller := newManagedControllerForTest(t, server.URL, fake, time.Now, nil)

			_, err := controller.Complete(
				context.Background(),
				testManagedSessionID,
				managedToken('g'),
				testManagedMobileKey,
			)
			if !isManagedCloudCode(err, testCase.code) {
				t.Fatalf("应原样保留稳定云端错误码 %q：%v", testCase.code, err)
			}
			if fake.managedCalls != 0 {
				t.Fatal("云端拒绝后不能写入稳定 Tailcat 白名单")
			}
		})
	}
}

func TestManagedPolicyUnauthorizedClearsAuthorizationImmediately(t *testing.T) {
	now := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"code":"unauthorized","message":"主机凭证无效或已过期"}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{Running: true, PublicKey: testManagedMacKey}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	if err := controller.Sync(context.Background()); err == nil {
		t.Fatal("撤销的主机凭证应报告未授权")
	}
	if len(fake.managedKeys) != 0 || !controller.state.AuthorizationInvalid {
		t.Fatalf("服务端明确撤销应立即清空策略：keys=%v state=%+v", fake.managedKeys, controller.state)
	}
}

func TestManagedPolicyRevocationFailsClosedEvenWhenStateWriteFails(t *testing.T) {
	now := time.Date(2026, 9, 4, 14, 30, 0, 0, time.UTC)
	revoked := true
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if revoked {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"code":"unauthorized"}`)
			return
		}
		http.Error(w, "temporary", http.StatusServiceUnavailable)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, func(string, managedPairingState) error {
		return errors.New("disk full")
	})
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(time.Hour).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	err := controller.Sync(context.Background())
	if err == nil || !strings.Contains(err.Error(), "disk full") {
		t.Fatalf("撤销落盘失败应返回明确错误：%v", err)
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 {
		t.Fatalf("磁盘故障不能阻止运行时撤销：calls=%d keys=%v", fake.managedCalls, fake.managedKeys)
	}
	if !controller.state.AuthorizationInvalid || len(controller.state.AllowedMobileKeys) != 0 {
		t.Fatalf("撤销落盘失败后内存状态仍必须失效：%+v", controller.state)
	}
	revoked = false
	if err := controller.Sync(context.Background()); err == nil {
		t.Fatal("撤销后的临时控制面故障仍应报告错误")
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 {
		t.Fatalf("撤销落盘失败后不能从旧缓存恢复权限：calls=%d keys=%v", fake.managedCalls, fake.managedKeys)
	}
}

func TestManagedPolicyInvalidCloudResponseDoesNotReuseCache(t *testing.T) {
	now := time.Date(2026, 9, 4, 14, 45, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":0,"validUntil":"2026-09-04T14:55:00Z","allowedMobileTailcatPublicKeys":["`+testManagedMobileKey+`"]}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-time.Minute).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	if err := controller.Sync(context.Background()); err == nil {
		t.Fatal("控制面返回无效策略时必须报告错误")
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 || !controller.state.AuthorizationInvalid {
		t.Fatalf("明确无效的云端策略不能沿用离线缓存：calls=%d keys=%v state=%+v", fake.managedCalls, fake.managedKeys, controller.state)
	}
}

func TestManagedPolicyRejectsMalformedTailcatPublicKey(t *testing.T) {
	now := time.Date(2026, 9, 4, 14, 47, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":2,"validUntil":"2026-09-04T14:57:00Z","allowedMobileTailcatPublicKeys":["not-a-key"]}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-time.Minute).Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(time.Hour).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	err := controller.Sync(context.Background())
	if err == nil || !strings.Contains(err.Error(), "无效 Tailcat 公钥") {
		t.Fatalf("格式错误的 Tailcat 公钥应被明确拒绝：%v", err)
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 || !controller.state.AuthorizationInvalid {
		t.Fatalf("格式错误的公钥必须清空旧授权：calls=%d keys=%v state=%+v", fake.managedCalls, fake.managedKeys, controller.state)
	}
}

func TestManagedPolicyMalformedSuccessResponseDoesNotReuseCache(t *testing.T) {
	now := time.Date(2026, 9, 4, 14, 48, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"hostId":`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-time.Minute).Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(time.Hour).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	err := controller.Sync(context.Background())
	if err == nil || !strings.Contains(err.Error(), "解析 Mimi 托管服务响应失败") {
		t.Fatalf("损坏的成功响应应被明确拒绝：%v", err)
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 || !controller.state.AuthorizationInvalid {
		t.Fatalf("损坏的成功响应不能沿用缓存：calls=%d keys=%v state=%+v", fake.managedCalls, fake.managedKeys, controller.state)
	}
}

func TestManagedPolicyPersistsInvalidationBeforeClearingRuntime(t *testing.T) {
	now := time.Date(2026, 9, 4, 14, 49, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"code":"unauthorized"}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	persistedBeforeRuntimeClear := false
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, func(path string, state managedPairingState) error {
		persistedBeforeRuntimeClear = state.AuthorizationInvalid && len(state.AllowedMobileKeys) == 0 && fake.managedCalls == 0
		return writeManagedPairingState(path, state)
	})
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-time.Minute).Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(time.Hour).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	if err := controller.Sync(context.Background()); err == nil {
		t.Fatal("撤销应返回未授权错误")
	}
	if !persistedBeforeRuntimeClear || fake.managedCalls != 1 || len(fake.managedKeys) != 0 {
		t.Fatalf("必须先持久化失效标记再清空运行时授权：persisted=%t calls=%d keys=%v", persistedBeforeRuntimeClear, fake.managedCalls, fake.managedKeys)
	}
}

func TestManagedPolicyCanonicalizesAllowlistOrder(t *testing.T) {
	now := time.Date(2026, 9, 4, 14, 50, 0, 0, time.UTC)
	requestCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requestCount++
		keys := `[` + `"` + testManagedMobileKey + `","` + testManagedOtherMobileKey + `"]`
		if requestCount == 2 {
			keys = `[` + `"` + testManagedOtherMobileKey + `","` + testManagedMobileKey + `"]`
		}
		_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":1,"validUntil":"2026-09-04T15:00:00Z","allowedMobileTailcatPublicKeys":`+keys+`}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey,
	}

	if err := controller.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := controller.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if fake.managedCalls != 1 {
		t.Fatalf("白名单仅顺序变化时不应重启稳定主机：calls=%d", fake.managedCalls)
	}
	if !reflect.DeepEqual(controller.state.AllowedMobileKeys, []string{testManagedMobileKey, testManagedOtherMobileKey}) {
		t.Fatalf("白名单未按 canonical 顺序保存：%v", controller.state.AllowedMobileKeys)
	}
}

func TestManagedPolicyRejectsVersionRollback(t *testing.T) {
	now := time.Date(2026, 9, 4, 14, 50, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":1,"validUntil":"2026-09-04T15:00:00Z","allowedMobileTailcatPublicKeys":["`+testManagedMobileKey+`"]}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 2,
		PolicyFetchedAt:   now.Add(-time.Minute).Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(time.Hour).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	err := controller.Sync(context.Background())
	if err == nil || !strings.Contains(err.Error(), "版本发生回退") {
		t.Fatalf("旧策略版本应被明确拒绝：%v", err)
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 || !controller.state.AuthorizationInvalid {
		t.Fatalf("旧策略版本不能继续授权：calls=%d keys=%v state=%+v", fake.managedCalls, fake.managedKeys, controller.state)
	}
}

func TestManagedPolicyReappliesAfterTailcatSidecarRestart(t *testing.T) {
	now := time.Date(2026, 9, 4, 15, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":1,"validUntil":"2026-09-04T15:10:00Z","allowedMobileTailcatPublicKeys":["`+testManagedMobileKey+`"]}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey,
	}

	if err := controller.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := controller.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if fake.managedCalls != 1 {
		t.Fatalf("同一 sidecar 实例不应重复重启稳定主机：calls=%d", fake.managedCalls)
	}
	fake.status.InstanceID = "sidecar-b"
	if err := controller.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if fake.managedCalls != 2 || !reflect.DeepEqual(fake.managedKeys, []string{testManagedMobileKey}) {
		t.Fatalf("sidecar 重启后必须重放最后有效策略：calls=%d keys=%v", fake.managedCalls, fake.managedKeys)
	}
}

func TestManagedPairingRotatesRevokedHostTokenOnceAndFailsClosedDuringRetry(t *testing.T) {
	now := time.Date(2026, 9, 4, 16, 0, 0, 0, time.UTC)
	oldToken := managedToken('o')
	newToken := managedToken('h')
	completionCalls := 0
	var fake *fakeTailcatSidecar
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/v1/pairing-sessions/" + testManagedSessionID + "/complete":
			completionCalls++
			var body map[string]string
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if completionCalls == 1 {
				if body["hostDeviceToken"] != oldToken {
					t.Fatalf("第一次重试前应使用已持久化凭证：%v", body)
				}
				w.WriteHeader(http.StatusConflict)
				_, _ = io.WriteString(w, `{"code":"host_token_conflict","message":"Mac 已撤销"}`)
				return
			}
			if body["hostDeviceToken"] != newToken {
				t.Fatalf("第二次请求应使用新生成凭证：%v", body)
			}
			if fake.managedCalls != 1 || len(fake.managedKeys) != 0 {
				t.Fatalf("替换凭证前必须先清空运行时授权：calls=%d keys=%v", fake.managedCalls, fake.managedKeys)
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, `{"host":{"id":"`+testManagedHostID+`"}}`)
		case "/v1/hosts/" + testManagedHostID + "/policy":
			_, _ = io.WriteString(w, `{"hostId":"`+testManagedHostID+`","policyVersion":2,"validUntil":"2026-09-04T16:10:00Z","allowedMobileTailcatPublicKeys":["`+testManagedMobileKey+`"]}`)
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()
	fake = &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, Address: "tailcat:stable", PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: oldToken,
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-time.Minute).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	if _, err := controller.Complete(context.Background(), testManagedSessionID, managedToken('g'), testManagedMobileKey); err != nil {
		t.Fatal(err)
	}
	if completionCalls != 2 || controller.state.HostDeviceToken != newToken || fake.managedCalls != 2 {
		t.Fatalf("撤销后重新登记未完成单次凭证轮换：completions=%d calls=%d state=%+v", completionCalls, fake.managedCalls, controller.state)
	}
}

func TestManagedPairingHostTokenConflictClearsRuntimeWhenRotationWriteFails(t *testing.T) {
	now := time.Date(2026, 9, 4, 16, 30, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = io.WriteString(w, `{"code":"host_token_conflict","message":"Mac 已撤销"}`)
	}))
	defer server.Close()
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, Address: "tailcat:stable", PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	controller := newManagedControllerForTest(t, server.URL, fake, func() time.Time { return now }, func(string, managedPairingState) error {
		return errors.New("disk full")
	})
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('o'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Add(-time.Minute).Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(time.Hour).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	_, err := controller.Complete(context.Background(), testManagedSessionID, managedToken('g'), testManagedMobileKey)
	if err == nil || !strings.Contains(err.Error(), "disk full") {
		t.Fatalf("新凭证落盘失败应返回明确错误：%v", err)
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 {
		t.Fatalf("新凭证落盘失败仍必须清空运行时授权：calls=%d keys=%v", fake.managedCalls, fake.managedKeys)
	}
	if controller.state.HostID != "" || controller.state.HostDeviceToken != "" || len(controller.state.AllowedMobileKeys) != 0 {
		t.Fatalf("新凭证落盘失败仍必须丢弃旧登记：%+v", controller.state)
	}
}

func TestManagedPolicyClearsRegistrationWhenMacTailcatIdentityChanges(t *testing.T) {
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: "nodekey:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", InstanceID: "sidecar-b",
	}}
	controller := newManagedControllerForTest(t, "http://127.0.0.1", fake, time.Now, nil)
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   time.Now().UTC().Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	err := controller.Sync(context.Background())
	if err == nil || !strings.Contains(err.Error(), "身份已改变") {
		t.Fatalf("Mac Tailcat 身份变化应要求重新配对：%v", err)
	}
	if controller.state.HostID != "" || fake.managedCalls != 1 || len(fake.managedKeys) != 0 {
		t.Fatalf("身份变化后必须清空登记和运行时授权：state=%+v calls=%d keys=%v", controller.state, fake.managedCalls, fake.managedKeys)
	}
}

func TestManagedPairingResetStaysClearedWhenStateWriteFails(t *testing.T) {
	now := time.Date(2026, 9, 4, 17, 0, 0, 0, time.UTC)
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, PublicKey: testManagedMacKey, InstanceID: "sidecar-a",
	}}
	persistAttemptedBeforeRuntimeClear := false
	controller := newManagedControllerForTest(t, "http://127.0.0.1", fake, func() time.Time { return now }, func(string, managedPairingState) error {
		persistAttemptedBeforeRuntimeClear = fake.managedCalls == 0
		return errors.New("disk full")
	})
	controller.state = managedPairingState{
		Version: 1, HostID: testManagedHostID, HostDeviceToken: managedToken('h'),
		MacTailcatPublicKey: testManagedMacKey, PolicyVersion: 1,
		PolicyFetchedAt:   now.Format(time.RFC3339Nano),
		PolicyValidUntil:  now.Add(time.Hour).Format(time.RFC3339Nano),
		AllowedMobileKeys: []string{testManagedMobileKey},
	}

	err := controller.Reset(context.Background())
	if err == nil || !strings.Contains(err.Error(), "disk full") {
		t.Fatalf("重置落盘失败应返回明确错误：%v", err)
	}
	if !persistAttemptedBeforeRuntimeClear || controller.state.HostID != "" || len(controller.state.AllowedMobileKeys) != 0 {
		t.Fatalf("重置落盘失败后内存登记仍必须清空：%+v", controller.state)
	}
	if fake.managedCalls != 1 || len(fake.managedKeys) != 0 {
		t.Fatalf("重置落盘失败不能保留运行时授权：calls=%d keys=%v", fake.managedCalls, fake.managedKeys)
	}
	if err := controller.Sync(context.Background()); err != nil || fake.managedCalls != 1 {
		t.Fatalf("后台同步不能恢复已重置授权：err=%v calls=%d", err, fake.managedCalls)
	}
}

func TestValidManagedTailcatPublicKeyRequiresCanonicalNodeKey(t *testing.T) {
	for _, value := range []string{
		"",
		"not-a-key",
		"nodekey:" + strings.Repeat("0", 64),
		"nodekey:" + strings.Repeat("A", 64),
		"nodekey:" + strings.Repeat("a", 63),
		" nodekey:" + strings.Repeat("a", 64),
	} {
		if validManagedTailcatPublicKey(value) {
			t.Fatalf("应拒绝非 canonical Tailcat 公钥：%q", value)
		}
	}
	if !validManagedTailcatPublicKey(testManagedMobileKey) {
		t.Fatal("应接受 canonical Tailcat 节点公钥")
	}
}

func TestManagedPairingRejectsNonV4SessionBeforeCloudRequest(t *testing.T) {
	fake := &fakeTailcatSidecar{status: tailcatStatus{
		Running: true, Address: "tailcat:stable", PublicKey: testManagedMacKey,
	}}
	controller := newManagedControllerForTest(t, "http://127.0.0.1", fake, time.Now, nil)

	_, err := controller.Complete(
		context.Background(),
		"30000000-0000-1000-8000-000000000001",
		managedToken('g'),
		testManagedMobileKey,
	)
	if err == nil || !strings.Contains(err.Error(), "会话无效") || fake.managedCalls != 0 {
		t.Fatalf("非 UUID v4 会话必须在修改策略前拒绝：err=%v calls=%d", err, fake.managedCalls)
	}
}

func TestLoadManagedPairingStateRejectsIncompleteHostIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), managedPairingStateFileName)
	if err := writeManagedPairingState(path, managedPairingState{
		Version: 1, HostID: testManagedHostID, MacTailcatPublicKey: testManagedMacKey,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := loadManagedPairingState(path); err == nil {
		t.Fatal("已登记主机缺少设备凭证时必须拒绝加载")
	}

	if err := writeManagedPairingState(path, managedPairingState{
		Version: 1, HostDeviceToken: managedToken('h'), AllowedMobileKeys: []string{testManagedMobileKey},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := loadManagedPairingState(path); err == nil {
		t.Fatal("缺少主机身份的孤立策略必须拒绝加载")
	}
}
