package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
)

func TestAppServerReadinessProbeCachesFailureAndRecovers(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	unavailable := true
	var calls atomic.Int64
	sentinel := errors.New("upstream unavailable")
	probe := newAppServerReadinessProbe(func(context.Context) error {
		calls.Add(1)
		if unavailable {
			return sentinel
		}
		return nil
	})
	probe.now = func() time.Time { return now }
	probe.failureTTL = time.Second
	probe.successTTL = 2 * time.Second

	if err := probe.Check(context.Background()); !errors.Is(err, sentinel) {
		t.Fatalf("首次失败结果异常：%v", err)
	}
	if err := probe.Check(context.Background()); !errors.Is(err, sentinel) || calls.Load() != 1 {
		t.Fatalf("failure TTL 内必须复用缓存：err=%v calls=%d", err, calls.Load())
	}
	unavailable = false
	now = now.Add(probe.failureTTL - time.Nanosecond)
	if err := probe.Check(context.Background()); !errors.Is(err, sentinel) || calls.Load() != 1 {
		t.Fatalf("failure TTL 到期前不得重复探测：err=%v calls=%d", err, calls.Load())
	}
	now = now.Add(time.Nanosecond)
	if err := probe.Check(context.Background()); err != nil || calls.Load() != 2 {
		t.Fatalf("failure TTL 到期后必须及时恢复：err=%v calls=%d", err, calls.Load())
	}
	now = now.Add(probe.successTTL - time.Nanosecond)
	if err := probe.Check(context.Background()); err != nil || calls.Load() != 2 {
		t.Fatalf("success TTL 内必须复用缓存：err=%v calls=%d", err, calls.Load())
	}
	now = now.Add(time.Nanosecond)
	if err := probe.Check(context.Background()); err != nil || calls.Load() != 3 {
		t.Fatalf("success TTL 到期后必须重新探测：err=%v calls=%d", err, calls.Load())
	}
}

func TestAppServerReadinessProbeSingleFlight(t *testing.T) {
	var calls atomic.Int64
	started := make(chan struct{})
	release := make(chan struct{})
	probe := newAppServerReadinessProbe(func(context.Context) error {
		if calls.Add(1) == 1 {
			close(started)
		}
		<-release
		return nil
	})
	probe.timeout = 2 * time.Second

	const workers = 12
	var wait sync.WaitGroup
	wait.Add(workers)
	errorsCh := make(chan error, workers)
	for index := 0; index < workers; index++ {
		go func() {
			defer wait.Done()
			errorsCh <- probe.Check(context.Background())
		}()
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("等待 single-flight 探测启动超时")
	}
	close(release)
	wait.Wait()
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatalf("并发等待者应共享成功结果：%v", err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("并发 readyz 只能触发一次 upstream 握手：calls=%d", calls.Load())
	}
}

func TestReadyzReturns503WhenUpstreamPortIsNotListening(t *testing.T) {
	var logs bytes.Buffer
	previousLog := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(previousLog) })

	for _, managed := range []bool{false, true} {
		t.Run(map[bool]string{false: "unmanaged", true: "managed"}[managed], func(t *testing.T) {
			upstreamURL := unusedReadyzUpstreamURL(t) + "/sensitive-upstream-path"
			tokenMarker := "private-upstream-token-port-test"
			tokenFile := filepath.Join(t.TempDir(), "private-token-file-marker")
			if err := os.WriteFile(tokenFile, []byte(tokenMarker+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			server := newReadyzTestServer(t, managed, upstreamURL, tokenFile)

			ready := requestReadyz(t, server.handler)
			if ready.Code != http.StatusServiceUnavailable {
				t.Fatalf("upstream 未监听时 readyz 必须返回 503：code=%d body=%s", ready.Code, ready.Body.String())
			}
			assertReadyzUpstreamCheck(t, ready, false)
			for _, secret := range []string{tokenMarker, tokenFile, upstreamURL, "sensitive-upstream-path"} {
				if strings.Contains(ready.Body.String(), secret) || strings.Contains(logs.String(), secret) {
					t.Fatalf("readyz 响应和日志不得泄露 upstream 敏感信息 %q：body=%s logs=%s", secret, ready.Body.String(), logs.String())
				}
			}

			live := httptest.NewRecorder()
			server.handler.ServeHTTP(live, httptest.NewRequest(http.MethodGet, "/healthz", nil))
			if live.Code != http.StatusOK {
				t.Fatalf("upstream 不可用不应影响 liveness：%d", live.Code)
			}
		})
	}
}

func TestReadyzRejectsUnmanagedUpstreamWithoutIndependentToken(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, nil)
	server := newReadyzTestServer(t, false, upstreamURL, "")

	ready := requestReadyz(t, server.handler)

	if ready.Code != http.StatusServiceUnavailable {
		t.Fatalf("unmanaged upstream 未配置独立 token 时 readyz 必须 fail-closed：code=%d body=%s", ready.Code, ready.Body.String())
	}
	assertReadyzUpstreamCheck(t, ready, false)
	if connections.Load() != 0 {
		t.Fatalf("缺少独立 token 时不得发起无鉴权 upstream 握手：connections=%d", connections.Load())
	}
}

