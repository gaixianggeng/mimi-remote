package appserver

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	sshHelperEnv           = "MIMI_SSH_HELPER"
	sshHelperProxyDelayEnv = "MIMI_SSH_PROXY_DELAY"
)

func TestSSHHelperProcess(t *testing.T) {
	if os.Getenv(sshHelperEnv) != "1" {
		return
	}
	args := os.Args
	separator := -1
	for index, arg := range args {
		if arg == "--" {
			separator = index
			break
		}
	}
	if separator < 0 || separator+1 >= len(args) {
		os.Exit(90)
	}
	sshArgs := args[separator+1:]
	appendSSHHelperLog(strings.Join(sshArgs, "\t"))
	command := sshArgs[len(sshArgs)-1]
	switch command {
	case sshCodexVersionRemoteCommand:
		if os.Getenv("MIMI_SSH_VERSION_FAIL") == "1" {
			fmt.Fprint(os.Stderr, "Host key verification failed.\n")
			os.Exit(255)
		}
		fmt.Print("codex-cli 0.149.1\n")
	case sshSocketStateCommand:
		if helperFileExists(os.Getenv("MIMI_SSH_SERVER_MARKER")) {
			fmt.Print("socket-present")
		} else {
			fmt.Print("socket-missing")
		}
	case sshBootstrapRemoteCommand:
		if err := os.WriteFile(os.Getenv("MIMI_SSH_SERVER_MARKER"), []byte("ready"), 0o600); err != nil {
			os.Exit(91)
		}
	case sshProxyRemoteCommand:
		if !helperFileExists(os.Getenv("MIMI_SSH_SERVER_MARKER")) || helperFileExists(os.Getenv("MIMI_SSH_FAIL_MARKER")) {
			os.Exit(92)
		}
		if delay, err := time.ParseDuration(os.Getenv(sshHelperProxyDelayEnv)); err == nil && delay > 0 {
			time.Sleep(delay)
		}
		serveSSHHelperWebSocket()
		if exitMarker := os.Getenv("MIMI_SSH_PROXY_EXIT_MARKER"); exitMarker != "" {
			_ = os.WriteFile(exitMarker, []byte("exited"), 0o600)
		}
	default:
		os.Exit(93)
	}
	os.Exit(0)
}

func TestSSHCommandArgsAreNonInteractiveAndTargetIsAnArgument(t *testing.T) {
	args := sshCommandArgs("user@host", sshProxyRemoteCommand)
	want := []string{"-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"}
	if len(args) < len(want)+2 || strings.Join(args[:len(want)], "|") != strings.Join(want, "|") {
		t.Fatalf("SSH 必须固定为非交互并严格校验 host key：%v", args)
	}
	if args[len(args)-2] != "user@host" || args[len(args)-1] != sshProxyRemoteCommand {
		t.Fatalf("target 和固定远端命令必须是独立 argv：%v", args)
	}
	for _, target := range []string{"", "-proxy", "user @host", "host\ncommand"} {
		if err := ValidateSSHTarget(target); err == nil {
			t.Fatalf("应拒绝不安全 target %q", target)
		}
	}
}

func TestSSHBootstrapAloneDisablesPersistedRemoteControl(t *testing.T) {
	const remoteControlEnv = "CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1"
	if !strings.Contains(sshBootstrapRemoteCommand, remoteControlEnv) {
		t.Fatalf("resident App Server bootstrap 必须关闭 persisted Remote Control：%s", sshBootstrapRemoteCommand)
	}
	if strings.Contains(sshProxyRemoteCommand, remoteControlEnv) {
		t.Fatalf("SSH proxy 不应覆盖官方 environment identity：%s", sshProxyRemoteCommand)
	}
}

func TestSSHRemoteCodexCommandsUseDeterministicUserPath(t *testing.T) {
	for name, command := range map[string]string{
		"version":   sshCodexVersionRemoteCommand,
		"proxy":     sshProxyRemoteCommand,
		"bootstrap": sshBootstrapRemoteCommand,
	} {
		for _, path := range []string{
			"$HOME/.local/bin",
			"$HOME/.npm-global/bin",
			"$HOME/.local/share/mise/shims",
			"$HOME/.local/share/mise/installs/codex/latest/bin",
			"/opt/homebrew/bin",
		} {
			if !strings.Contains(command, path) {
				t.Fatalf("%s 命令缺少常见 Codex 路径 %q：%s", name, path, command)
			}
		}
		if !strings.Contains(command, "export PATH") || strings.Index(command, "export PATH") > strings.LastIndex(command, "codex") {
			t.Fatalf("%s 命令必须先固定 PATH 再执行 Codex：%s", name, command)
		}
	}
}

