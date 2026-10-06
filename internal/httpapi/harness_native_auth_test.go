package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// restartedDeepSeekHarness 模拟重启过的 Harness：只认本次进程的 token，token 文件里还是旧的。
func restartedDeepSeekHarness(t *testing.T) (*Router, *fakeDeepSeekHarness, string) {
	t.Helper()
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionModelCatalog, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return json.RawMessage(`{"groups":[{"id":"fixture","models":[{"id":"model-a"}]}]}`), nil
	})
	server := harness.serve()
	tokenPath := writeDeepSeekTestTokenFile(t, "token-from-previous-harness-process")
	router := &Router{cfg: config.Config{DeepSeek: config.DeepSeekConfig{
		Enabled: true, BaseURL: server.URL, TokenFile: tokenPath,
	}}}
	return router, harness, tokenPath
}

// replaceDeepSeekTestToken 与生产路径一样原子替换 token 文件，并发读者不会读到半截内容。
func replaceDeepSeekTestToken(path, token string) error {
	staged := path + ".staged"
	if err := os.WriteFile(staged, []byte(token), 0o600); err != nil {
		return err
	}
	return os.Rename(staged, path)
}

func TestDeepSeekRuntimeStatusRenewsCredentialAfterHarnessRestart(t *testing.T) {
	router, harness, tokenPath := restartedDeepSeekHarness(t)
	var renewals atomic.Int32
	router.deepSeekCredential.renew = func(context.Context) error {
		renewals.Add(1)
		return replaceDeepSeekTestToken(tokenPath, harness.token)
	}

	status := router.probeDeepSeekRuntime(context.Background())
	if status.State != runtimeStateAvailable || status.Reason != "ready" {
		t.Fatalf("换上新凭据后应恢复可用：%+v", status)
	}
	if renewals.Load() != 1 {
		t.Fatalf("应恰好重新发现一次，实际 %d 次", renewals.Load())
	}
}

func TestDeepSeekRuntimeStatusReportsRejectedCredentialAndCoolsDown(t *testing.T) {
	router, _, _ := restartedDeepSeekHarness(t)
	var renewals atomic.Int32
	router.deepSeekCredential.renew = func(context.Context) error {
		renewals.Add(1)
		return errors.New("启动日志已被清理")
	}

	for range 3 {
		status := router.probeDeepSeekRuntime(context.Background())
		if status.State != runtimeStateSignedOut || status.Reason != deepSeekCredentialsRejectedReason {
			t.Fatalf("自动更新失败时应提示更新启动凭据：%+v", status)
		}
		if !runtimeStatusHasFailure(runtimeStatusResponse{Runtimes: []runtimeAccountStatus{status}}) {
			t.Fatal("凭据被拒必须按失败快照短期缓存，恢复后才能尽快反映")
		}
	}
	if renewals.Load() != 1 {
		t.Fatalf("冷却期内不得反复执行重新发现，实际 %d 次", renewals.Load())
	}
}

func TestDeepSeekCredentialRenewalRunsOnceForConcurrentRejections(t *testing.T) {
	router, harness, tokenPath := restartedDeepSeekHarness(t)
	var renewals atomic.Int32
	router.deepSeekCredential.renew = func(context.Context) error {
		renewals.Add(1)
		time.Sleep(50 * time.Millisecond)
		return replaceDeepSeekTestToken(tokenPath, harness.token)
	}

	const callers = 8
	var wg sync.WaitGroup
	errs := make(chan error, callers)
	for range callers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := router.authenticatedDeepSeekClient(context.Background())
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("并发请求在凭据更新后都应认证成功：%v", err)
		}
	}
	if renewals.Load() != 1 {
		t.Fatalf("并发 401 只能触发一次重新发现，实际 %d 次", renewals.Load())
	}
}

func TestDeepSeekOfflineHarnessDoesNotTriggerCredentialRenewal(t *testing.T) {
	offline := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	baseURL := offline.URL
	offline.Close()
	router := &Router{cfg: config.Config{DeepSeek: config.DeepSeekConfig{
		Enabled: true, BaseURL: baseURL, TokenFile: writeDeepSeekTestTokenFile(t, "stored-token"),
	}}}
	router.deepSeekCredential.renew = func(context.Context) error {
		t.Fatal("服务不可达不是凭据问题，不应重新发现")
		return nil
	}

	status := router.probeDeepSeekRuntime(context.Background())
	if status.State != runtimeStateUnavailable || status.Reason != "harness_unavailable" {
		t.Fatalf("服务不可达应保持不可用状态：%+v", status)
	}
}

func TestDeepSeekRuntimeStatusWithoutConfigPathNeverTouchesDefaultConfig(t *testing.T) {
	router, _, _ := restartedDeepSeekHarness(t)
	// 未注入 renew 且没有配置路径：必须直接放弃，不能回落到用户默认配置文件。
	status := router.probeDeepSeekRuntime(context.Background())
	if status.State != runtimeStateSignedOut {
		t.Fatalf("没有可更新的配置时应报告凭据被拒：%+v", status)
	}
}

func TestHarnessNativeClientExplainsRejectedCredential(t *testing.T) {
	router, harness, _ := restartedDeepSeekHarness(t)
	router.deepSeekCredential.renew = func(context.Context) error { return errors.New("未发现 Harness") }

	_, err := router.harnessNativeClientFor(context.Background())
	var policyErr *harnessNativePolicyError
	if !errors.As(err, &policyErr) || policyErr.status != http.StatusBadGateway {
		t.Fatalf("凭据被拒应映射为 502：%v", err)
	}
	if !strings.Contains(policyErr.message, "重新检测") {
		t.Fatalf("移动端应拿到可执行的恢复说明：%q", policyErr.message)
	}
	if strings.Contains(policyErr.message, harness.token) || strings.Contains(policyErr.message, "token-from-previous") {
		t.Fatalf("错误不得回显凭据：%q", policyErr.message)
	}
}
