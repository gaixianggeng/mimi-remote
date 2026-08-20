package appserver

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestLocalDaemonPreexistingFallsBackToLiveSocket(t *testing.T) {
	probeTimeout := errors.New("initialize timeout")
	if !localDaemonWasPreexisting(probeTimeout, true) {
		t.Fatal("协议探测超时时，仍在监听的 socket 必须按旧 daemon 处理")
	}
	if localDaemonWasPreexisting(probeTimeout, false) {
		t.Fatal("协议和轻量连接都失败时才允许按全新冷启动处理")
	}
	if !localDaemonWasPreexisting(nil, false) {
		t.Fatal("完整协议探测成功必须视为已有 daemon")
	}
}

func TestStableOwnerEnsureFailureOnlyRollsBackConfigurationTransaction(t *testing.T) {
	cause := errors.New("lifecycle unavailable")
	tests := []struct {
		name          string
		options       LocalDaemonOptions
		wantRollbacks int
	}{
		{
			name:          "ordinary runtime preserves pending owner",
			options:       LocalDaemonOptions{StableOwner: true},
			wantRollbacks: 0,
		},
		{
			name: "uncommitted configuration may restore previous owner",
			options: LocalDaemonOptions{
				StableOwner:            true,
				RollbackOwnerOnFailure: true,
			},
			wantRollbacks: 1,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			rollbacks := 0
			owner := SharedDaemonOwnerStatus{Rollback: &SharedDaemonOwnerRollback{
				rollbackUnlocked: func(context.Context) error {
					rollbacks++
					return nil
				},
			}}
			err := stableOwnerEnsureFailure(test.options, owner, cause)
			if !errors.Is(err, cause) || rollbacks != test.wantRollbacks {
				t.Fatalf("owner rollback 边界错误：err=%v rollbacks=%d", err, rollbacks)
			}
		})
	}
}

func TestLocalDaemonSocketPathUsesCanonicalCodexHome(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	realHome := shortCodexHome(t)
	linkRoot := t.TempDir()
	linkHome := filepath.Join(linkRoot, "codex-home")
	if err := os.Symlink(realHome, linkHome); err != nil {
		t.Fatal(err)
	}

	path, err := LocalDaemonSocketPath(map[string]string{"CODEX_HOME": linkHome})
	if err != nil {
		t.Fatal(err)
	}
	canonicalHome, err := filepath.EvalSymlinks(realHome)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(canonicalHome, localDaemonSocketDir, localDaemonSocketName)
	if path != want {
		t.Fatalf("socket 应使用 canonical CODEX_HOME：want %q, got %q", want, path)
	}
}

func TestLocalDaemonSocketPathRejectsRelativeExplicitHome(t *testing.T) {
	t.Setenv("CODEX_HOME", "")
	if _, err := LocalDaemonSocketPath(map[string]string{"CODEX_HOME": "relative/codex"}); err == nil {
		t.Fatal("显式相对 CODEX_HOME 必须 fail closed")
	}
}

func TestLocalDaemonSocketPathRejectsOverlongUnixPath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不使用 Unix socket")
	}
	codexHome := filepath.Join(t.TempDir(), strings.Repeat("x", 80))
	if err := os.MkdirAll(codexHome, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := LocalDaemonSocketPath(map[string]string{"CODEX_HOME": codexHome}); err == nil {
		t.Fatal("超过保守 Unix socket 上限的 CODEX_HOME 必须提前拒绝")
	}
}

func TestProbeLocalDaemonPerformsInitializeHandshake(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Unix socket")
	}
	codexHome := shortCodexHome(t)
	socketPath, initialized, _ := startLocalDaemonTestServer(t, codexHome, "mimi_remote_daemon_probe/0.147.0-alpha.6.5 (Mac OS; arm64)")

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	probe, err := ProbeLocalDaemonInfo(ctx, socketPath)
	if err != nil {
		t.Fatalf("daemon probe 失败：%v", err)
	}
	if probe.Version != "0.147.0-alpha.6.5" || probe.CodexHome != codexHome {
		t.Fatalf("probe metadata 错误：%+v", probe)
	}
	select {
	case <-initialized:
	case <-time.After(time.Second):
		t.Fatal("probe 应在 initialize 后发送 initialized 通知")
	}
}

