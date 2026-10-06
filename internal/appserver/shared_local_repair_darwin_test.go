//go:build darwin

package appserver

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestReleaseSharedLocalBackgroundServerReleasesOnce(t *testing.T) {
	harness := newSharedLocalRepairHarness(t)
	result, err := releaseSharedLocalBackgroundServer(
		context.Background(), harness.options, harness.ops,
	)
	if err != nil {
		t.Fatalf("空闲 Background resident 应可安全释放：%v", err)
	}
	if !result.Released || harness.signalCount != 1 {
		t.Fatalf("应只发送一次 SIGTERM：result=%+v signals=%d", result, harness.signalCount)
	}
	if !harness.connection.initialized || !harness.connection.reset || !harness.connection.closed {
		t.Fatalf("连接应 initialize、重置探针限制并关闭：%+v", harness.connection)
	}
	if harness.socketNameCalls != 2 {
		t.Fatalf("客户端计数必须在状态检查前后各执行一次，got %d", harness.socketNameCalls)
	}
	harness.rpc.assertSafeRequests(t)
}

func TestReleaseSharedLocalBackgroundServerNoops(t *testing.T) {
	t.Run("missing socket", func(t *testing.T) {
		harness := newSharedLocalRepairHarness(t)
		harness.socketExists = false
		result, err := releaseSharedLocalBackgroundServer(context.Background(), harness.options, harness.ops)
		if err != nil || result.Released || harness.signalCount != 0 {
			t.Fatalf("缺少 socket 应 noop：result=%+v err=%v signals=%d", result, err, harness.signalCount)
		}
		if harness.connection.initialized {
			t.Fatal("缺少 socket 时不得连接或初始化")
		}
	})

	t.Run("Aqua resident", func(t *testing.T) {
		harness := newSharedLocalRepairHarness(t)
		harness.connection.sessionErr = nil
		result, err := releaseSharedLocalBackgroundServer(context.Background(), harness.options, harness.ops)
		if err != nil || result.Released || harness.signalCount != 0 {
			t.Fatalf("Aqua resident 应 noop：result=%+v err=%v signals=%d", result, err, harness.signalCount)
		}
		if !strings.Contains(result.Message, "Aqua") {
			t.Fatalf("noop 结果应说明 Aqua：%+v", result)
		}
	})
}

func TestReleaseSharedLocalBackgroundServerRefusesWithoutSignal(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*sharedLocalRepairHarness)
	}{
		{name: "caller not Aqua", mutate: func(h *sharedLocalRepairHarness) {
			h.ops.validateLaunch = func(context.Context) error { return errors.New("not Aqua") }
		}},
		{name: "path not socket", mutate: func(h *sharedLocalRepairHarness) { h.socketIsSocket = false }},
		{name: "initialize error", mutate: func(h *sharedLocalRepairHarness) {
			h.connection.initializeErr = errors.New("initialize failed")
		}},
		{name: "peer uid mismatch", mutate: func(h *sharedLocalRepairHarness) { h.connection.uid++ }},
		{name: "peer is caller", mutate: func(h *sharedLocalRepairHarness) { h.connection.pid = os.Getpid() }},
		{name: "process is not codex", mutate: func(h *sharedLocalRepairHarness) { h.process.Name = "other" }},
		{name: "unknown session", mutate: func(h *sharedLocalRepairHarness) {
			h.connection.sessionErr = &SharedLocalSessionError{Kind: "invalid_response"}
		}},
		{name: "extra client", mutate: func(h *sharedLocalRepairHarness) { h.socketNames = 3 }},
		{name: "active thread", mutate: func(h *sharedLocalRepairHarness) {
			h.rpc.threadStatus["thread-idle"] = "active"
		}},
		{name: "pending queue", mutate: func(h *sharedLocalRepairHarness) {
			h.rpc.pending["thread-idle"] = []any{map[string]any{"id": "pending"}}
		}},
		{name: "missing queue schema", mutate: func(h *sharedLocalRepairHarness) {
			h.rpc.omitQueueNextCursor = true
		}},
		{name: "rpc error", mutate: func(h *sharedLocalRepairHarness) {
			h.rpc.errMethod = "thread/read"
		}},
		{name: "client appears before signal", mutate: func(h *sharedLocalRepairHarness) {
			h.socketNamesAtCall = map[int]int{2: 3}
		}},
		{name: "pid reused before signal", mutate: func(h *sharedLocalRepairHarness) {
			h.reusePIDAtProcessCall = 4
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			harness := newSharedLocalRepairHarness(t)
			test.mutate(harness)
			result, err := releaseSharedLocalBackgroundServer(context.Background(), harness.options, harness.ops)
			if err == nil {
				t.Fatalf("不确定状态必须拒绝：result=%+v", result)
			}
			if result.Released || harness.signalCount != 0 {
				t.Fatalf("拒绝路径不得发信号：result=%+v signals=%d err=%v", result, harness.signalCount, err)
			}
		})
	}
}

