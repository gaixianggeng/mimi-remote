//go:build darwin

package appserver

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

const realFeatureCodexVersion = "0.161.0"

// Desktop 的运行时发布策略能修改未显式配置的共享后台；恢复时必须等旧进程退出，
// 再用 CLI 自身的实际值启动受保护 replacement。
func TestFrontDoorRealModelDiscoveryFeatureRecovery(t *testing.T) {
	bin := requireRealFeatureCodex(t)
	_, _, env := realFeatureIsolation(t)
	door, err := NewFrontDoor(SharedLocalOptions{CodexBin: bin, Env: env}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	// 隔离目录不可能有旧标准 socket，避免测试扫描本机其它 Codex 进程。
	door.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) { return nil, nil }
	if err := os.MkdirAll(filepath.Dir(door.BackendSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	initial, err := startRealFeatureCodex(bin, []string{
		"app-server", "--listen", "unix://" + door.BackendSocketPath(),
	}, env)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { initial.stop(t) })
	if err := waitRealFeatureSocket(ctx, initial, door.BackendSocketPath()); err != nil {
		t.Fatal(err)
	}

	desktop := dialRealCodexWebSocket(t, ctx, door.BackendSocketPath())
	if _, err := initializeWebSocketResult(ctx, desktop); err != nil {
		desktop.Close()
		t.Fatal(err)
	}
	if enabled := readRealModelDiscovery(t, ctx, desktop, 2); !enabled {
		desktop.Close()
		t.Fatal("无显式配置的 Codex 0.161 应默认启用 api_key_model_discovery")
	}
	setRealModelDiscovery(t, ctx, desktop, 3, false)
	if enabled := readRealModelDiscovery(t, ctx, desktop, 4); enabled {
		desktop.Close()
		t.Fatal("未复现 Desktop 对未保护 backend 的运行时覆盖")
	}
	_ = desktop.Close()

	before, err := door.RuntimeVersions(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if before.InstalledVersion != realFeatureCodexVersion ||
		before.RunningVersion != realFeatureCodexVersion ||
		before.UpdateAvailable || !before.FeatureMismatch {
		t.Fatalf("同版本功能冲突识别错误：%+v", before)
	}
	process, alive, err := realSharedLocalRepairProcess(initial.pid())
	if err != nil || !alive {
		t.Fatalf("无法确认隔离 backend 进程：alive=%v err=%v", alive, err)
	}
	if err := validateSharedLocalRepairProcess(process, initial.pid(), uint32(os.Getuid())); err != nil {
		t.Fatalf("隔离 backend 进程身份不符合安全退出前提：%v", err)
	}
	if err := canGracefullyDrainFrontDoorOrphan(ctx, process); err != nil {
		t.Fatalf("隔离 backend 不符合安全退出前提：%v", err)
	}

	listener, err := net.Listen("unix", door.PublicSocketPath())
	if err != nil {
		t.Fatal(err)
	}
	serveCtx, stopServing := context.WithCancel(context.Background())
	serveDone := make(chan error, 1)
	go func() { serveDone <- door.Serve(serveCtx, listener) }()
	t.Cleanup(func() {
		stopServing()
		_ = listener.Close()
		select {
		case err := <-serveDone:
			if err != nil {
				t.Errorf("隔离前门退出失败：%v", err)
			}
		case <-time.After(5 * time.Second):
			t.Error("隔离前门退出超时")
		}
	})

	var launches atomic.Int32
	var replacementMu sync.Mutex
	var replacement *realFeatureCodexProcess
	t.Cleanup(func() {
		replacementMu.Lock()
		process := replacement
		replacementMu.Unlock()
		if process != nil {
			process.stop(t)
		}
	})
	door.launch = func(callCtx context.Context, options SharedLocalOptions, listen string) error {
		if _, alive, checkErr := realSharedLocalRepairProcess(initial.pid()); checkErr != nil || alive {
			return fmt.Errorf("旧 backend 尚未退出就启动 replacement: alive=%v err=%v", alive, checkErr)
		}
		args, argsErr := sharedLocalAppServerArgs(callCtx, options.CodexBin, options.Env, listen)
		if argsErr != nil {
			return argsErr
		}
		if !containsRealFeatureArg(args, true) {
			return fmt.Errorf("replacement 未显式保护 api_key_model_discovery=true: %v", args)
		}
		process, startErr := startRealFeatureCodex(options.CodexBin, args, options.Env)
		if startErr != nil {
			return startErr
		}
		replacementMu.Lock()
		if replacement != nil {
			replacementMu.Unlock()
			if stopErr := stopRealFeatureCodex(process, 5*time.Second); stopErr != nil {
				return fmt.Errorf("重复启动 replacement 且清理失败：%w", stopErr)
			}
			return errors.New("重复启动 replacement")
		}
		replacement = process
		replacementMu.Unlock()
		launches.Add(1)
		return nil
	}

	// 保持公共连接不主动关闭，确认 restart 会先让旧 backend 断开，再启动 replacement。
	shared := dialRealCodexWebSocket(t, ctx, door.PublicSocketPath())
	if _, err := initializeWebSocketResult(ctx, shared); err != nil {
		shared.Close()
		t.Fatal(err)
	}
	after, err := door.RestartRuntime(ctx, nil)
	_ = shared.Close()
	if err != nil {
		t.Fatal(err)
	}
	if launches.Load() != 1 {
		t.Fatalf("replacement 启动次数=%d want 1", launches.Load())
	}
	if after.InstalledVersion != realFeatureCodexVersion ||
		after.RunningVersion != realFeatureCodexVersion ||
		after.UpdateAvailable || after.FeatureMismatch {
		t.Fatalf("恢复后状态错误：%+v", after)
	}

	secondDesktop := dialRealCodexWebSocket(t, ctx, door.PublicSocketPath())
	if _, err := initializeWebSocketResult(ctx, secondDesktop); err != nil {
		secondDesktop.Close()
		t.Fatal(err)
	}
	setRealModelDiscovery(t, ctx, secondDesktop, 2, false)
	_ = secondDesktop.Close()

	reconnected := dialRealCodexWebSocket(t, ctx, door.PublicSocketPath())
	if _, err := initializeWebSocketResult(ctx, reconnected); err != nil {
		reconnected.Close()
		t.Fatal(err)
	}
	if enabled := readRealModelDiscovery(t, ctx, reconnected, 2); !enabled {
		reconnected.Close()
		t.Fatal("显式 true 的 replacement 被 Desktop 运行时覆盖")
	}
	_ = reconnected.Close()
	verified, err := door.RuntimeVersions(ctx)
	if err != nil || verified.FeatureMismatch || verified.UpdateAvailable {
		t.Fatalf("重连后的运行态校验失败：versions=%+v err=%v", verified, err)
	}
}

func TestFrontDoorRealModelDiscoveryExplicitFalse(t *testing.T) {
	bin := requireRealFeatureCodex(t)
	_, codexHome, env := realFeatureIsolation(t)
	config := "[features]\napi_key_model_discovery = false\n"
	if err := os.WriteFile(filepath.Join(codexHome, "config.toml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	door, err := NewFrontDoor(SharedLocalOptions{CodexBin: bin, Env: env}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	door.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) { return nil, nil }
	if err := os.MkdirAll(filepath.Dir(door.PublicSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}

	var backendMu sync.Mutex
	var backend *realFeatureCodexProcess
	t.Cleanup(func() {
		backendMu.Lock()
		process := backend
		backendMu.Unlock()
		if process != nil {
			process.stop(t)
		}
	})
	door.launch = func(callCtx context.Context, options SharedLocalOptions, listen string) error {
		backendMu.Lock()
		alreadyStarted := backend != nil
		backendMu.Unlock()
		if alreadyStarted {
			return errors.New("重复启动显式 false backend")
		}
		args, argsErr := sharedLocalAppServerArgs(callCtx, options.CodexBin, options.Env, listen)
		if argsErr != nil {
			return argsErr
		}
		if !containsRealFeatureArg(args, false) {
			return fmt.Errorf("用户 false 未进入真实启动参数: %v", args)
		}
		process, startErr := startRealFeatureCodex(options.CodexBin, args, options.Env)
		if startErr != nil {
			return startErr
		}
		backendMu.Lock()
		backend = process
		backendMu.Unlock()
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	probe, err := door.DialBackend(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_ = probe.Close()
	client := dialRealCodexWebSocket(t, ctx, door.BackendSocketPath())
	if _, err := initializeWebSocketResult(ctx, client); err != nil {
		client.Close()
		t.Fatal(err)
	}
	if enabled := readRealModelDiscovery(t, ctx, client, 2); enabled {
		client.Close()
		t.Fatal("用户显式 false 未应用到真实 backend")
	}
	setRealModelDiscovery(t, ctx, client, 3, true)
	if enabled := readRealModelDiscovery(t, ctx, client, 4); enabled {
		client.Close()
		t.Fatal("用户显式 false 被 Desktop 运行时 true 覆盖")
	}
	_ = client.Close()
	versions, err := door.RuntimeVersions(ctx)
	if err != nil || versions.FeatureMismatch || versions.UpdateAvailable {
		t.Fatalf("用户显式 false 被误报为冲突：versions=%+v err=%v", versions, err)
	}
	backendMu.Lock()
	startedBackend := backend
	backendMu.Unlock()
	if startedBackend == nil {
		t.Fatal("真实 backend 未记录")
	}
	oldPID := startedBackend.pid()
	// 非确认关停必须通过物理 socket alias 的严格 lsof 引用计数，不能依赖恢复路径的跳过规则。
	if err := door.StopIdleBackend(ctx); err != nil {
		t.Fatalf("真实 0.161 backend 严格空闲关停失败：%v", err)
	}
	select {
	case <-startedBackend.done:
	case <-ctx.Done():
		t.Fatalf("等待真实 0.161 backend 退出：%v", ctx.Err())
	}
	if _, alive, err := realSharedLocalRepairProcess(oldPID); err != nil || alive {
		t.Fatalf("严格空闲关停后旧 PID 仍存在：pid=%d alive=%v err=%v", oldPID, alive, err)
	}
}

type realFeatureCodexProcess struct {
	cmd     *exec.Cmd
	cancel  context.CancelFunc
	done    chan struct{}
	waitMu  sync.Mutex
	waitErr error
	stopOne sync.Once
}

func startRealFeatureCodex(bin string, args []string, env map[string]string) (*realFeatureCodexProcess, error) {
	directory, err := sharedLocalWorkingDirectory(env)
	if err != nil {
		return nil, err
	}
	processCtx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(processCtx, bin, args...)
	cmd.Dir = directory
	isolatedEnv := cloneStringMap(env)
	isolatedEnv["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"
	isolatedEnv["OPENAI_API_KEY"] = ""
	isolatedEnv["CODEX_API_KEY"] = ""
	cmd.Env = buildManagedEnv(isolatedEnv)
	if err := cmd.Start(); err != nil {
		cancel()
		return nil, err
	}
	process := &realFeatureCodexProcess{cmd: cmd, cancel: cancel, done: make(chan struct{})}
	go func() {
		err := cmd.Wait()
		process.waitMu.Lock()
		process.waitErr = err
		process.waitMu.Unlock()
		close(process.done)
	}()
	return process, nil
}

func (p *realFeatureCodexProcess) pid() int {
	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return 0
	}
	return p.cmd.Process.Pid
}

func (p *realFeatureCodexProcess) err() error {
	p.waitMu.Lock()
	defer p.waitMu.Unlock()
	return p.waitErr
}

func (p *realFeatureCodexProcess) stop(t *testing.T) {
	t.Helper()
	p.stopOne.Do(func() {
		if err := stopRealFeatureCodex(p, 5*time.Second); err != nil {
			t.Error(err)
		}
	})
}

func stopRealFeatureCodex(process *realFeatureCodexProcess, timeout time.Duration) error {
	process.cancel()
	select {
	case <-process.done:
		return nil
	case <-time.After(timeout):
		return fmt.Errorf("真实隔离 Codex 进程未退出：pid=%d", process.pid())
	}
}

func waitRealFeatureSocket(ctx context.Context, process *realFeatureCodexProcess, socket string) error {
	for {
		conn, err := net.DialTimeout("unix", socket, 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		select {
		case <-process.done:
			if err := process.err(); err != nil {
				return fmt.Errorf("真实 Codex App Server 提前退出：%w", err)
			}
			return errors.New("真实 Codex App Server 提前退出")
		case <-ctx.Done():
			return fmt.Errorf("等待真实 Codex App Server socket：%w", ctx.Err())
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func requireRealFeatureCodex(t *testing.T) string {
	t.Helper()
	if os.Getenv("MIMI_TEST_REAL_CODEX_FRONT") != "1" {
		t.Skip("仅在显式隔离实测时运行")
	}
	bin, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal(err)
	}
	bin, err = filepath.EvalSymlinks(bin)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	version, err := CheckLocalCodex(ctx, bin)
	if err != nil {
		t.Fatal(err)
	}
	if version != realFeatureCodexVersion {
		t.Skipf("真实回归固定 Codex %s，当前为 %s", realFeatureCodexVersion, version)
	}
	return bin
}

func realFeatureIsolation(t *testing.T) (string, string, map[string]string) {
	t.Helper()
	home := shortSharedLocalCodexHome(t)
	codexHome := shortSharedLocalCodexHome(t)
	return home, codexHome, map[string]string{
		"HOME":       home,
		"CODEX_HOME": codexHome,
		"PATH":       os.Getenv("PATH"),
	}
}

func containsRealFeatureArg(args []string, enabled bool) bool {
	want := "features." + modelDiscoveryFeature + "=" + fmt.Sprint(enabled)
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}

func readRealModelDiscovery(t *testing.T, ctx context.Context, conn *websocket.Conn, id int) bool {
	t.Helper()
	var result struct {
		Data []struct {
			Name    string `json:"name"`
			Enabled bool   `json:"enabled"`
		} `json:"data"`
	}
	callRealCodexRPC(t, ctx, conn, id, "experimentalFeature/list", map[string]any{"limit": 1000}, &result)
	for _, feature := range result.Data {
		if feature.Name == modelDiscoveryFeature {
			return feature.Enabled
		}
	}
	t.Fatalf("真实 Codex 未报告 %s", modelDiscoveryFeature)
	return false
}

func setRealModelDiscovery(t *testing.T, ctx context.Context, conn *websocket.Conn, id int, enabled bool) {
	t.Helper()
	var result struct {
		Enablement map[string]bool `json:"enablement"`
	}
	callRealCodexRPC(t, ctx, conn, id, "experimentalFeature/enablement/set", map[string]any{
		"enablement": map[string]bool{modelDiscoveryFeature: enabled},
	}, &result)
	if actual, ok := result.Enablement[modelDiscoveryFeature]; !ok || actual != enabled {
		t.Fatalf("运行时功能写入响应=%v want %v", result.Enablement, enabled)
	}
}
