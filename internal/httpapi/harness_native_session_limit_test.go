package httpapi

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

// harnessNativeSessionLimitFixture 与 harnessNativeStreamFixture 同构，但显式设定全局
// 会话上限，用来验证 `cfg.DeepSeek.MaxConcurrentSessions` 在原生通道上真的被执行。
func harnessNativeSessionLimitFixture(
	t *testing.T,
	stub *harnessNativeStreamStub,
	limit int,
) (string, string, *Router) {
	t.Helper()
	upstream := stub.serve()
	tokenFile := filepath.Join(t.TempDir(), "harness-token")
	if err := os.WriteFile(tokenFile, []byte(stub.token), 0o600); err != nil {
		t.Fatal(err)
	}
	authorized := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "demo", Name: "Demo", Path: authorized}}
		cfg.DeepSeek = config.DeepSeekConfig{
			Enabled:               true,
			BaseURL:               upstream.URL,
			TokenFile:             tokenFile,
			MaxConcurrentSessions: limit,
		}
	})
	agentd := httptest.NewServer(server.handler)
	t.Cleanup(agentd.Close)
	return "ws" + strings.TrimPrefix(agentd.URL, "http") + "/api/harness/ws", authorized, server.router
}

// holdHarnessNativeMux 让每条上游订阅保持打开，直到测试结束。
//
// 必须在 fixture 之后调用：cleanup 是后进先出，先注册的 release 要晚于上游 server
// 的 Close 执行，否则 Close 会等在一个永远不返回的订阅处理器上。
func holdHarnessNativeMux(t *testing.T, stub *harnessNativeStreamStub) {
	t.Helper()
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	stub.muxOpen = func(*websocket.Conn, map[string]any) { <-release }
}

func sendHarnessNativeFollow(t *testing.T, conn *websocket.Conn, streamID, sessionID string) {
	t.Helper()
	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "open", "streamId": streamID, "endpoint": harnessclient.MethodSessionFollow,
		"payload": map[string]any{"args": map[string]any{"request": map[string]any{
			"address": map[string]any{"kind": "session", "sessionId": sessionID},
		}}},
	})
}

func waitForHarnessNativeOpens(t *testing.T, stub *harnessNativeStreamStub, want int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if opens, _ := stub.upstreamTouches(); opens >= want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	opens, _ := stub.upstreamTouches()
	t.Fatalf("上游订阅数始终未达到 %d，实际 %d", want, opens)
}

// waitForHarnessNativeActiveSessions 直接读中继的名额计数。
//
// 比等帧可靠：服务端拒绝会回错误帧，但**成功**的订阅不回任何帧，靠帧无法区分
// "成功"与"还没处理完"。
func waitForHarnessNativeActiveSessions(t *testing.T, router *Router, want int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if got := activeHarnessNativeSessions(router); got == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("活动会话名额始终未达到 %d，实际 %d", want, activeHarnessNativeSessions(router))
}

func activeHarnessNativeSessions(router *Router) int {
	router.harnessNativeSessionMu.Lock()
	defer router.harnessNativeSessionMu.Unlock()
	return router.activeHarnessNativeSession
}

// 上限必须跨连接生效。单连接上限（harnessNativeWSMaxStreams）挡不住"一个客户端
// 多开几条移动连接"，那正是退役旧网关后会失去保护的地方。
func TestHarnessNativeStreamSessionLimitIsGlobalAcrossConnections(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, authorized, router := harnessNativeSessionLimitFixture(t, stub, 2)
	holdHarnessNativeMux(t, stub)
	stub.sessions = []harnessclient.SessionSummary{
		harnessNativeFixtureSession("session-a", authorized),
		harnessNativeFixtureSession("session-b", authorized),
		harnessNativeFixtureSession("session-c", authorized),
	}

	first := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, first, "s1", "session-a")
	sendHarnessNativeFollow(t, first, "s2", "session-b")
	waitForHarnessNativeOpens(t, stub, 2)
	waitForHarnessNativeActiveSessions(t, router, 2)

	second := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, second, "s3", "session-c")
	if frame := readHarnessNativeFrame(t, second); frame["type"] != harnessclient.CarrierError {
		t.Fatalf("超过全局会话上限必须回错误帧，得到 %v", frame)
	}
	if opens, _ := stub.upstreamTouches(); opens != 2 {
		t.Fatalf("被拒的 follow 不得建立上游订阅，得到 %d 条", opens)
	}
}

