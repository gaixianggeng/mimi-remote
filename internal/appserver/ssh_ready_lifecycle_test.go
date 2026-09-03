package appserver

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSSHTransportReadyFlightSurvivesLeaderCancellation(t *testing.T) {
	transport, logPath, _, _ := newSSHHelperTransport(t, true)
	t.Cleanup(transport.Shutdown)
	t.Setenv(sshHelperProxyDelayEnv, "150ms")

	leaderCtx, cancelLeader := context.WithCancel(context.Background())
	leaderResult := make(chan error, 1)
	go func() {
		leaderResult <- transport.EnsureReady(leaderCtx)
	}()
	waitForSSHHelperCommand(t, logPath, sshProxyRemoteCommand)

	followerResult := make(chan error, 1)
	go func() {
		followerResult <- transport.EnsureReady(context.Background())
	}()
	cancelLeader()

	if err := <-leaderResult; !errors.Is(err, context.Canceled) {
		t.Fatalf("leader 应只结束自己的等待：%v", err)
	}
	select {
	case err := <-followerResult:
		if err != nil {
			t.Fatalf("leader 取消不应终止共享 readiness：%v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("follower 未收到共享 readiness 结果")
	}
	if got := countSSHHelperCommand(t, logPath, sshProxyRemoteCommand); got != 1 {
		t.Fatalf("leader 与 follower 必须共享一次 proxy 探测，got=%d", got)
	}
}

func TestSSHTransportShutdownCancelsReadyFlightAndRejectsNewWork(t *testing.T) {
	transport, logPath, _, _ := newSSHHelperTransport(t, true)
	t.Setenv(sshHelperProxyDelayEnv, "5s")

	result := make(chan error, 1)
	go func() {
		result <- transport.EnsureReady(context.Background())
	}()
	waitForSSHHelperCommand(t, logPath, sshProxyRemoteCommand)
	transport.Shutdown()
	transport.Shutdown()

	select {
	case err := <-result:
		if err == nil {
			t.Fatal("shutdown 后 readiness 不应成功")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("shutdown 未及时结束 readiness 子进程")
	}
	if err := transport.EnsureReady(context.Background()); err == nil {
		t.Fatal("shutdown 后不得启动新 readiness")
	}
}

func TestSSHTransportShutdownClosesEstablishedProxyButKeepsResidentServer(t *testing.T) {
	transport, _, serverMarker, _ := newSSHHelperTransport(t, true)
	conn, _, err := transport.DialWebSocket(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}

	transport.Shutdown()
	_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("shutdown 后已建立的 SSH proxy 应关闭")
	}
	if !helperFileExists(serverMarker) {
		t.Fatal("shutdown 不得停止共享 resident App Server")
	}
	transport.readyMu.Lock()
	activeProxies := len(transport.proxies)
	transport.readyMu.Unlock()
	if activeProxies != 0 {
		t.Fatalf("shutdown 后 SSH 子进程注册表应为空，got=%d", activeProxies)
	}
}

func waitForSSHHelperCommand(t *testing.T, logPath string, command string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if helperFileExists(logPath) && countSSHHelperCommand(t, logPath, command) > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("等待 SSH helper 命令超时：%s", command)
}
