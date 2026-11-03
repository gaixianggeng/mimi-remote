package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type bootTestHost struct {
	router  *Router
	sidecar *tailcatSidecarSupervisor
	managed *bootCountingManagedPairing
	path    string
}

type bootCountingManagedPairing struct {
	fakeManagedPairingService
	starts atomic.Int32
	syncs  atomic.Int32
}

func (f *bootCountingManagedPairing) Start() { f.starts.Add(1) }
func (f *bootCountingManagedPairing) Sync(context.Context) error {
	f.syncs.Add(1)
	return nil
}

// newBootTestHost 在创建 Router 前写好故障标记并注入短退避，第一次拉起就走被测路径。
func newBootTestHost(t *testing.T, enabled bool, markers ...string) *bootTestHost {
	t.Helper()
	binary := buildModeTestSidecar(t)
	dir, err := os.MkdirTemp("", "tc-boot-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	stateDir := filepath.Join(dir, "tailcat")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, marker := range markers {
		if err := os.WriteFile(filepath.Join(stateDir, marker), []byte(restartTestRelay), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(dir, "config.json")
	cfg := config.Config{Listen: "127.0.0.1:8787", Tailcat: config.TailcatConfig{
		Enabled: enabled, SidecarBin: binary, DERPMapURL: restartTestRelay, ManagedDERPMapURL: testOfficialRelayURL,
	}}
	cfg.Auth.Token = testToken
	data, _ := json.Marshal(cfg)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	sidecar := newTailcatSidecarSupervisor(cfg, path)
	sidecar.restartBaseDelay = 20 * time.Millisecond
	sidecar.restartMaxDelay = 40 * time.Millisecond
	managed := &bootCountingManagedPairing{}
	_, router := NewRouterWithInstallationIDAndOptions(
		cfg, nil, nil, "test", testInstallationID,
		RouterOptions{ConfigPath: path, tailcat: sidecar, managedPairing: managed},
	)
	t.Cleanup(router.Shutdown)
	return &bootTestHost{router: router, sidecar: sidecar, managed: managed, path: path}
}

func (h *bootTestHost) clearStartFailure(t *testing.T) {
	t.Helper()
	if err := os.Remove(filepath.Join(h.sidecar.stateDir, "fail-start-url")); err != nil {
		t.Fatal(err)
	}
}

func (h *bootTestHost) configuredEnabled(t *testing.T) bool {
	t.Helper()
	data, err := os.ReadFile(h.path)
	if err != nil {
		t.Fatal(err)
	}
	var cfg config.Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	return cfg.Tailcat.Enabled
}

func waitForBootTest(t *testing.T, what string, ready func() bool) {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); !ready(); {
		if time.Now().After(deadline) {
			t.Fatalf("等待超时：%s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func waitForBootTestRetries(t *testing.T, s *tailcatSidecarSupervisor, count int) {
	t.Helper()
	waitForBootTest(t, "启动失败后应持续重试", func() bool { return len(restartTestStarts(t, s)) >= count })
}

// 断言前先等在途的一次拉起收尾，再确认一段时间内没有新的拉起。
func assertBootTestNoMoreStarts(t *testing.T, s *tailcatSidecarSupervisor) int {
	t.Helper()
	s.operationMu.Lock()
	settled := len(restartTestStarts(t, s))
	s.operationMu.Unlock()
	time.Sleep(150 * time.Millisecond)
	if starts := len(restartTestStarts(t, s)); starts != settled {
		t.Fatalf("不应继续拉起：%d -> %d", settled, starts)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd != nil {
		t.Fatal("不应有运行中的辅助程序")
	}
	return settled
}

func TestRouterStartsManagedSyncAfterFirstBootStart(t *testing.T) {
	h := newBootTestHost(t, true)
	waitForBootTest(t, "就绪后应启动托管同步", func() bool { return h.managed.starts.Load() == 1 })
	if starts := restartTestStarts(t, h.sidecar); len(starts) != 1 {
		t.Fatalf("首次成功不应多拉起：%d", len(starts))
	}
	// 同步循环的第一次同步就是重放，这里不能再多打一次控制面。
	if syncs := h.managed.syncs.Load(); syncs != 0 {
		t.Fatalf("首次启动不应走重启后的同步：%d", syncs)
	}
}

func TestRouterRetriesFirstBootStartAndStartsManagedSyncAfterRecovery(t *testing.T) {
	h := newBootTestHost(t, true, "fail-start-url")
	waitForBootTestRetries(t, h.sidecar, 3)
	if starts := h.managed.starts.Load(); starts != 0 {
		t.Fatalf("辅助程序就绪前不应启动托管同步：%d", starts)
	}
	if status := h.sidecar.Status(context.Background()); !status.Enabled || status.Running || status.Error == "" {
		t.Fatalf("重试期间应保持开启、未运行并报告错误：%+v", status)
	}
	if !h.configuredEnabled(t) {
		t.Fatal("启动时重试不应改写配置")
	}

	h.clearStartFailure(t)

	waitForBootTest(t, "恢复后应启动托管同步", func() bool { return h.managed.starts.Load() == 1 })
	before := waitForRestartTestStatus(t, h.sidecar, func(status tailcatStatus) bool { return status.Running })
	if before.Error != "" {
		t.Fatalf("恢复后不应保留启动错误：%q", before.Error)
	}

	// 恢复后交给正常监管：再次意外退出会重启，并走重启后的策略重放。
	killRestartTestSidecar(t, h.sidecar)
	waitForRestartTestStatus(t, h.sidecar, func(status tailcatStatus) bool {
		return status.Running && status.InstanceID != before.InstanceID
	})
	waitForBootTest(t, "重启后应重放托管策略", func() bool { return h.managed.syncs.Load() == 1 })
	if starts := h.managed.starts.Load(); starts != 1 {
		t.Fatalf("托管同步只应启动一次：%d", starts)
	}
}

func TestBootRetryCancelledByStopAndClose(t *testing.T) {
	cases := map[string]func(t *testing.T, h *bootTestHost){
		"stop": func(t *testing.T, h *bootTestHost) {
			if err := h.sidecar.Stop(context.Background()); err != nil {
				t.Fatal(err)
			}
		},
		"shutdown": func(_ *testing.T, h *bootTestHost) { h.router.Shutdown() },
	}
	for name, stop := range cases {
		t.Run(name, func(t *testing.T) {
			h := newBootTestHost(t, true, "fail-start-url")
			waitForBootTestRetries(t, h.sidecar, 2)
			stop(t, h)
			assertBootTestNoMoreStarts(t, h.sidecar)
			// 故障解除也不能自行恢复：用户已关闭或 agentd 已退出。
			h.clearStartFailure(t)
			assertBootTestNoMoreStarts(t, h.sidecar)
			if starts := h.managed.starts.Load(); starts != 0 {
				t.Fatalf("取消后不应启动托管同步：%d", starts)
			}
		})
	}
}

// 没网时辅助程序可能既不退出也不就绪，关闭不能等满 20 秒就绪超时。
func TestBootStartWaitingForReadyIsCancelledByClose(t *testing.T) {
	h := newBootTestHost(t, true, "hang-before-ready")
	waitForBootTestRetries(t, h.sidecar, 1)
	started := time.Now()
	h.sidecar.Close()
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("关闭应取消等待就绪，实际耗时 %s", elapsed)
	}
	assertBootTestNoMoreStarts(t, h.sidecar)
}

func TestBootRetryStartsManagedSyncWhenReconfigurationBringsSidecarUp(t *testing.T) {
	h := newBootTestHost(t, true, "fail-start-url")
	waitForBootTestRetries(t, h.sidecar, 2)
	// 故障标记只匹配原中继，换中继后 reconfigure 自己就能拉起。
	if _, err := h.sidecar.ConfigureDERPMap(context.Background(), "https://other.example.invalid/map"); err != nil {
		t.Fatal(err)
	}
	waitForBootTest(t, "别的入口拉起后也应启动托管同步", func() bool { return h.managed.starts.Load() == 1 })
}

func TestEnableFailureRollsBackAndDoesNotRetry(t *testing.T) {
	h := newBootTestHost(t, false, "fail-start-url")
	if failure := h.router.enableTailcat(context.Background()); failure == nil {
		t.Fatal("辅助程序启动失败时启用应报错")
	}
	if starts := assertBootTestNoMoreStarts(t, h.sidecar); starts != 1 {
		t.Fatalf("启用失败不应重试：starts=%d", starts)
	}
	if h.configuredEnabled(t) {
		t.Fatal("启用失败应回滚配置")
	}
	if status := h.sidecar.Status(context.Background()); status.Enabled {
		t.Fatalf("启用失败后应是关闭状态：%+v", status)
	}
	if starts := h.managed.starts.Load(); starts != 0 {
		t.Fatalf("启用失败不应启动托管同步：%d", starts)
	}
}

// 重试期间用户点启用：失败同样回滚，并把重试一起取消，不能回滚之后又被拉起来。
func TestEnableFailureDuringBootRetryRollsBackAndCancelsRetry(t *testing.T) {
	h := newBootTestHost(t, true, "fail-start-url")
	waitForBootTestRetries(t, h.sidecar, 2)
	if failure := h.router.enableTailcat(context.Background()); failure == nil {
		t.Fatal("辅助程序启动失败时启用应报错")
	}
	assertBootTestNoMoreStarts(t, h.sidecar)
	if h.configuredEnabled(t) {
		t.Fatal("启用失败应回滚配置")
	}
	h.clearStartFailure(t)
	assertBootTestNoMoreStarts(t, h.sidecar)
}

func TestEnableAfterStoppingBootRetryStartsManagedSync(t *testing.T) {
	h := newBootTestHost(t, true, "fail-start-url")
	waitForBootTestRetries(t, h.sidecar, 2)
	if err := h.sidecar.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	h.clearStartFailure(t)
	if failure := h.router.enableTailcat(context.Background()); failure != nil {
		t.Fatal(failure.err)
	}
	if !h.configuredEnabled(t) || h.managed.starts.Load() != 1 {
		t.Fatalf("重新开启后应恢复：configured=%v starts=%d", h.configuredEnabled(t), h.managed.starts.Load())
	}
	before := h.sidecar.Status(context.Background())
	killRestartTestSidecar(t, h.sidecar)
	waitForRestartTestStatus(t, h.sidecar, func(status tailcatStatus) bool {
		return status.Running && status.InstanceID != before.InstanceID
	})
}

type statusCountingSidecar struct {
	fakeTailcatSidecar
	statuses atomic.Int32
}

func (f *statusCountingSidecar) Status(context.Context) tailcatStatus {
	f.statuses.Add(1)
	return tailcatStatus{}
}

// 辅助程序的重试可能在 Close 之后才成功，这时不能再启动同步循环。
func TestManagedPairingStartAfterCloseDoesNotRunSyncLoop(t *testing.T) {
	sidecar := &statusCountingSidecar{}
	controller, err := newManagedPairingController(managedPairingControllerOptions{
		BaseURL: "https://control.example.invalid", StatePath: filepath.Join(t.TempDir(), managedPairingStateFileName),
		InstallationID: testManagedInstallationID, Tailcat: sidecar,
		HTTPClient: &http.Client{Transport: rejectModeTestNetwork{}},
	})
	if err != nil {
		t.Fatal(err)
	}
	controller.Close()
	controller.Start()
	controller.wait.Wait()
	if statuses := sidecar.statuses.Load(); statuses != 0 {
		t.Fatalf("关闭后不应运行同步循环：%d", statuses)
	}
}