func TestReadyzAuthenticationFailureCacheAndRecovery(t *testing.T) {
	const correctToken = "correct-independent-upstream-token"
	const wrongToken = "wrong-private-upstream-token-marker"
	upstreamURL, _, connections := fakeAppServerUpstreamWithAuth(t, correctToken, nil)
	tokenFile := filepath.Join(t.TempDir(), "sensitive-upstream-token-file-marker")
	if err := os.WriteFile(tokenFile, []byte(wrongToken+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	server := newReadyzTestServer(t, true, upstreamURL, tokenFile)

	var logs bytes.Buffer
	previousLog := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(previousLog) })

	failed := requestReadyz(t, server.handler)
	if failed.Code != http.StatusServiceUnavailable {
		t.Fatalf("upstream token 错误时 readyz 必须返回 503：code=%d body=%s", failed.Code, failed.Body.String())
	}
	assertReadyzUpstreamCheck(t, failed, false)
	if connections.Load() != 1 {
		t.Fatalf("鉴权失败应发生一次真实握手：connections=%d", connections.Load())
	}
	for _, secret := range []string{correctToken, wrongToken, tokenFile, upstreamURL} {
		if strings.Contains(failed.Body.String(), secret) || strings.Contains(logs.String(), secret) {
			t.Fatalf("鉴权失败不得泄露敏感信息 %q：body=%s logs=%s", secret, failed.Body.String(), logs.String())
		}
	}

	if err := os.WriteFile(tokenFile, []byte(correctToken+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	time.Sleep(appServerReadinessFailureTTL + 100*time.Millisecond)
	recovered := requestReadyz(t, server.handler)
	if recovered.Code != http.StatusOK {
		t.Fatalf("修复 token 后 readyz 应在短 failure TTL 后恢复：code=%d body=%s", recovered.Code, recovered.Body.String())
	}
	assertReadyzUpstreamCheck(t, recovered, true)
	if connections.Load() != 2 {
		t.Fatalf("恢复应只增加一次真实握手：connections=%d", connections.Load())
	}

	cached := requestReadyz(t, server.handler)
	if cached.Code != http.StatusOK || connections.Load() != 2 {
		t.Fatalf("成功结果 TTL 内不得重复昂贵握手：code=%d connections=%d", cached.Code, connections.Load())
	}
}

func newReadyzTestServer(t *testing.T, managed bool, upstreamURL string, tokenFile string) testServer {
	t.Helper()
	codexPath := filepath.Join(t.TempDir(), "codex")
	if err := os.WriteFile(codexPath, []byte("#!/bin/sh\nprintf '%s\\n' '--listen --ws-auth --ws-token-file'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Codex.Bin = codexPath
		cfg.Runtime.Type = "codex_app_server"
		cfg.AppServer = config.AppServerConfig{
			Transport:   "ws",
			Managed:     managed,
			Listen:      upstreamURL,
			WSTokenFile: tokenFile,
		}
	})
}

func unusedReadyzUpstreamURL(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return "ws://" + address
}

func requestReadyz(t *testing.T, handler http.Handler) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, authedRequest(t, http.MethodGet, "/api/readyz", nil))
	return recorder
}

func assertReadyzUpstreamCheck(t *testing.T, recorder *httptest.ResponseRecorder, wantOK bool) {
	t.Helper()
	var results doctor.Results
	if err := json.Unmarshal(recorder.Body.Bytes(), &results); err != nil {
		t.Fatalf("readyz 响应不是 doctor.Results：%v body=%s", err, recorder.Body.String())
	}
	for _, check := range results.Checks {
		if check.Name == "app-server-upstream" {
			if check.OK != wantOK {
				t.Fatalf("upstream readiness 状态异常：got=%+v want_ok=%v", check, wantOK)
			}
			return
		}
	}
	t.Fatalf("readyz 缺少 app-server-upstream 动态检查：%+v", results.Checks)
}
