package appserver

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const sshHelperEnv = "MIMI_SSH_HELPER"

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
	case "codex --version":
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
	if err == nil || !strings.Contains(err.Error(), "SSH host/auth") || !strings.Contains(err.Error(), "ssh 127.0.0.1 codex --version") {
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

func newSSHHelperTransport(t *testing.T, ready bool) (*SSHTransport, string, string, string) {
	t.Helper()
	dir := t.TempDir()
	wrapper := filepath.Join(dir, "ssh")
	logPath := filepath.Join(dir, "ssh.log")
	serverMarker := filepath.Join(dir, "server-ready")
	failMarker := filepath.Join(dir, "proxy-fail")
	script := "#!/bin/sh\nexec \"$MIMI_SSH_TEST_BINARY\" -test.run=TestSSHHelperProcess -- \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
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