func TestReleaseSharedLocalBackgroundServerCanceledBeforeSignal(t *testing.T) {
	harness := newSharedLocalRepairHarness(t)
	ctx, cancel := context.WithCancel(context.Background())
	harness.rpc.afterCall = func(method string, params map[string]any) {
		if method == "thread/queue/list" && params["threadId"] == "thread-unloaded" {
			cancel()
		}
	}
	result, err := releaseSharedLocalBackgroundServer(ctx, harness.options, harness.ops)
	if err == nil || result.Released || harness.signalCount != 0 {
		t.Fatalf("取消后不得发信号：result=%+v err=%v signals=%d", result, err, harness.signalCount)
	}
}

func TestWaitSharedLocalRepairExitRejectsProcessLookupError(t *testing.T) {
	process := sharedLocalRepairProcess{PID: 4242, UID: uint32(os.Getuid()), StartSec: 10, Name: "codex"}
	ops := sharedLocalRepairOps{
		socketState: func(string) (bool, bool, error) { return false, false, nil },
		process: func(int) (sharedLocalRepairProcess, bool, error) {
			return sharedLocalRepairProcess{}, false, errors.New("sysctl failed")
		},
		now:  time.Now,
		wait: func(context.Context, time.Duration) error { return nil },
	}
	if err := waitSharedLocalRepairExit(context.Background(), ops, process, "/tmp/socket"); err == nil {
		t.Fatal("socket 消失但进程查询失败时不得误报释放成功")
	}
}