func TestProbeLocalDaemonRejectsUnsupportedVersion(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Unix socket")
	}
	codexHome := shortCodexHome(t)
	socketPath, _, _ := startLocalDaemonTestServer(t, codexHome, "Codex Desktop/0.140.9 (Mac OS; arm64)")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := ProbeLocalDaemonInfo(ctx, socketPath); err == nil {
		t.Fatal("低于 Desktop local daemon 门槛的版本必须被拒绝")
	}
}

func TestEnsureLocalDaemonAttachesBeforeStarting(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	var starts atomic.Int32
	status, err := ensureLocalDaemon(context.Background(), LocalDaemonOptions{
		Env: map[string]string{"CODEX_HOME": codexHome},
	}, localDaemonHooks{
		probe: func(context.Context, string) (LocalDaemonProbe, error) {
			return LocalDaemonProbe{Version: "0.146.0", CodexHome: codexHome}, nil
		},
		start: func(context.Context, LocalDaemonOptions) error {
			starts.Add(1)
			return nil
		},
		stat: os.Stat,
	})
	if err != nil {
		t.Fatal(err)
	}
	if starts.Load() != 0 || status.Started || status.Version != "0.146.0" {
		t.Fatalf("健康 daemon 应直接 attach，不应启动新进程：starts=%d status=%+v", starts.Load(), status)
	}
	if !status.StartedAt.IsZero() {
		t.Fatalf("attach 外部 daemon 时不能把 socket mtime 伪装为启动时间：%v", status.StartedAt)
	}
}

func TestAttachOnlyLocalDaemonNeverStartsBackend(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, err := EnsureLocalDaemon(ctx, LocalDaemonOptions{
		Env:        map[string]string{"CODEX_HOME": codexHome},
		AttachOnly: true,
	})
	if err == nil || !strings.Contains(err.Error(), "不会启动或接管") {
		t.Fatalf("外部 Unix backend 缺失时必须 attach-only 失败：%v", err)
	}
}

func TestEnsureLocalDaemonStartsOnceThenProbes(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	var starts atomic.Int32
	var probes atomic.Int32
	status, err := ensureLocalDaemon(context.Background(), LocalDaemonOptions{
		Env: map[string]string{"CODEX_HOME": codexHome},
	}, localDaemonHooks{
		probe: func(context.Context, string) (LocalDaemonProbe, error) {
			if probes.Add(1) == 1 {
				return LocalDaemonProbe{}, os.ErrNotExist
			}
			return LocalDaemonProbe{Version: "0.147.0", CodexHome: codexHome}, nil
		},
		start: func(context.Context, LocalDaemonOptions) error {
			starts.Add(1)
			return nil
		},
		stat: func(string) (os.FileInfo, error) { return nil, os.ErrNotExist },
	})
	if err != nil {
		t.Fatal(err)
	}
	if starts.Load() != 1 || !status.Started || status.Version != "0.147.0" {
		t.Fatalf("应只启动一次并返回探针版本：starts=%d status=%+v", starts.Load(), status)
	}
}

func TestEnsureLocalDaemonDoesNotStartOverInvalidSocket(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	socketDir := filepath.Join(codexHome, localDaemonSocketDir)
	if err := os.MkdirAll(socketDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(socketDir, localDaemonSocketName), []byte("not a socket"), 0o600); err != nil {
		t.Fatal(err)
	}
	var starts atomic.Int32
	_, err := ensureLocalDaemon(context.Background(), LocalDaemonOptions{
		Env: map[string]string{"CODEX_HOME": codexHome},
	}, localDaemonHooks{
		probe: func(context.Context, string) (LocalDaemonProbe, error) {
			return LocalDaemonProbe{}, errors.New("handshake failed")
		},
		start: func(context.Context, LocalDaemonOptions) error {
			starts.Add(1)
			return nil
		},
		stat: os.Stat,
	})
	if err == nil || starts.Load() != 0 {
		t.Fatalf("非法占位文件必须在启动前 fail closed：starts=%d err=%v", starts.Load(), err)
	}
}

func TestLocalDaemonVersionSupported(t *testing.T) {
	cases := map[string]bool{
		"0.140.9":           false,
		"0.141.0-alpha.1":   false,
		"0.141.0":           true,
		"0.146.0":           true,
		"0.147.0-alpha.6.5": true,
		"invalid":           false,
	}
	for version, want := range cases {
		if got := localDaemonVersionSupported(version); got != want {
			t.Errorf("version %q: want %t, got %t", version, want, got)
		}
	}
}