func TestSSHRemoteCodexVersionFindsMiseInstallWithoutShellRC(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test requires a POSIX shell")
	}
	home := t.TempDir()
	codexBin := filepath.Join(home, ".local", "share", "mise", "shims", "codex")
	if err := os.MkdirAll(filepath.Dir(codexBin), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(codexBin, []byte("#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.152.1'\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("/bin/sh", "-c", sshCodexVersionRemoteCommand)
	cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin"}
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("非交互 shell 未找到 mise Codex：%v，输出：%s", err, output)
	}
	if strings.TrimSpace(string(output)) != "codex-cli 0.152.1" {
		t.Fatalf("Codex 版本输出不正确：%q", output)
	}
}

func TestSSHBootstrapGuaranteesOpenFileCapacityBeforeStartingResident(t *testing.T) {
	limitCheck := "ulimit -Sn"
	limitRaise := fmt.Sprintf("ulimit -Sn %d", sshAppServerOpenFileSoftLimit)
	residentStart := "nohup env"
	for _, required := range []string{limitCheck, limitRaise, residentStart} {
		if !strings.Contains(sshBootstrapRemoteCommand, required) {
			t.Fatalf("bootstrap 缺少 %q：%s", required, sshBootstrapRemoteCommand)
		}
	}
	if strings.Index(sshBootstrapRemoteCommand, limitCheck) > strings.Index(sshBootstrapRemoteCommand, residentStart) ||
		strings.Index(sshBootstrapRemoteCommand, limitRaise) > strings.Index(sshBootstrapRemoteCommand, residentStart) {
		t.Fatalf("必须在启动 resident 前确认 open-file soft limit：%s", sshBootstrapRemoteCommand)
	}
	if strings.Contains(sshBootstrapRemoteCommand, limitRaise+" || true") {
		t.Fatalf("无法提高 open-file soft limit 时必须阻止低上限 resident 启动：%s", sshBootstrapRemoteCommand)
	}
}

func TestSSHBootstrapResidentInheritsRaisedOpenFileLimit(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("SSH Unix resident 只在 Unix 主机启动")
	}
	hardOutput, err := exec.Command("/bin/sh", "-c", "ulimit -Hn").Output()
	if err != nil {
		t.Fatalf("读取测试 shell hard limit：%v", err)
	}
	hardLimit := strings.TrimSpace(string(hardOutput))
	if hardLimit != "unlimited" {
		value, parseErr := strconv.Atoi(hardLimit)
		if parseErr != nil {
			t.Fatalf("解析测试 shell hard limit %q：%v", hardLimit, parseErr)
		}
		if value < sshAppServerOpenFileSoftLimit {
			t.Skipf("测试环境 hard limit %d 低于 resident 要求 %d", value, sshAppServerOpenFileSoftLimit)
		}
	}

	directory := t.TempDir()
	marker := filepath.Join(directory, "resident-limit")
	fakeCodex := filepath.Join(directory, ".local", "bin", "codex")
	if err := os.MkdirAll(filepath.Dir(fakeCodex), 0o755); err != nil {
		t.Fatalf("创建 fake Codex 目录：%v", err)
	}
	if err := os.WriteFile(fakeCodex, []byte("#!/bin/sh\nulimit -Sn > \"$MIMI_BOOTSTRAP_LIMIT_MARKER\"\n"), 0o755); err != nil {
		t.Fatalf("创建 fake codex：%v", err)
	}
	t.Setenv("MIMI_BOOTSTRAP_LIMIT_MARKER", marker)
	t.Setenv("HOME", directory)
	command := exec.Command("/bin/sh", "-c", "ulimit -Sn 256; "+sshBootstrapRemoteCommand)
	command.Env = os.Environ()
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("执行 bootstrap shell：%v，output=%s", err, strings.TrimSpace(string(output)))
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		output, readErr := os.ReadFile(marker)
		if readErr == nil {
			limit, parseErr := strconv.Atoi(strings.TrimSpace(string(output)))
			if parseErr != nil || limit < sshAppServerOpenFileSoftLimit {
				t.Fatalf("resident 继承的 open-file soft limit=%q，至少应为 %d", strings.TrimSpace(string(output)), sshAppServerOpenFileSoftLimit)
			}
			break
		}
		if !errors.Is(readErr, os.ErrNotExist) {
			t.Fatalf("读取 resident limit marker：%v", readErr)
		}
		if time.Now().After(deadline) {
			t.Fatal("fake resident 未写入 open-file soft limit")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestCodexVersionParsingAcceptsPrereleaseBuildsAndPreservesMinimumGate(t *testing.T) {
	for _, testCase := range []struct {
		output string
		want   string
	}{
		{output: "codex-cli 0.149.1\n", want: "0.149.1"},
		{output: "codex-cli 0.151.0-alpha.7.1\n", want: "0.151.0-alpha.7.1"},
		{output: "codex-cli v0.151.0-alpha.7.1+local\n", want: "0.151.0-alpha.7.1"},
	} {
		got, ok := ParseCodexVersion(testCase.output)
		if !ok || got != testCase.want {
			t.Fatalf("ParseCodexVersion(%q) = %q, %t; want %q", testCase.output, got, ok, testCase.want)
		}
	}
	if CompareCodexVersions("0.151.0-alpha.7.1", MinimumCodexVersion) <= 0 {
		t.Fatal("更高 core 版本的 prerelease 应通过 0.149.1 最低版本门槛")
	}
	if CompareCodexVersions("0.149.1-alpha.1", MinimumCodexVersion) >= 0 {
		t.Fatal("与最低版本同 core 的 prerelease 不能冒充稳定版本")
	}
}

func TestSSHTransportChecksVersionAndRealInitialize(t *testing.T) {
	transport, logPath, _, _ := newSSHHelperTransport(t, true)
	version, err := transport.CheckRemoteCodex(context.Background())
	if err != nil || version != MinimumCodexVersion {
		t.Fatalf("版本检查失败：version=%q err=%v", version, err)
	}
	if err := transport.EnsureReady(context.Background()); err != nil {
		t.Fatalf("真实 initialize 探测失败：%v", err)
	}
	log := readSSHHelperLog(t, logPath)
	if !strings.Contains(log, "BatchMode=yes") || !strings.Contains(log, "StrictHostKeyChecking=yes") || !strings.Contains(log, sshProxyRemoteCommand) {
		t.Fatalf("SSH 调用缺少固定参数或 initialize proxy：%s", log)
	}
}

func TestSSHTransportMissingHostKeyReturnsActionableFailure(t *testing.T) {
	transport, logPath, _, _ := newSSHHelperTransport(t, true)
	t.Setenv("MIMI_SSH_VERSION_FAIL", "1")
	_, err := transport.CheckRemoteCodex(context.Background())
	if err == nil || !strings.Contains(err.Error(), "SSH host/auth") || !strings.Contains(err.Error(), "ssh 127.0.0.1") || !strings.Contains(err.Error(), sshCodexVersionRemoteCommand) {
		t.Fatalf("缺少 host key 时应返回可执行检查命令：%v", err)
	}
	log := readSSHHelperLog(t, logPath)
	if !strings.Contains(log, "StrictHostKeyChecking=yes") || !strings.Contains(log, "BatchMode=yes") {
		t.Fatalf("host key 失败路径也必须禁止交互：%s", log)
	}
}

func TestSSHTransportBootstrapsOnlyWhenSocketMissing(t *testing.T) {
	transport, logPath, _, _ := newSSHHelperTransport(t, false)
	if err := transport.EnsureReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	log := readSSHHelperLog(t, logPath)
	if strings.Count(log, sshBootstrapRemoteCommand) != 1 || !strings.Contains(log, sshSocketStateCommand) {
		t.Fatalf("socket missing 时必须只 bootstrap 一次：%s", log)
	}

	present, presentLog, _, failMarker := newSSHHelperTransport(t, true)
	if err := os.WriteFile(failMarker, []byte("fail"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := present.EnsureReady(context.Background()); err == nil {
		t.Fatal("socket present 但 proxy 失败时不能 bootstrap")
	}
	if strings.Contains(readSSHHelperLog(t, presentLog), sshBootstrapRemoteCommand) {
		t.Fatal("socket present 时禁止 bootstrap")
	}
}

func TestSSHTransportSingleFlightAndFailureIsNotCached(t *testing.T) {
	transport, logPath, _, failMarker := newSSHHelperTransport(t, true)
	var group sync.WaitGroup
	errorsSeen := make(chan error, 2)
	group.Add(2)
	for range 2 {
		go func() {
			defer group.Done()
			errorsSeen <- transport.EnsureReady(context.Background())
		}()
	}
	group.Wait()
	close(errorsSeen)
	for err := range errorsSeen {
		if err != nil {
			t.Fatal(err)
		}
	}
	if countSSHHelperCommand(t, logPath, sshProxyRemoteCommand) != 1 {
		t.Fatalf("同进程并发探测必须 single-flight：%s", readSSHHelperLog(t, logPath))
	}

	if err := os.WriteFile(failMarker, []byte("fail"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := transport.EnsureReady(context.Background()); err == nil {
		t.Fatal("预期 proxy 失败")
	}
	if err := os.Remove(failMarker); err != nil {
		t.Fatal(err)
	}
	if err := transport.EnsureReady(context.Background()); err != nil {
		t.Fatalf("失败不能永久缓存：%v", err)
	}
}

func TestSSHTransportEachDialUsesIndependentProxyAndCloseDoesNotBootstrap(t *testing.T) {
	transport, logPath, _, _ := newSSHHelperTransport(t, true)
	for range 2 {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		conn, _, err := transport.DialWebSocket(ctx, nil)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Close(); err != nil {
			t.Fatal(err)
		}
	}
	log := readSSHHelperLog(t, logPath)
	if countSSHHelperCommand(t, logPath, sshProxyRemoteCommand) != 4 {
		t.Fatalf("两次连接应各有 readiness proxy 和独立长期 proxy：%s", log)
	}
	if strings.Contains(log, sshBootstrapRemoteCommand) {
		t.Fatal("关闭 proxy 不能停止或重启 resident App Server")
	}
}

func TestSSHWebSocketDialerKeepsProxyAliveAfterHandshakeContextCancellation(t *testing.T) {
	transport, _, _, _ := newSSHHelperTransport(t, true)
	exitMarker := filepath.Join(t.TempDir(), "proxy-exited")
	t.Setenv("MIMI_SSH_PROXY_EXIT_MARKER", exitMarker)
	dialer, err := transport.WebSocketDialer(time.Second)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	conn, response, err := dialer.DialContext(ctx, CodexAppServerWebSocketURL, nil)
	cancel()
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	if helperFileExists(exitMarker) {
		t.Fatal("Gorilla 握手 context 结束后 SSH proxy 不应退出")
	}
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	if err := conn.WriteJSON(map[string]any{"id": 1, "method": "initialize", "params": map[string]any{}}); err != nil {
		t.Fatalf("握手返回后 proxy 必须仍可写入：%v", err)
	}
	var frame map[string]any
	if err := conn.ReadJSON(&frame); err != nil || frame["id"] != float64(1) {
		t.Fatalf("握手返回后 proxy 必须仍可读取：frame=%v err=%v", frame, err)
	}
	if helperFileExists(exitMarker) {
		t.Fatal("数据交换期间 SSH proxy 不应退出")
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !helperFileExists(exitMarker) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !helperFileExists(exitMarker) {
		t.Fatal("WebSocket Close 后应结束对应 SSH proxy")
	}
}

func TestSSHProxyConnFallbackDeadlinesUnblockUnsupportedExecPipes(t *testing.T) {
	readPipe := newNoDeadlineReadPipe()
	writePipe := newNoDeadlineWritePipe()
	done := make(chan struct{})
	close(done)
	proxy := &sshProxyConn{stdin: writePipe, stdout: readPipe, doneCh: done}
	if err := proxy.SetReadDeadline(time.Now().Add(20 * time.Millisecond)); err != nil {
		t.Fatalf("不支持原生 deadline 的 read pipe 应启用 fallback：%v", err)
	}
	readResult := make(chan error, 1)
	go func() {
		_, err := proxy.Read(make([]byte, 1))
		readResult <- err
	}()
	select {
	case err := <-readResult:
		if !errors.Is(err, os.ErrDeadlineExceeded) {
			t.Fatalf("read fallback 应返回 timeout：%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("read fallback 未解除阻塞")
	}

	writeProxy := &sshProxyConn{
		stdin:  newNoDeadlineWritePipe(),
		stdout: newNoDeadlineReadPipe(),
		doneCh: done,
	}
	if err := writeProxy.SetWriteDeadline(time.Now().Add(20 * time.Millisecond)); err != nil {
		t.Fatalf("不支持原生 deadline 的 write pipe 应启用 fallback：%v", err)
	}
	writeResult := make(chan error, 1)
	go func() {
		_, err := writeProxy.Write([]byte("x"))
		writeResult <- err
	}()
	select {
	case err := <-writeResult:
		if !errors.Is(err, os.ErrDeadlineExceeded) {
			t.Fatalf("write fallback 应返回 timeout：%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("write fallback 未解除阻塞")
	}
}

func TestSSHProxyConnFallbackDeadlineResetInvalidatesStaleCallback(t *testing.T) {
	readPipe := newNoDeadlineReadPipe()
	writePipe := newNoDeadlineWritePipe()
	done := make(chan struct{})
	close(done)
	proxy := &sshProxyConn{stdin: writePipe, stdout: readPipe, doneCh: done}
	if err := proxy.SetReadDeadline(time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	proxy.stateMu.Lock()
	staleGeneration := proxy.readDeadlineGeneration
	proxy.stateMu.Unlock()
	if err := proxy.SetReadDeadline(time.Time{}); err != nil {
		t.Fatalf("清零 read deadline 失败：%v", err)
	}
	proxy.expireFallbackDeadline(true, staleGeneration)
	if readPipe.isClosed() {
		t.Fatal("清零 deadline 后旧 generation callback 不得关闭 pipe")
	}

	if err := proxy.SetDeadline(time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := proxy.Close(); err != nil {
		t.Fatal(err)
	}
	proxy.stateMu.Lock()
	defer proxy.stateMu.Unlock()
	if proxy.readDeadlineTimer != nil || proxy.writeDeadlineTimer != nil {
		t.Fatal("Close 必须清理 fallback deadline timers")
	}
}

func TestSSHProxyConnFallbackDeadlineCloseAndResetAreAtomic(t *testing.T) {
	readPipe := newGatedNoDeadlineReadPipe()
	done := make(chan struct{})
	close(done)
	proxy := &sshProxyConn{
		stdin:  newNoDeadlineWritePipe(),
		stdout: readPipe,
		doneCh: done,
	}
	proxy.stateMu.Lock()
	proxy.readDeadlineGeneration = 7
	proxy.stateMu.Unlock()
	expired := make(chan struct{})
	go func() {
		proxy.expireFallbackDeadline(true, 7)
		close(expired)
	}()
	<-readPipe.closeStarted
	if proxy.stateMu.TryLock() {
		proxy.stateMu.Unlock()
		close(readPipe.allowClose)
		<-expired
		t.Fatal("deadline callback 校验 generation 后不能在关闭 pipe 前释放状态锁")
	}

	reset := make(chan error, 1)
	go func() {
		reset <- proxy.SetReadDeadline(time.Time{})
	}()
	close(readPipe.allowClose)
	<-expired
	if err := <-reset; err != nil {
		t.Fatalf("deadline callback 完成后清零失败：%v", err)
	}
}

func newSSHHelperTransport(t *testing.T, ready bool) (*SSHTransport, string, string, string) {
	t.Helper()
	dir := t.TempDir()
	wrapper := filepath.Join(dir, "ssh")
	logPath := filepath.Join(dir, "ssh.log")
	serverMarker := filepath.Join(dir, "server-ready")
	failMarker := filepath.Join(dir, "proxy-fail")
	if runtime.GOOS == "windows" {
		wrapper += ".cmd"
		script := "@echo off\r\n\"%MIMI_SSH_TEST_BINARY%\" -test.run=TestSSHHelperProcess -- %*\r\n"
		if err := os.WriteFile(wrapper, []byte(script), 0o600); err != nil {
			t.Fatal(err)
		}
	} else {
		script := "#!/bin/sh\nexec \"$MIMI_SSH_TEST_BINARY\" -test.run=TestSSHHelperProcess -- \"$@\"\n"
		if err := os.WriteFile(wrapper, []byte(script), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if ready {
		if err := os.WriteFile(serverMarker, []byte("ready"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv(sshHelperEnv, "1")
	t.Setenv("MIMI_SSH_TEST_BINARY", os.Args[0])
	t.Setenv("MIMI_SSH_LOG", logPath)
	t.Setenv("MIMI_SSH_SERVER_MARKER", serverMarker)
	t.Setenv("MIMI_SSH_FAIL_MARKER", failMarker)
	transport, err := NewSSHTransport(SSHTransportOptions{
		Target: "127.0.0.1", SSHBin: wrapper,
		ReadyTimeout: 5 * time.Second, BootstrapTimeout: 3 * time.Second, RetryInterval: 10 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	return transport, logPath, serverMarker, failMarker
}

func serveSSHHelperWebSocket() {
	reader := bufio.NewReader(os.Stdin)
	key := ""
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			os.Exit(94)
		}
		if strings.HasPrefix(strings.ToLower(line), "sec-websocket-key:") {
			key = strings.TrimSpace(strings.TrimPrefix(line, "Sec-WebSocket-Key:"))
		}
		if line == "\r\n" {
			break
		}
	}
	digest := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	fmt.Fprintf(os.Stdout, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(digest[:]))
	_ = readSSHHelperFrame(reader)
	writeSSHHelperFrame([]byte(`{"id":1,"result":{"userAgent":"codex_cli_rs/0.149.1"}}`))
	_, _ = io.Copy(io.Discard, reader)
}

func readSSHHelperFrame(reader *bufio.Reader) []byte {
	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil
	}
	length := int(header[1] & 0x7f)
	if length == 126 {
		raw := make([]byte, 2)
		_, _ = io.ReadFull(reader, raw)
		length = int(binary.BigEndian.Uint16(raw))
	}
	mask := make([]byte, 4)
	_, _ = io.ReadFull(reader, mask)
	payload := make([]byte, length)
	_, _ = io.ReadFull(reader, payload)
	for index := range payload {
		payload[index] ^= mask[index%4]
	}
	return payload
}

func writeSSHHelperFrame(payload []byte) {
	header := []byte{0x81, byte(len(payload))}
	if len(payload) >= 126 {
		header = []byte{0x81, 126, byte(len(payload) >> 8), byte(len(payload))}
	}
	_, _ = os.Stdout.Write(append(header, payload...))
}

func appendSSHHelperLog(line string) {
	path := os.Getenv("MIMI_SSH_LOG")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		os.Exit(95)
	}
	_, _ = fmt.Fprintln(file, line)
	_ = file.Close()
}

func helperFileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func readSSHHelperLog(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func countSSHHelperCommand(t *testing.T, path, command string) int {
	t.Helper()
	return strings.Count(readSSHHelperLog(t, path), command)
}

type noDeadlineReadPipe struct {
	closed chan struct{}
	once   sync.Once
}

func newNoDeadlineReadPipe() *noDeadlineReadPipe {
	return &noDeadlineReadPipe{closed: make(chan struct{})}
}

func (p *noDeadlineReadPipe) Read([]byte) (int, error) {
	<-p.closed
	return 0, os.ErrClosed
}

func (p *noDeadlineReadPipe) Close() error {
	p.once.Do(func() { close(p.closed) })
	return nil
}

func (p *noDeadlineReadPipe) SetReadDeadline(time.Time) error { return os.ErrNoDeadline }

func (p *noDeadlineReadPipe) isClosed() bool {
	select {
	case <-p.closed:
		return true
	default:
		return false
	}
}

type noDeadlineWritePipe struct {
	closed chan struct{}
	once   sync.Once
}

func newNoDeadlineWritePipe() *noDeadlineWritePipe {
	return &noDeadlineWritePipe{closed: make(chan struct{})}
}

func (p *noDeadlineWritePipe) Write([]byte) (int, error) {
	<-p.closed
	return 0, os.ErrClosed
}

func (p *noDeadlineWritePipe) Close() error {
	p.once.Do(func() { close(p.closed) })
	return nil
}

func (p *noDeadlineWritePipe) SetWriteDeadline(time.Time) error { return os.ErrNoDeadline }

type gatedNoDeadlineReadPipe struct {
	*noDeadlineReadPipe
	closeStarted chan struct{}
	allowClose   chan struct{}
	startOnce    sync.Once
}

func newGatedNoDeadlineReadPipe() *gatedNoDeadlineReadPipe {
	return &gatedNoDeadlineReadPipe{
		noDeadlineReadPipe: newNoDeadlineReadPipe(),
		closeStarted:       make(chan struct{}),
		allowClose:         make(chan struct{}),
	}
}

func (p *gatedNoDeadlineReadPipe) Close() error {
	p.startOnce.Do(func() { close(p.closeStarted) })
	<-p.allowClose
	return p.noDeadlineReadPipe.Close()
}