// `$events` 是宿主级订阅，一台设备只开一条，不能占会话名额。
//
// 计入会让上限 1 被单设备的宿主订阅直接占满，重连时旧连接尚未超时就拿不到名额，
// 表现为"服务明明可用却连不上"。
func TestHarnessNativeStreamEventsDoesNotConsumeSessionSlot(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, authorized, router := harnessNativeSessionLimitFixture(t, stub, 1)
	holdHarnessNativeMux(t, stub)
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", authorized)}

	host := dialHarnessNativeStream(t, url)
	sendHarnessNativeFrame(t, host, map[string]any{
		"type": "open", "streamId": "e1", "endpoint": harnessclient.EndpointEvents,
	})
	waitForHarnessNativeOpens(t, stub, 1)
	waitForHarnessNativeActiveSessions(t, router, 0)

	conn := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, conn, "s1", "session-a")
	waitForHarnessNativeOpens(t, stub, 2)
	waitForHarnessNativeActiveSessions(t, router, 1)
}

// 主动退订必须归还名额。只在上游断流时归还的话，"先后浏览两个会话"会在第二个上失败。
func TestHarnessNativeStreamCancelReleasesSessionSlot(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, authorized, router := harnessNativeSessionLimitFixture(t, stub, 1)
	holdHarnessNativeMux(t, stub)
	stub.sessions = []harnessclient.SessionSummary{
		harnessNativeFixtureSession("session-a", authorized),
		harnessNativeFixtureSession("session-b", authorized),
	}

	first := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, first, "s1", "session-a")
	waitForHarnessNativeOpens(t, stub, 1)
	waitForHarnessNativeActiveSessions(t, router, 1)

	second := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, second, "s2", "session-b")
	if frame := readHarnessNativeFrame(t, second); frame["type"] != harnessclient.CarrierError {
		t.Fatalf("名额已满时必须拒绝，得到 %v", frame)
	}

	sendHarnessNativeFrame(t, first, map[string]any{"type": "cancel", "streamId": "s1"})
	if frame := readHarnessNativeFrame(t, first); frame["type"] != harnessclient.CarrierEnd {
		t.Fatalf("退订应回 end 帧，得到 %v", frame)
	}
	waitForHarnessNativeActiveSessions(t, router, 0)

	sendHarnessNativeFollow(t, second, "s3", "session-b")
	waitForHarnessNativeOpens(t, stub, 2)
	waitForHarnessNativeActiveSessions(t, router, 1)
}

// 整条连接退役也必须归还名额。漏了这条，断线重连会一直撞全局上限。
func TestHarnessNativeStreamConnectionCloseReleasesSessionSlot(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, authorized, router := harnessNativeSessionLimitFixture(t, stub, 1)
	holdHarnessNativeMux(t, stub)
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", authorized)}

	conn := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, conn, "s1", "session-a")
	waitForHarnessNativeOpens(t, stub, 1)
	waitForHarnessNativeActiveSessions(t, router, 1)

	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	waitForHarnessNativeActiveSessions(t, router, 0)
}

// 未配置时回落到默认上限；释放的下限是 0。
//
// 计数被打负会让上限在每个后续连接上被静默放宽一格——那是"配了上限但没生效"，
// 比没有上限更难发现。
func TestHarnessNativeSessionCounterFallsBackAndFloorsAtZero(t *testing.T) {
	router := &Router{cfg: config.Config{DeepSeek: config.DeepSeekConfig{MaxConcurrentSessions: 0}}}
	for i := 1; i <= config.DefaultDeepSeekMaxConcurrentSessions; i++ {
		if !router.acquireHarnessNativeSession() {
			t.Fatalf("第 %d 个名额应在默认上限内", i)
		}
	}
	if router.acquireHarnessNativeSession() {
		t.Fatal("超过默认上限必须拒绝")
	}
	router.releaseHarnessNativeSession()
	router.releaseHarnessNativeSession()
	router.releaseHarnessNativeSession()
	if got := activeHarnessNativeSessions(router); got != 0 {
		t.Fatalf("释放必须停在 0，得到 %d", got)
	}
	if !router.acquireHarnessNativeSession() {
		t.Fatal("释放后应能重新申请名额")
	}
}