func TestRealSharedLocalRepairProcessReportsReapedChildGone(t *testing.T) {
	cmd := exec.Command("/bin/sleep", "10")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid := cmd.Process.Pid
	if _, alive, err := realSharedLocalRepairProcess(pid); err != nil || !alive {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		t.Fatalf("运行中的测试子进程应可查询：alive=%v err=%v", alive, err)
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	// 被信号结束会让 Wait 返回非零；这里只要求它完成回收。
	_ = cmd.Wait()
	if _, alive, err := realSharedLocalRepairProcess(pid); err != nil || alive {
		t.Fatalf("已回收的测试子进程应返回 gone 而不是 EIO：alive=%v err=%v", alive, err)
	}
}

func TestCountSharedLocalRepairSocketNames(t *testing.T) {
	socket := "/private/tmp/codex/app-server-control.sock"
	output := []byte("p4242\nfcwd\nn/private/tmp/project\nf10\nn" + socket + "\nf11\nn" + socket + " type=STREAM\n")
	count, err := countSharedLocalRepairSocketNames(output, 4242, socket)
	if err != nil || count != 2 {
		t.Fatalf("应只统计目标 socket name：count=%d err=%v", count, err)
	}
	if _, err := countSharedLocalRepairSocketNames([]byte("p7\nn"+socket+"\n"), 4242, socket); err == nil {
		t.Fatal("lsof 返回其他 PID 时必须拒绝")
	}
}

type sharedLocalRepairHarness struct {
	options               SharedLocalOptions
	ops                   sharedLocalRepairOps
	connection            *fakeSharedLocalRepairConnection
	rpc                   *fakeSharedLocalRepairRPC
	process               sharedLocalRepairProcess
	processAlive          bool
	socketExists          bool
	socketIsSocket        bool
	socketNames           int
	socketNamesAtCall     map[int]int
	socketNameCalls       int
	processCalls          int
	reusePIDAtProcessCall int
	signalCount           int
}

func newSharedLocalRepairHarness(t *testing.T) *sharedLocalRepairHarness {
	t.Helper()
	root := shortSharedLocalCodexHome(t)
	rpc := &fakeSharedLocalRepairRPC{
		threadStatus: map[string]string{"thread-idle": "idle", "thread-unloaded": "notLoaded"},
		pending:      map[string][]any{},
	}
	harness := &sharedLocalRepairHarness{
		options:        SharedLocalOptions{Env: map[string]string{"CODEX_HOME": root}},
		rpc:            rpc,
		process:        sharedLocalRepairProcess{PID: 4242, UID: uint32(os.Getuid()), StartSec: 10, StartUSec: 20, Name: "codex"},
		processAlive:   true,
		socketExists:   true,
		socketIsSocket: true,
		socketNames:    2,
	}
	harness.connection = &fakeSharedLocalRepairConnection{
		pid:        harness.process.PID,
		uid:        harness.process.UID,
		sessionErr: &SharedLocalSessionError{Kind: "background"},
		rpc:        rpc,
	}
	harness.ops = sharedLocalRepairOps{
		validateLaunch: func(context.Context) error { return nil },
		socketState: func(string) (bool, bool, error) {
			return harness.socketExists, harness.socketIsSocket, nil
		},
		dial: func(context.Context, SharedLocalOptions) (sharedLocalRepairConnection, error) {
			return harness.connection, nil
		},
		process: func(int) (sharedLocalRepairProcess, bool, error) {
			harness.processCalls++
			if !harness.processAlive {
				return sharedLocalRepairProcess{}, false, nil
			}
			process := harness.process
			if harness.reusePIDAtProcessCall > 0 && harness.processCalls >= harness.reusePIDAtProcessCall {
				process.StartUSec++
			}
			return process, true, nil
		},
		socketNames: func(context.Context, int, string) (int, error) {
			harness.socketNameCalls++
			if count, ok := harness.socketNamesAtCall[harness.socketNameCalls]; ok {
				return count, nil
			}
			return harness.socketNames, nil
		},
		signalTERM: func(pid int) error {
			harness.signalCount++
			if pid != harness.process.PID {
				return errors.New("unexpected pid")
			}
			harness.processAlive = false
			harness.socketExists = false
			return nil
		},
		now: time.Now,
		wait: func(ctx context.Context, _ time.Duration) error {
			return ctx.Err()
		},
	}
	return harness
}

type fakeSharedLocalRepairConnection struct {
	pid           int
	uid           uint32
	initializeErr error
	sessionErr    error
	resetErr      error
	rpc           sharedLocalRepairRPC
	initialized   bool
	reset         bool
	closed        bool
}

func (c *fakeSharedLocalRepairConnection) Initialize(context.Context) error {
	c.initialized = true
	return c.initializeErr
}

func (c *fakeSharedLocalRepairConnection) PeerIdentity() (int, uint32, error) {
	return c.pid, c.uid, nil
}

func (c *fakeSharedLocalRepairConnection) ValidateSession(context.Context) error {
	return c.sessionErr
}

func (c *fakeSharedLocalRepairConnection) ResetAfterSessionProbe() error {
	c.reset = true
	return c.resetErr
}

func (c *fakeSharedLocalRepairConnection) RPC() sharedLocalRepairRPC { return c.rpc }
func (c *fakeSharedLocalRepairConnection) Close() error {
	c.closed = true
	return nil
}

type fakeSharedLocalRepairRPC struct {
	requests            []fakeSharedLocalRepairRequest
	threadStatus        map[string]string
	pending             map[string][]any
	errMethod           string
	omitQueueNextCursor bool
	afterCall           func(string, map[string]any)
}

type fakeSharedLocalRepairRequest struct {
	method string
	params map[string]any
}

func (r *fakeSharedLocalRepairRPC) Call(_ context.Context, method string, params any, result any) error {
	requestParams, _ := params.(map[string]any)
	r.requests = append(r.requests, fakeSharedLocalRepairRequest{method: method, params: requestParams})
	defer func() {
		if r.afterCall != nil {
			r.afterCall(method, requestParams)
		}
	}()
	if method == r.errMethod {
		return errors.New("fake RPC error")
	}
	var response map[string]any
	switch method {
	case "thread/loaded/list":
		if requestParams["cursor"] == nil {
			response = map[string]any{"data": []string{"thread-idle"}, "nextCursor": "next-page"}
		} else {
			response = map[string]any{"data": []string{"thread-unloaded"}, "nextCursor": nil}
		}
	case "thread/read":
		threadID, _ := requestParams["threadId"].(string)
		response = map[string]any{"thread": map[string]any{
			"id": threadID, "status": map[string]any{"type": r.threadStatus[threadID]},
		}}
	case "thread/queue/list":
		threadID, _ := requestParams["threadId"].(string)
		pending, ok := r.pending[threadID]
		if !ok {
			pending = []any{}
		}
		response = map[string]any{"data": pending, "nextCursor": nil}
		if r.omitQueueNextCursor {
			delete(response, "nextCursor")
		}
	default:
		return errors.New("unexpected method")
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		return err
	}
	return json.Unmarshal(encoded, result)
}

func (r *fakeSharedLocalRepairRPC) assertSafeRequests(t *testing.T) {
	t.Helper()
	loadedCalls := 0
	readCalls := 0
	queueCalls := 0
	for _, request := range r.requests {
		switch request.method {
		case "thread/loaded/list":
			loadedCalls++
		case "thread/read":
			readCalls++
			if request.params["includeTurns"] != false {
				t.Fatalf("thread/read 必须固定 includeTurns:false：%v", request.params)
			}
		case "thread/queue/list":
			queueCalls++
		default:
			t.Fatalf("释放检查发送了未知 RPC：%s", request.method)
		}
	}
	if loadedCalls != 2 || readCalls != 2 || queueCalls != 2 {
		t.Fatalf("应分页检查所有加载线程与队列：loaded=%d read=%d queue=%d", loadedCalls, readCalls, queueCalls)
	}
}
