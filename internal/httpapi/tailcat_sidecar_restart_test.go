package httpapi

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const restartTestRelay = "https://custom.example.invalid/map"

func newRestartTestHost(t *testing.T, base, limit time.Duration) (*tailcatSidecarSupervisor, *managedPairingController) {
	t.Helper()
	s, c := newModeTestHost(t, buildModeTestSidecar(t), restartTestRelay, true)
	s.mu.Lock()
	s.restartBaseDelay = base
	s.restartMaxDelay = limit
	s.mu.Unlock()
	return s, c
}

func killRestartTestSidecar(t *testing.T, s *tailcatSidecarSupervisor) {
	t.Helper()
	s.mu.Lock()
	cmd, done := s.cmd, s.done
	s.mu.Unlock()
	if cmd == nil {
		t.Fatal("没有运行中的辅助程序")
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	<-done
}

func waitForRestartTestStatus(t *testing.T, s *tailcatSidecarSupervisor, ready func(tailcatStatus) bool) tailcatStatus {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		status := s.Status(context.Background())
		if ready(status) {
			return status
		}
		if time.Now().After(deadline) {
			t.Fatalf("等待辅助程序状态超时：%+v", status)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func restartTestStarts(t *testing.T, s *tailcatSidecarSupervisor) []time.Time {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(s.stateDir, "starts.log"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatal(err)
	}
	var starts []time.Time
	for _, line := range strings.Fields(string(raw)) {
		started, err := time.Parse(time.RFC3339Nano, line)
		if err != nil {
			t.Fatal(err)
		}
		starts = append(starts, started)
	}
	return starts
}

func TestTailcatSidecarRestartsAfterUnexpectedExit(t *testing.T) {
	s, _ := newRestartTestHost(t, 10*time.Millisecond, time.Second)
	var restarted atomic.Int32
	s.setRestartHandler(func(context.Context) { restarted.Add(1) })
	before := s.Status(context.Background())

	killRestartTestSidecar(t, s)

	after := waitForRestartTestStatus(t, s, func(status tailcatStatus) bool {
		return status.Running && status.InstanceID != before.InstanceID
	})
	if after.PublicKey != before.PublicKey || after.Address != before.Address || after.PublicKey == "" {
		t.Fatalf("重启后主机身份和地址必须不变：before=%+v after=%+v", before, after)
	}
	if after.Error != "" {
		t.Fatalf("重启成功后不应保留退出错误：%q", after.Error)
	}
	for deadline := time.Now().Add(5 * time.Second); restarted.Load() == 0; {
		if time.Now().After(deadline) {
			t.Fatal("重启成功后应通知上层重放策略")
		}
		time.Sleep(5 * time.Millisecond)
	}

	// 再次退出同样能恢复：循环结束后不能留下「已有循环」的登记。
	killRestartTestSidecar(t, s)
	waitForRestartTestStatus(t, s, func(status tailcatStatus) bool {
		return status.Running && status.InstanceID != after.InstanceID
	})
}

func TestTailcatSidecarDoesNotRestartAfterIntentionalStop(t *testing.T) {
	cases := map[string]func(t *testing.T, s *tailcatSidecarSupervisor){
		"stop": func(t *testing.T, s *tailcatSidecarSupervisor) {
			if err := s.Stop(context.Background()); err != nil {
				t.Fatal(err)
			}
		},
		"close": func(_ *testing.T, s *tailcatSidecarSupervisor) { s.Close() },
	}
	for name, stop := range cases {
		t.Run(name, func(t *testing.T) {
			s, _ := newRestartTestHost(t, 5*time.Millisecond, 20*time.Millisecond)
			stop(t, s)
			time.Sleep(150 * time.Millisecond)
			s.mu.Lock()
			running := s.cmd != nil
			s.mu.Unlock()
			if starts := restartTestStarts(t, s); running || len(starts) != 1 {
				t.Fatalf("主动停止不应重启：running=%v starts=%d", running, len(starts))
			}
		})
	}
}

func TestTailcatSidecarReconfigurationAndResetDoNotTriggerRestart(t *testing.T) {
	s, _ := newRestartTestHost(t, 5*time.Millisecond, 20*time.Millisecond)
	var restarted atomic.Int32
	s.setRestartHandler(func(context.Context) { restarted.Add(1) })
	if _, err := s.Reset(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ConfigureDERPMap(context.Background(), "https://other.example.invalid/map"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(150 * time.Millisecond)
	// 启动一次 + 改配置一次，旧进程退出不能再额外拉起一个。
	if starts := restartTestStarts(t, s); len(starts) != 2 || restarted.Load() != 0 {
		t.Fatalf("改配置和重置不应触发自动重启：starts=%d restarted=%d", len(starts), restarted.Load())
	}
	if status := s.Status(context.Background()); !status.Running {
		t.Fatalf("改配置后应运行新进程：%+v", status)
	}
}

func TestTailcatSidecarStopDuringBackoffCancelsRestart(t *testing.T) {
	s, _ := newRestartTestHost(t, 100*time.Millisecond, time.Second)
	killRestartTestSidecar(t, s)
	if err := s.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	if starts := restartTestStarts(t, s); len(starts) != 1 {
		t.Fatalf("退避期间关闭后不应再拉起：starts=%d", len(starts))
	}
	// 用户重新开启后恢复正常监管。
	if err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	before := s.Status(context.Background())
	killRestartTestSidecar(t, s)
	waitForRestartTestStatus(t, s, func(status tailcatStatus) bool {
		return status.Running && status.InstanceID != before.InstanceID
	})
}

func TestTailcatSidecarRestartBacksOffWhileStartKeepsFailing(t *testing.T) {
	base, limit := 40*time.Millisecond, 160*time.Millisecond
	s, _ := newRestartTestHost(t, base, limit)
	failure := filepath.Join(s.stateDir, "fail-start-url")
	if err := os.WriteFile(failure, []byte(restartTestRelay), 0o600); err != nil {
		t.Fatal(err)
	}
	killRestartTestSidecar(t, s)

	// 启动 1 次 + 自动重试至少 5 次，足够覆盖翻倍和封顶。
	deadline := time.Now().Add(20 * time.Second)
	var starts []time.Time
	for len(starts) < 6 {
		if time.Now().After(deadline) {
			t.Fatalf("启动失败后应持续重试，实际启动 %d 次", len(starts))
		}
		time.Sleep(10 * time.Millisecond)
		starts = restartTestStarts(t, s)
	}
	if status := s.Status(context.Background()); status.Running || status.Error == "" {
		t.Fatalf("重试失败期间应报告未运行和错误：%+v", status)
	}
	// starts[0] 是首次启动。只断言下限：进程启动耗时只会把间隔拉长，不受机器负载影响。
	for index, expected := range []time.Duration{80, 160, 160} {
		gap := starts[index+2].Sub(starts[index+1])
		if gap < expected*time.Millisecond {
			t.Fatalf("第 %d 次重试间隔 %s 小于预期 %dms", index+2, gap, expected)
		}
	}

	// 故障解除后自行恢复。
	if err := os.Remove(failure); err != nil {
		t.Fatal(err)
	}
	waitForRestartTestStatus(t, s, func(status tailcatStatus) bool { return status.Running })
}

func TestTailcatRestartDelayKeepsGrowingAcrossQuickCrashes(t *testing.T) {
	s := &tailcatSidecarSupervisor{
		restartBaseDelay: time.Second, restartMaxDelay: 5 * time.Second, restartStableUptime: time.Minute,
	}
	for index, expected := range []time.Duration{1, 2, 4, 5, 5} {
		if got := s.nextRestartDelayLocked(); got != expected*time.Second {
			t.Fatalf("第 %d 次间隔 = %s，期望 %ds", index, got, expected)
		}
	}
	// 没有循环在跑时 schedule 会新开 goroutine；登记占位后只验证退避计数。
	s.restartCancel = func() {}
	s.config.Enabled = true
	exited := &exec.Cmd{}
	s.readyAt = time.Now()
	s.scheduleRestartLocked(exited)
	if s.restartFailures != 5 {
		t.Fatalf("就绪后很快退出不应清零退避：%d", s.restartFailures)
	}
	s.readyAt = time.Now().Add(-2 * time.Minute)
	s.scheduleRestartLocked(exited)
	if s.restartFailures != 0 {
		t.Fatalf("稳定运行后退出应清零退避：%d", s.restartFailures)
	}
}

// 启用失败要回滚配置，启动期间的退出不能被自动重启接管。
func TestTailcatSidecarFailedDirectStartIsNotRestarted(t *testing.T) {
	s, _ := newModeTestHost(t, buildModeTestSidecar(t), restartTestRelay, false)
	s.mu.Lock()
	s.restartBaseDelay = 5 * time.Millisecond
	s.mu.Unlock()
	if err := os.WriteFile(filepath.Join(s.stateDir, "fail-start-url"), []byte(restartTestRelay), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Start(context.Background()); err == nil {
		t.Fatal("假辅助程序启动失败时 Start 应返回错误")
	}
	time.Sleep(100 * time.Millisecond)
	if starts := restartTestStarts(t, s); len(starts) != 1 {
		t.Fatalf("启动失败由调用方处理，不应自动重试：starts=%d", len(starts))
	}
}

func TestTailcatSidecarRestartReplaysManagedClients(t *testing.T) {
	s, c := newRestartTestHost(t, 10*time.Millisecond, time.Second)
	if _, err := c.ConfigureMode(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	seedModeTestPolicy(t, c, s)
	before := s.Status(context.Background())
	if before.Mode != config.TailcatModeManaged || before.PairedDeviceCount != 1 {
		t.Fatalf("前置状态不对：%+v", before)
	}
	s.setRestartHandler(func(ctx context.Context) { _ = c.Sync(ctx) })

	killRestartTestSidecar(t, s)

	// 假控制面拒绝网络，走离线缓存策略；白名单必须远早于 5 分钟轮询恢复。
	after := waitForRestartTestStatus(t, s, func(status tailcatStatus) bool {
		return status.Running && status.InstanceID != before.InstanceID && status.PairedDeviceCount == 1
	})
	if after.PublicKey != before.PublicKey {
		t.Fatalf("重启不应改变托管主机身份：before=%q after=%q", before.PublicKey, after.PublicKey)
	}
}

func TestRouterReplaysManagedPolicyAfterSidecarRestart(t *testing.T) {
	binary := buildModeTestSidecar(t)
	dir, err := os.MkdirTemp("", "tc-router-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "config.json")
	cfg := config.Config{Listen: "127.0.0.1:8787", Tailcat: config.TailcatConfig{Enabled: true, SidecarBin: binary}}
	data, _ := json.Marshal(cfg)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	managed := &syncCountingManagedPairing{}
	_, router := NewRouterWithInstallationIDAndOptions(
		cfg, nil, nil, "test", testInstallationID,
		RouterOptions{ConfigPath: path, managedPairing: managed},
	)
	s := router.tailcat.(*tailcatSidecarSupervisor)
	t.Cleanup(s.Close)
	s.mu.Lock()
	s.restartBaseDelay = 10 * time.Millisecond
	s.mu.Unlock()
	// 必须等启动流程结束：启动期间退出由启动调用方处理，不算意外退出。
	before := waitForRestartTestStatus(t, s, func(status tailcatStatus) bool {
		s.mu.Lock()
		defer s.mu.Unlock()
		return status.Running && !s.starting
	})

	killRestartTestSidecar(t, s)

	waitForRestartTestStatus(t, s, func(status tailcatStatus) bool {
		return status.Running && status.InstanceID != before.InstanceID
	})
	for deadline := time.Now().Add(5 * time.Second); managed.syncs.Load() == 0; {
		if time.Now().After(deadline) {
			t.Fatal("Router 应在辅助程序重启后立即同步托管策略")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

type syncCountingManagedPairing struct {
	fakeManagedPairingService
	syncs atomic.Int32
}

func (f *syncCountingManagedPairing) Sync(context.Context) error {
	f.syncs.Add(1)
	return nil
}
