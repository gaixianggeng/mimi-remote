package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/debuglog"
	"github.com/gaixianggeng/mimi-remote/internal/diagnosticlog"
)

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func captureStdLog(t *testing.T) *lockedBuffer {
	t.Helper()
	var out lockedBuffer
	previous := log.Writer()
	log.SetOutput(&out)
	t.Cleanup(func() { log.SetOutput(previous) })
	return &out
}

func installDebugLog(t *testing.T) (*lockedBuffer, *debuglog.Sink) {
	t.Helper()
	var out lockedBuffer
	sink := debuglog.New(&out, func() bool { return true })
	restore := debuglog.Install(sink)
	t.Cleanup(restore)
	return &out, sink
}

func TestClaudeBridgeStderrRoutesDebugLinesOnlyToTheDebugLog(t *testing.T) {
	std := captureStdLog(t)
	debug, sink := installDebugLog(t)
	input := strings.Join([]string{
		"[mimi-claude-adapter] debug rpc method=thread/list ms=3",
		"[mimi-claude-adapter] trace sdk.message thread=t1",
		"[mimi-claude-adapter] info listening on /tmp/bridge.sock",
		"[mimi-claude-adapter] warn claude.failed thread=t1",
		"alleycat-claude-bridge plain line",
	}, "\n") + "\n"
	captureClaudeBridgeStderr(strings.NewReader(input), nil)
	sink.Close()

	stdText := std.String()
	for _, hidden := range []string{"debug rpc", "trace sdk.message"} {
		if strings.Contains(stdText, hidden) {
			t.Fatalf("debug/trace 行不应进标准日志：%q", stdText)
		}
	}
	for _, kept := range []string{"info listening", "warn claude.failed", "plain line"} {
		if !strings.Contains(stdText, kept) {
			t.Fatalf("标准日志缺少 %q：%q", kept, stdText)
		}
	}
	debugText := debug.String()
	for _, line := range []string{"debug rpc method=thread/list", "info listening", "warn claude.failed", "plain line"} {
		if !strings.Contains(debugText, line) {
			t.Fatalf("调试日志缺少 %q：%q", line, debugText)
		}
	}
	if !strings.Contains(debugText, " claude-bridge [mimi-claude-adapter] debug rpc") {
		t.Fatalf("调试日志的来源标记不对：%q", debugText)
	}
}

func TestClaudeBridgeStderrKeepsDrainingAfterAnOversizedLine(t *testing.T) {
	captureStdLog(t)
	reader, writer := io.Pipe()
	done := make(chan struct{})
	go func() {
		captureClaudeBridgeStderr(reader, nil)
		close(done)
	}()
	oversized := make(chan struct{})
	go func() {
		_, _ = writer.Write([]byte(strings.Repeat("x", 2<<20) + "\n"))
		_, _ = writer.Write([]byte("[mimi-claude-adapter] info still flowing\n"))
		close(oversized)
	}()
	select {
	case <-oversized:
	case <-time.After(5 * time.Second):
		t.Fatal("超长行之后 bridge 的 stderr 不能被卡住")
	}
	_ = writer.Close()
	<-done
}

func TestClaudeBridgeEnvDefaultsTheAdapterToDebugUnlessConfigured(t *testing.T) {
	has := func(environment []string, entry string) bool {
		for _, value := range environment {
			if value == entry {
				return true
			}
		}
		return false
	}
	if !has(buildClaudeBridgeEnv(nil), claudeAdapterLogLevelEnv+"=debug") {
		t.Fatal("默认应让适配器输出 debug 行，由 agentd 决定是否落盘")
	}
	configured := buildClaudeBridgeEnv(map[string]string{claudeAdapterLogLevelEnv: "warn"})
	if !has(configured, claudeAdapterLogLevelEnv+"=warn") || has(configured, claudeAdapterLogLevelEnv+"=debug") {
		t.Fatal("claude.env 里显式设置的级别优先")
	}
}

func TestPolicyRejectionRecordsTheMethodSafelyAndTheReasonInTheDebugLog(t *testing.T) {
	var safe lockedBuffer
	recorder, err := diagnosticlog.New(&safe)
	if err != nil {
		t.Fatal(err)
	}
	restore := diagnosticlog.Install(recorder)
	defer restore()
	defer recorder.Close()
	debug, sink := installDebugLog(t)

	monitor := newRelayMonitor()
	policyErr := &appServerGatewayPolicyError{message: "Claude 通道不支持 thread/name/set", data: map[string]any{"reason": "method_not_allowed"}}
	monitor.recordGatewayPolicyError("conn-1", "client_to_upstream", "claude", []byte(`{"id":7,"method":"thread/name/set","params":{"threadId":"t1","name":"secret title"}}`), policyErr, time.Millisecond)
	monitor.recordGatewayPolicyError("conn-1", "client_to_upstream", "claude", []byte(`{"id":8,"method":"thread/list","params":{}}`), policyErr, time.Millisecond)
	if err := recorder.Sync(nil); err != nil {
		t.Fatal(err)
	}
	sink.Close()

	var operations []string
	for _, line := range strings.Split(strings.TrimSpace(safe.String()), "\n") {
		var event diagnosticlog.Event
		if json.Unmarshal([]byte(line), &event) != nil {
			t.Fatalf("安全日志行无效：%q", line)
		}
		operations = append(operations, event.Operation)
	}
	if strings.Join(operations, ",") != "other,thread/list" {
		t.Fatalf("安全日志只能记白名单方法名：%v", operations)
	}
	if strings.Contains(safe.String(), "thread/name/set") || strings.Contains(safe.String(), "secret title") {
		t.Fatalf("安全日志泄露了方法名或参数：%q", safe.String())
	}
	debugText := debug.String()
	for _, want := range []string{"policy rejected runtime=claude direction=client_to_upstream method=thread/name/set reason=method_not_allowed", "Claude 通道不支持 thread/name/set"} {
		if !strings.Contains(debugText, want) {
			t.Fatalf("调试日志缺少 %q：%q", want, debugText)
		}
	}
	if strings.Contains(debugText, "secret title") {
		t.Fatalf("调试日志不应记录请求参数：%q", debugText)
	}
}
