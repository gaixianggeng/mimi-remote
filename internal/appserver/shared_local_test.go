//go:build linux || darwin

package appserver

import (
	"context"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestSharedLocalSocketPathUsesCanonicalCodexHome(t *testing.T) {
	realHome := shortSharedLocalCodexHome(t)
	link := filepath.Join(filepath.Dir(realHome), "codex-link")
	if err := os.Symlink(realHome, link); err != nil {
		t.Fatal(err)
	}
	path, err := SharedLocalSocketPath(map[string]string{"CODEX_HOME": link})
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(realHome, sharedLocalSocketDir, sharedLocalSocketName); path != want {
		t.Fatalf("socket path = %q, want %q", path, want)
	}
}

func TestSharedLocalTransportAttachesWithoutStartingAnotherServer(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	stop := startSharedLocalTestServer(t, socket)
	defer stop()

	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	var starts atomic.Int32
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		starts.Add(1)
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := transport.EnsureReady(ctx); err != nil {
		t.Fatal(err)
	}
	if starts.Load() != 0 {
		t.Fatalf("已有 control socket 时不应启动第二个 App Server：starts=%d", starts.Load())
	}
}

func TestSharedLocalTransportStartsOnceAndThenAttaches(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	var starts atomic.Int32
	var stop func()
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		starts.Add(1)
		stop = startSharedLocalTestServer(t, socket)
		return nil
	}
	t.Cleanup(func() {
		if stop != nil {
			stop()
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := transport.EnsureReady(ctx); err != nil {
		t.Fatal(err)
	}
	if err := transport.EnsureReady(ctx); err != nil {
		t.Fatal(err)
	}
	if starts.Load() != 1 {
		t.Fatalf("缺失 socket 时应只启动一次：starts=%d", starts.Load())
	}
}

func TestSharedLocalTransportConnectOnlyNeverStartsResident(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	transport, err := NewSharedLocalTransport(SharedLocalOptions{
		Env: map[string]string{"CODEX_HOME": codexHome}, ConnectOnly: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := transport.EnsureReady(ctx); err == nil || !strings.Contains(err.Error(), "前门尚未就绪") {
		t.Fatalf("前门缺失时应拒绝另起共享 resident：%v", err)
	}
	if _, err := os.Lstat(transport.SocketPath()); !os.IsNotExist(err) {
		t.Fatalf("connect-only 意外创建标准 socket：%v", err)
	}
}

func TestSharedLocalTransportRejectsNonSocketOccupant(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(socket, []byte("occupied"), 0o600); err != nil {
		t.Fatal(err)
	}
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		t.Fatal("非 socket 占位不得触发启动")
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if err := transport.EnsureReady(ctx); err == nil || !strings.Contains(err.Error(), "非 socket") {
		t.Fatalf("应拒绝非 socket 占位，got %v", err)
	}
}

func TestSharedLocalTransportDoesNotReplaceUnresponsiveSocket(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	listener.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		t.Fatal("仍存在的 socket 不得触发第二个 App Server")
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if err := transport.EnsureReady(ctx); err == nil || !strings.Contains(err.Error(), "仍存在") {
		t.Fatalf("无法握手的现有 socket 应明确失败，got %v", err)
	}
}

func TestStartResidentCommandUsesStableHome(t *testing.T) {
	originalDirectory, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	launchDirectory := filepath.Join(root, "temporary-launch")
	home := filepath.Join(root, "home")
	for _, directory := range []string{launchDirectory, home} {
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chdir(launchDirectory); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(originalDirectory) })

	marker := filepath.Join(root, "resident-cwd")
	err = startResidentCommand(
		"/bin/sh",
		[]string{"-c", `pwd > "$MIMI_SHARED_LOCAL_CWD_MARKER"; sleep 1`},
		map[string]string{
			"HOME":                         home,
			"MIMI_SHARED_LOCAL_CWD_MARKER": marker,
		},
	)
	if chdirErr := os.Chdir(originalDirectory); chdirErr != nil {
		t.Fatal(chdirErr)
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(launchDirectory); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	wantHome := home
	if canonical, evalErr := filepath.EvalSymlinks(home); evalErr == nil {
		wantHome = canonical
	}
	if got := strings.TrimSpace(string(contents)); got != wantHome {
		t.Fatalf("resident cwd = %q, want stable HOME %q", got, wantHome)
	}
}

func TestSharedLocalWorkingDirectoryRejectsInvalidHome(t *testing.T) {
	for name, home := range map[string]string{
		"empty":    "",
		"relative": "relative/home",
		"missing":  filepath.Join(t.TempDir(), "missing"),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := sharedLocalWorkingDirectory(map[string]string{"HOME": home}); err == nil {
				t.Fatalf("HOME %q should be rejected", home)
			}
		})
	}
}

func TestSystemdResidentCommandUsesIndependentService(t *testing.T) {
	args := systemdResidentCommandArgs(
		"mimi-test.service",
		"/home/tester",
		"/home/tester/.codex/control/environment",
		"/usr/bin/codex",
		[]string{"app-server", "--listen", "unix://"},
	)
	for _, want := range []string{
		"--service-type=exec",
		"--working-directory=/home/tester",
		"--property=EnvironmentFile=/home/tester/.codex/control/environment",
		"--property=StandardOutput=null",
		"--property=StandardError=null",
	} {
		if !slices.Contains(args, want) {
			t.Fatalf("systemd-run args missing %q: %v", want, args)
		}
	}
	if slices.Contains(args, "--scope") {
		t.Fatalf("resident must not inherit agentd mount namespace: %v", args)
	}
}

func TestWriteSystemdEnvironmentFile(t *testing.T) {
	path, err := writeSystemdEnvironmentFile(t.TempDir(), []string{
		`HOME=/home/test user`,
		`QUOTED=value "quoted"`,
		`BACKSLASH=C:\tools\codex`,
		"MULTILINE=first\nsecond",
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "HOME=\"/home/test user\"\n" +
		"QUOTED=\"value \\\"quoted\\\"\"\n" +
		"BACKSLASH=\"C:\\\\tools\\\\codex\"\n" +
		"MULTILINE=\"first\nsecond\"\n"
	if string(contents) != want {
		t.Fatalf("environment file = %q, want %q", contents, want)
	}
	if info, err := os.Stat(path); err != nil {
		t.Fatal(err)
	} else if info.Mode().Perm() != 0o600 {
		t.Fatalf("environment file mode = %o, want 600", info.Mode().Perm())
	}
}

func TestSharedLocalResidentEnvironmentDropsServiceIdentity(t *testing.T) {
	env := sharedLocalResidentEnvironment(map[string]string{
		"INVOCATION_ID":  "old-service",
		"JOURNAL_STREAM": "old-journal",
		"PATH":           "/usr/bin:/bin",
	})
	if slices.Contains(env, "INVOCATION_ID=old-service") ||
		slices.Contains(env, "JOURNAL_STREAM=old-journal") {
		t.Fatalf("resident inherited agentd service identity: %v", env)
	}
	if !slices.Contains(env, "PATH=/usr/bin:/bin") {
		t.Fatalf("resident lost configured PATH: %v", env)
	}
}

func shortSharedLocalCodexHome(t *testing.T) string {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "msl-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	// macOS 的 /tmp 是 /private/tmp 的符号链接；socket 路径按规范路径比较。
	if canonical, evalErr := filepath.EvalSymlinks(root); evalErr == nil {
		root = canonical
	}
	path := filepath.Join(root, "c")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func startSharedLocalTestServer(t *testing.T, socket string) func() {
	t.Helper()
	return startSharedLocalTestServerWithSession(t, socket, "Aqua")
}

func startSharedLocalTestServerWithSession(t *testing.T, socket, manager string) func() {
	return startSharedLocalTestServerWithSessionAndHome(t, socket, manager, filepath.Dir(filepath.Dir(socket)))
}

func startSharedLocalTestServerWithSessionAndHome(t *testing.T, socket, manager, reportedHome string) func() {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		conn, upgradeErr := upgrader.Upgrade(w, request, nil)
		if upgradeErr != nil {
			return
		}
		defer conn.Close()
		var initialize map[string]any
		if conn.ReadJSON(&initialize) != nil {
			return
		}
		result := map[string]any{}
		if reportedHome != "" {
			result["codexHome"] = reportedHome
		}
		_ = conn.WriteJSON(map[string]any{"id": 1, "result": result})
		var initialized map[string]any
		_ = conn.ReadJSON(&initialized)
		var sessionProbe map[string]any
		if conn.ReadJSON(&sessionProbe) == nil {
			_ = conn.WriteJSON(map[string]any{"id": sessionProbe["id"], "result": map[string]any{
				"exitCode": 0, "stdout": manager + "\n", "stderr": "",
			}})
		}
	})}
	go func() { _ = server.Serve(listener) }()
	return func() {
		_ = server.Close()
		_ = os.Remove(socket)
	}
}

func TestSharedLocalTransportEnsureReadyTimesOutWithoutDeadline(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	// 握手成功但永远不回应 initialize：没有总超时的 probe 会在这里永久阻塞。
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		conn, upgradeErr := upgrader.Upgrade(w, request, nil)
		if upgradeErr != nil {
			return
		}
		defer conn.Close()
		<-release
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		close(release)
		_ = server.Close()
		_ = os.Remove(socket)
	})

	previous := sharedLocalDefaultReadyTimeout
	sharedLocalDefaultReadyTimeout = 300 * time.Millisecond
	t.Cleanup(func() { sharedLocalDefaultReadyTimeout = previous })

	transport, err := NewSharedLocalTransport(SharedLocalOptions{CodexBin: "codex", Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	var started atomic.Int32
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		started.Add(1)
		return nil
	}
	begin := time.Now()
	err = transport.EnsureReady(context.Background())
	elapsed := time.Since(begin)
	if err == nil {
		t.Fatal("不回应 initialize 的 socket 必须在总超时内失败")
	}
	if elapsed > 3*time.Second {
		t.Fatalf("EnsureReady 应受默认总超时约束，实际耗时 %v", elapsed)
	}
	if !strings.Contains(err.Error(), "仍存在") {
		t.Fatalf("已有 socket 的初始化超时应报告为无法连接现有 socket：%v", err)
	}
	if started.Load() != 0 {
		t.Fatal("已有 socket 时不得再启动第二个 resident")
	}
}

func TestStartResidentCommandConnectsStdioToNullDevice(t *testing.T) {
	if _, err := os.Stat("/proc/self/fd"); err != nil {
		if _, lookErr := exec.LookPath("lsof"); lookErr != nil {
			t.Skip("需要 /proc 或 lsof 才能检查子进程的标准输出去向")
		}
	}
	root := t.TempDir()
	marker := filepath.Join(root, "resident-stdio")
	// dash（Ubuntu 的 /bin/sh）会先在父 shell 上应用 `cmd >&3` 的重定向再 fork，直接
	// readlink /proc/$$/fd/1 会读到被临时改写的 fd。命令替换在子 shell 里运行，父 shell 的
	// fd 1/2 保持原样，读完再统一写到 fd 3。
	script := `exec 3>"$MIMI_RESIDENT_STDIO_MARKER"; if [ -d /proc/$$/fd ]; then out=$(readlink /proc/$$/fd/1); err=$(readlink /proc/$$/fd/2); else out=$(lsof -a -p $$ -d 1 -Fn | sed -n 's/^n//p'); err=$(lsof -a -p $$ -d 2 -Fn | sed -n 's/^n//p'); fi; printf '%s\n%s\n' "$out" "$err" >&3; sleep 1`
	if err := startResidentCommand("/bin/sh", []string{"-c", script}, map[string]string{
		"HOME":                       root,
		"MIMI_RESIDENT_STDIO_MARKER": marker,
		"PATH":                       os.Getenv("PATH"),
	}); err != nil {
		t.Fatal(err)
	}
	var contents []byte
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		var readErr error
		contents, readErr = os.ReadFile(marker)
		if readErr == nil && len(strings.Fields(string(contents))) >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	targets := strings.Fields(string(contents))
	if len(targets) < 2 {
		t.Fatalf("未能读取 resident 的 stdout/stderr 去向：%q", contents)
	}
	for _, target := range targets {
		if target != "/dev/null" {
			// 管道意味着 resident 仍依赖启动它的进程；agentd 退出后写日志会得到 EPIPE。
			t.Fatalf("resident 的标准输出必须直连空设备而不是父进程管道，got %q", targets)
		}
	}
}