func TestLocalDaemonVersionParsesInitializeClientProduct(t *testing.T) {
	cases := map[string]string{
		"mimi_remote_daemon_probe/0.147.0-alpha.6.5 (Mac OS; arm64)": "0.147.0-alpha.6.5",
		"Codex Desktop/0.147.0 (Mac OS; arm64)":                      "0.147.0",
	}
	for userAgent, want := range cases {
		got, ok := localDaemonVersion(userAgent)
		if !ok || got != want {
			t.Errorf("user agent %q: want %q, got %q ok=%t", userAgent, want, got, ok)
		}
	}
	if _, ok := localDaemonVersion("Mac OS/15.0"); ok {
		t.Fatal("非 semver 系统版本不能被当作 app-server 版本")
	}
}

func TestInspectLocalDaemonLifecycleParsesOfficialJSON(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("测试脚本使用 POSIX shell")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex")
	script := `#!/bin/sh
printf '%s\n' '{"status":"running","backend":"pid","managedCodexPath":"/tmp/codex","managedCodexVersion":"0.147.0","socketPath":"/tmp/app-server-control.sock","cliVersion":"0.147.0","appServerVersion":"0.147.0"}'
`
	if err := os.WriteFile(bin, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	status, err := InspectLocalDaemonLifecycle(context.Background(), LocalDaemonOptions{CodexBin: bin})
	if err != nil {
		t.Fatal(err)
	}
	if status.Status != "running" || status.AppServerVersion != "0.147.0" ||
		status.Backend == nil || *status.Backend != "pid" ||
		status.ManagedCodexVersion == nil || *status.ManagedCodexVersion != "0.147.0" {
		t.Fatalf("daemon version JSON 解析错误：%+v", status)
	}
}

func TestValidateLocalDaemonLifecycleRequiresOfficialManagedPath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	socketPath := filepath.Join(codexHome, localDaemonSocketDir, localDaemonSocketName)
	version := "0.147.0"
	foreign := filepath.Join(t.TempDir(), "codex")
	if err := os.WriteFile(foreign, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	status := LocalDaemonLifecycleStatus{
		Status:              "running",
		ManagedCodexPath:    foreign,
		ManagedCodexVersion: &version,
		SocketPath:          socketPath,
		CLIVersion:          version,
		AppServerVersion:    version,
	}
	if err := ValidateLocalDaemonLifecycle(status, socketPath); err == nil {
		t.Fatal("非当前 CODEX_HOME 官方 standalone 路径必须被拒绝")
	}

	official := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if err := os.MkdirAll(filepath.Dir(official), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(official, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	status.ManagedCodexPath = official
	if err := ValidateLocalDaemonLifecycle(status, socketPath); err != nil {
		t.Fatalf("同一 CODEX_HOME 的官方 standalone 应通过：%v", err)
	}
	if err := ValidateManagedLocalDaemonLifecycle(status, socketPath); err == nil {
		t.Fatal("缺少 backend 的旧 SSH 直启 socket 不能冒充 managed daemon")
	}
	backend := "pid"
	status.Backend = &backend
	if err := ValidateManagedLocalDaemonLifecycle(status, socketPath); err != nil {
		t.Fatalf("官方 pid backend 应通过 managed 校验：%v", err)
	}
}

func TestReconcileStableOwnerLifecycleMarksDetectedUnmanagedBackend(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	socketPath := filepath.Join(codexHome, localDaemonSocketDir, localDaemonSocketName)
	official := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if err := os.MkdirAll(filepath.Dir(official), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(official, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	version := "0.147.0"
	lifecycle := LocalDaemonLifecycleStatus{
		Status:              "running",
		ManagedCodexPath:    official,
		ManagedCodexVersion: &version,
		SocketPath:          socketPath,
		CLIVersion:          version,
		AppServerVersion:    version,
	}
	status := LocalDaemonStatus{SocketPath: socketPath, Version: version}
	owner := SharedDaemonOwnerStatus{Installed: true, Loaded: true, Secure: true}
	markCalls := 0
	if err := reconcileStableOwnerLifecycle(lifecycle, status, &owner, false, func() error {
		markCalls++
		return nil
	}); err != nil {
		t.Fatalf("稳定 owner 下检测到 SSH unmanaged backend 应保持 attach：%v", err)
	}
	if !owner.MigrationRequired || markCalls != 1 {
		t.Fatalf("必须重建待迁移标记：owner=%+v markCalls=%d", owner, markCalls)
	}
	if err := reconcileStableOwnerLifecycle(lifecycle, status, &owner, false, func() error {
		markCalls++
		return nil
	}); err != nil || markCalls != 1 {
		t.Fatalf("已有 marker 时必须幂等：err=%v markCalls=%d", err, markCalls)
	}
}

func TestReconcileStableOwnerLifecycleMarksLegacyPIDBackendForMigration(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	socketPath := filepath.Join(codexHome, localDaemonSocketDir, localDaemonSocketName)
	official := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if err := os.MkdirAll(filepath.Dir(official), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(official, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	version := "0.147.0"
	backend := "pid"
	lifecycle := LocalDaemonLifecycleStatus{
		Status:              "running",
		Backend:             &backend,
		ManagedCodexPath:    official,
		ManagedCodexVersion: &version,
		SocketPath:          socketPath,
		CLIVersion:          version,
		AppServerVersion:    version,
	}
	status := LocalDaemonStatus{SocketPath: socketPath, Version: version}
	owner := SharedDaemonOwnerStatus{Installed: true, Loaded: true, Secure: true}
	markCalls := 0
	if err := reconcileStableOwnerLifecycle(lifecycle, status, &owner, false, func() error {
		markCalls++
		return nil
	}); err != nil {
		t.Fatalf("旧官方 pid backend 应保持 attach 并等待显式迁移：%v", err)
	}
	if !owner.MigrationRequired || markCalls != 1 {
		t.Fatalf("旧 pid backend 不能冒充签名 supervisor：owner=%+v mark=%d", owner, markCalls)
	}
	if err := reconcileStableOwnerLifecycle(lifecycle, status, &owner, false, func() error {
		markCalls++
		return nil
	}); err != nil || markCalls != 1 {
		t.Fatalf("已有 legacy marker 时必须幂等：err=%v mark=%d", err, markCalls)
	}

	owner.MigrationRequired = true
	err := reconcileStableOwnerLifecycle(lifecycle, status, &owner, true, func() error {
		markCalls++
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "旧 pid backend") || markCalls != 1 {
		t.Fatalf("本次新 owner kickstart 得到 pid backend 必须 fail closed：err=%v mark=%d", err, markCalls)
	}
}

func TestReconcileStableOwnerLifecycleRejectsUnmanagedAfterStableKickstart(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	socketPath := filepath.Join(codexHome, localDaemonSocketDir, localDaemonSocketName)
	official := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if err := os.MkdirAll(filepath.Dir(official), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(official, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	version := "0.147.0"
	lifecycle := LocalDaemonLifecycleStatus{
		Status:              "running",
		ManagedCodexPath:    official,
		ManagedCodexVersion: &version,
		SocketPath:          socketPath,
		CLIVersion:          version,
		AppServerVersion:    version,
	}
	status := LocalDaemonStatus{SocketPath: socketPath, Version: version}
	owner := SharedDaemonOwnerStatus{Installed: true, Loaded: true, Secure: true, MigrationRequired: true}
	markCalls := 0
	err := reconcileStableOwnerLifecycle(lifecycle, status, &owner, true, func() error {
		markCalls++
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "pid daemon") || markCalls != 0 {
		t.Fatalf("稳定 owner kickstart 后仍无 backend 必须 fail closed：err=%v mark=%d", err, markCalls)
	}
}

func TestReconcileStableOwnerLifecycleRejectsUnknownBackend(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	socketPath := filepath.Join(codexHome, localDaemonSocketDir, localDaemonSocketName)
	official := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if err := os.MkdirAll(filepath.Dir(official), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(official, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	version := "0.147.0"
	backend := "future"
	lifecycle := LocalDaemonLifecycleStatus{
		Status:              "running",
		Backend:             &backend,
		ManagedCodexPath:    official,
		ManagedCodexVersion: &version,
		SocketPath:          socketPath,
		CLIVersion:          version,
		AppServerVersion:    version,
	}
	owner := SharedDaemonOwnerStatus{Installed: true, Loaded: true, Secure: true, MigrationRequired: true}
	markCalls := 0
	err := reconcileStableOwnerLifecycle(
		lifecycle,
		LocalDaemonStatus{SocketPath: socketPath, Version: version},
		&owner,
		false,
		func() error { markCalls++; return nil },
	)
	if err == nil || markCalls != 0 {
		t.Fatalf("未知 backend 不能借 marker 绕过 managed 校验：err=%v mark=%d", err, markCalls)
	}
}

func TestReconcileStableOwnerLifecycleRequiresSecureOwnerAndWritableMarker(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不支持 Codex Unix daemon")
	}
	codexHome := shortCodexHome(t)
	socketPath := filepath.Join(codexHome, localDaemonSocketDir, localDaemonSocketName)
	official := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if err := os.MkdirAll(filepath.Dir(official), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(official, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	version := "0.147.0"
	lifecycle := LocalDaemonLifecycleStatus{
		Status:              "running",
		ManagedCodexPath:    official,
		ManagedCodexVersion: &version,
		SocketPath:          socketPath,
		CLIVersion:          version,
		AppServerVersion:    version,
	}
	status := LocalDaemonStatus{SocketPath: socketPath, Version: version}

	unsafeOwners := map[string]SharedDaemonOwnerStatus{
		"not installed": {Loaded: true, Secure: true},
		"not loaded":    {Installed: true, Secure: true},
		"not secure":    {Installed: true, Loaded: true},
	}
	for name, owner := range unsafeOwners {
		t.Run(name, func(t *testing.T) {
			markCalls := 0
			err := reconcileStableOwnerLifecycle(lifecycle, status, &owner, false, func() error {
				markCalls++
				return nil
			})
			if err == nil || !strings.Contains(err.Error(), "缺少安全稳定 owner") || markCalls != 0 {
				t.Fatalf("不安全 owner 必须在写 marker 前拒绝：err=%v mark=%d", err, markCalls)
			}
		})
	}

	markerErr := errors.New("磁盘只读")
	owner := SharedDaemonOwnerStatus{Installed: true, Loaded: true, Secure: true}
	err := reconcileStableOwnerLifecycle(lifecycle, status, &owner, false, func() error {
		return markerErr
	})
	if err == nil || !errors.Is(err, markerErr) || owner.MigrationRequired {
		t.Fatalf("marker 写入失败必须 fail closed 且不得伪报待迁移：err=%v owner=%+v", err, owner)
	}
}

func TestValidateLocalDaemonProbeVersionRejectsMismatch(t *testing.T) {
	status := LocalDaemonLifecycleStatus{AppServerVersion: "0.147.0"}
	if err := ValidateLocalDaemonProbeVersion(status, "0.146.0"); err == nil {
		t.Fatal("live initialize 与 daemon version 不一致时必须拒绝")
	}
	if err := ValidateLocalDaemonProbeVersion(status, "0.147.0"); err != nil {
		t.Fatalf("一致版本应通过：%v", err)
	}
}

func TestStartIndependentModeRuntimeRejectsChangedConfigBeforeStart(t *testing.T) {
	startCalls := 0
	err := StartIndependentModeRuntime(
		context.Background(),
		func() error { return errors.New("config switched to shared") },
		func() error {
			startCalls++
			return nil
		},
	)
	if err == nil || startCalls != 0 {
		t.Fatalf("配置复核失败时不得启动独立 runtime：calls=%d err=%v", startCalls, err)
	}
}

func startLocalDaemonTestServer(
	t *testing.T,
	codexHome string,
	userAgent string,
) (string, <-chan struct{}, func()) {
	t.Helper()
	socketDir := filepath.Join(codexHome, localDaemonSocketDir)
	if err := os.MkdirAll(socketDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socketDir, 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(socketDir, localDaemonSocketName)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = listener.Close()
		t.Fatal(err)
	}
	initialized := make(chan struct{}, 1)
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		conn, err := upgrader.Upgrade(writer, request, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		var initialize map[string]any
		if err := conn.ReadJSON(&initialize); err != nil {
			return
		}
		_ = conn.WriteJSON(map[string]any{
			"id": 1,
			"result": map[string]any{
				"userAgent": userAgent,
				"codexHome": codexHome,
			},
		})
		var notification map[string]any
		if err := conn.ReadJSON(&notification); err == nil && notification["method"] == "initialized" {
			initialized <- struct{}{}
		}
	})}
	go func() { _ = server.Serve(listener) }()
	stop := func() {
		_ = server.Close()
		_ = listener.Close()
	}
	t.Cleanup(stop)
	return socketPath, initialized, stop
}

func shortCodexHome(t *testing.T) string {
	t.Helper()
	path, err := os.MkdirTemp("/tmp", "mimi-codex.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(path) })
	return path
}
