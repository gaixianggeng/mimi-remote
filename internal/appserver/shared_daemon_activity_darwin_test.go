//go:build darwin

package appserver

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRequireSharedDaemonIdleAcceptsOnlyStableIdleSnapshots(t *testing.T) {
	tests := []struct {
		name      string
		loaded    [][]string
		statuses  map[string]string
		wantErr   string
		wantLists int32
	}{
		{name: "no loaded tasks", loaded: [][]string{{}}, wantLists: 4},
		{
			name:      "all idle",
			loaded:    [][]string{{"thread-b", "thread-a"}},
			statuses:  map[string]string{"thread-a": "idle", "thread-b": "idle"},
			wantLists: 4,
		},
		{
			name:      "loaded task reports not loaded",
			loaded:    [][]string{{"thread-a"}},
			statuses:  map[string]string{"thread-a": "notLoaded"},
			wantErr:   "未知 task 状态",
			wantLists: 1,
		},
		{
			name:      "active turn",
			loaded:    [][]string{{"thread-a"}},
			statuses:  map[string]string{"thread-a": "active"},
			wantErr:   "1 个活动 Turn",
			wantLists: 1,
		},
		{
			name:      "system error",
			loaded:    [][]string{{"thread-a"}},
			statuses:  map[string]string{"thread-a": "systemError"},
			wantErr:   "系统错误状态",
			wantLists: 1,
		},
		{
			name:      "unknown state",
			loaded:    [][]string{{"thread-a"}},
			statuses:  map[string]string{"thread-a": "paused"},
			wantErr:   "未知 task 状态",
			wantLists: 1,
		},
		{
			name:      "duplicate task identity",
			loaded:    [][]string{{"thread-a", "thread-a"}},
			wantErr:   "重复 task 身份",
			wantLists: 1,
		},
		{
			name:      "empty task identity",
			loaded:    [][]string{{""}},
			wantErr:   "无效 task 身份",
			wantLists: 1,
		},
		{
			name:      "loaded set keeps changing",
			loaded:    [][]string{{"thread-a"}, {"thread-b"}, {"thread-a"}, {"thread-b"}},
			statuses:  map[string]string{"thread-a": "idle", "thread-b": "idle"},
			wantErr:   "检查期间发生变化",
			wantLists: 4,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			codexHome := shortCodexHome(t)
			socketPath, listCalls := startSharedDaemonActivityTestServer(
				t,
				codexHome,
				test.loaded,
				test.statuses,
				nil,
			)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			err := requireSharedDaemonIdle(ctx, socketPath)
			if test.wantErr == "" && err != nil {
				t.Fatalf("稳定空闲快照应允许停止：%v", err)
			}
			if test.wantErr != "" && (err == nil || !strings.Contains(err.Error(), test.wantErr)) {
				t.Fatalf("应拒绝不安全状态 %q：%v", test.wantErr, err)
			}
			if got := listCalls.Load(); got != test.wantLists {
				t.Fatalf("thread/loaded/list 调用数错误：got=%d want=%d", got, test.wantLists)
			}
		})
	}
}

func TestRequireSharedDaemonIdleReadsEveryLoadedThreadPage(t *testing.T) {
	codexHome := shortCodexHome(t)
	socketPath, listCalls := startSharedDaemonActivityTestServer(
		t,
		codexHome,
		nil,
		map[string]string{"thread-idle": "idle", "thread-active": "active"},
		func(_ int, params map[string]any) map[string]any {
			cursor, _ := params["cursor"].(string)
			if cursor == "page-2" {
				return map[string]any{"data": []string{"thread-active"}, "nextCursor": nil}
			}
			return map[string]any{"data": []string{"thread-idle"}, "nextCursor": "page-2"}
		},
	)
	err := requireSharedDaemonIdle(context.Background(), socketPath)
	if err == nil || !strings.Contains(err.Error(), "1 个活动 Turn") {
		t.Fatalf("第二页活动 Turn 必须阻止停止：%v", err)
	}
	if got := listCalls.Load(); got != 2 {
		t.Fatalf("必须读取到最后一页：got=%d want=2", got)
	}
}

func TestRequireSharedDaemonIdleRejectsMalformedLoadedThreadPages(t *testing.T) {
	tests := []struct {
		name    string
		result  map[string]any
		wantErr string
	}{
		{name: "missing data", result: map[string]any{"nextCursor": nil}, wantErr: "缺少 data"},
		{name: "null data", result: map[string]any{"data": nil, "nextCursor": nil}, wantErr: "缺少 data"},
		{name: "missing next cursor", result: map[string]any{"data": []string{}}, wantErr: "缺少 nextCursor"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			codexHome := shortCodexHome(t)
			socketPath, _ := startSharedDaemonActivityTestServer(
				t,
				codexHome,
				nil,
				nil,
				func(int, map[string]any) map[string]any { return test.result },
			)
			err := requireSharedDaemonIdle(context.Background(), socketPath)
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("畸形分页响应必须 fail closed：%v", err)
			}
		})
	}
}

func TestRequireSharedDaemonIdleRejectsRepeatedLoadedThreadCursor(t *testing.T) {
	codexHome := shortCodexHome(t)
	socketPath, listCalls := startSharedDaemonActivityTestServer(
		t,
		codexHome,
		nil,
		nil,
		func(call int, _ map[string]any) map[string]any {
			return map[string]any{"data": []string{fmt.Sprintf("thread-%d", call)}, "nextCursor": "same"}
		},
	)
	err := requireSharedDaemonIdle(context.Background(), socketPath)
	if err == nil || !strings.Contains(err.Error(), "重复分页 cursor") {
		t.Fatalf("重复 cursor 必须阻止停止：%v", err)
	}
	if got := listCalls.Load(); got != 2 {
		t.Fatalf("重复 cursor 后不应继续分页：got=%d want=2", got)
	}
}

func TestRequireManagedSharedDaemonIdleForStopRejectsActiveTurn(t *testing.T) {
	originalDesktop := sharedDaemonDesktopRunning
	originalRequireIdle := sharedDaemonRequireIdle
	var activityChecks atomic.Int32
	sharedDaemonDesktopRunning = func(context.Context) (bool, error) { return false, nil }
	sharedDaemonRequireIdle = func(context.Context, string) error {
		activityChecks.Add(1)
		return errors.New("共享 daemon 仍有 1 个活动 Turn，拒绝停止")
	}
	t.Cleanup(func() {
		sharedDaemonDesktopRunning = originalDesktop
		sharedDaemonRequireIdle = originalRequireIdle
	})

	err := requireManagedSharedDaemonIdleForStop(
		context.Background(),
		LocalDaemonOptions{},
		"/tmp/app.sock",
		LocalDaemonLifecycleStatus{},
		nil,
	)
	if err == nil || !strings.Contains(err.Error(), "活动 Turn") {
		t.Fatalf("活动 Turn 必须阻止优雅排空：%v", err)
	}
	if activityChecks.Load() != 1 {
		t.Fatalf("停止前活动检查次数错误：%d", activityChecks.Load())
	}
}

func TestRequestSharedDaemonGracefulDrainSignalsVerifiedPIDOnce(t *testing.T) {
	originalSignal := sharedDaemonSignalGraceful
	var signaled []int
	sharedDaemonSignalGraceful = func(pid int) error {
		signaled = append(signaled, pid)
		return nil
	}
	t.Cleanup(func() { sharedDaemonSignalGraceful = originalSignal })

	listener := sharedDaemonListenerProcess{PID: 4321}
	if err := requestSharedDaemonGracefulDrain(listener); err != nil {
		t.Fatalf("已验证 listener 应收到一次 SIGHUP：%v", err)
	}
	if !slices.Equal(signaled, []int{listener.PID}) {
		t.Fatalf("优雅排空必须只命中已验证 PID：%v", signaled)
	}

	for _, pid := range []int{0, 1} {
		if err := requestSharedDaemonGracefulDrain(sharedDaemonListenerProcess{PID: pid}); err == nil {
			t.Fatalf("PID %d 必须在发送信号前被拒绝", pid)
		}
	}
	if !slices.Equal(signaled, []int{listener.PID}) {
		t.Fatalf("非法 PID 不得进入信号实现：%v", signaled)
	}
}

func TestManagedGracefulDrainRejectsListenerSwapDuringFinalDesktopCheck(t *testing.T) {
	originalRequireIdle := sharedDaemonRequireIdle
	originalDesktop := sharedDaemonDesktopRunning
	originalInspect := sharedDaemonInspectBeforeStop
	originalCapture := sharedDaemonCaptureSignedRuntimeIdentity
	originalSignal := sharedDaemonSignalGraceful
	t.Cleanup(func() {
		sharedDaemonRequireIdle = originalRequireIdle
		sharedDaemonDesktopRunning = originalDesktop
		sharedDaemonInspectBeforeStop = originalInspect
		sharedDaemonCaptureSignedRuntimeIdentity = originalCapture
		sharedDaemonSignalGraceful = originalSignal
	})

	first := sharedDaemonListenerProcess{PID: 4321, UID: 501, StartSec: 10}
	replacement := first
	replacement.PID = 5432
	replacement.StartSec++
	swapped := false
	current := func() sharedDaemonListenerProcess {
		if swapped {
			return replacement
		}
		return first
	}
	sharedDaemonRequireIdle = func(context.Context, string) error { return nil }
	sharedDaemonInspectBeforeStop = func(context.Context, string) (sharedDaemonListenerProcess, error) {
		return current(), nil
	}
	sharedDaemonCaptureSignedRuntimeIdentity = func(
		context.Context,
		LocalDaemonOptions,
		string,
	) (sharedDaemonListenerProcess, error) {
		return current(), nil
	}
	sharedDaemonDesktopRunning = func(context.Context) (bool, error) {
		swapped = true
		return false, nil
	}
	signalCalls := 0
	sharedDaemonSignalGraceful = func(int) error { signalCalls++; return nil }
	pID := uint32(first.PID)

	err := requireManagedSharedDaemonIdleForStop(
		context.Background(),
		LocalDaemonOptions{},
		"/tmp/app.sock",
		LocalDaemonLifecycleStatus{PID: &pID},
		&first,
	)
	if err == nil {
		err = requestSharedDaemonGracefulDrain(first)
	}
	if err == nil || !strings.Contains(err.Error(), "Desktop 复核后") || signalCalls != 0 {
		t.Fatalf("Desktop 探测期间换主必须在 SIGHUP 前 fail closed：signal=%d err=%v", signalCalls, err)
	}
}

func TestStopUnmanagedSharedDaemonRevalidatesAfterIdleCheck(t *testing.T) {
	process := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	inspectCalls := 0
	signalCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		process.Executable,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				inspectCalls++
				return process, nil
			},
			requireIdle:    func(context.Context, string) error { return nil },
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return 501 },
		},
	)
	if err != nil {
		t.Fatalf("空闲且身份稳定时应允许 SIGHUP：%v", err)
	}
	if inspectCalls != 5 || signalCalls != 1 {
		t.Fatalf("活动检查后必须重新复核身份：inspect=%d signal=%d", inspectCalls, signalCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsListenerSwapAfterIdleCheck(t *testing.T) {
	first := sharedDaemonListenerProcess{
		PID: 1234, UID: 501, StartSec: 1786522048, StartUsec: 123,
		Command: "codex app-server --listen unix://", Executable: "/tmp/codex-real",
	}
	replacement := first
	replacement.PID = 5678
	replacement.StartUsec++
	inspectCalls := 0
	signalCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		first.Executable,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				inspectCalls++
				if inspectCalls <= 2 {
					return first, nil
				}
				return replacement, nil
			},
			requireIdle:    func(context.Context, string) error { return nil },
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "活动检查前身份不一致") {
		t.Fatalf("活动检查后替换 listener 必须停止迁移：%v", err)
	}
	if signalCalls != 0 {
		t.Fatalf("不得终止替换进来的 listener：signal=%d", signalCalls)
	}
}

type sharedDaemonLoadedListResponder func(call int, params map[string]any) map[string]any

func startSharedDaemonActivityTestServer(
	t *testing.T,
	codexHome string,
	loaded [][]string,
	statuses map[string]string,
	loadedResult sharedDaemonLoadedListResponder,
) (string, *atomic.Int32) {
	t.Helper()
	socketDir := filepath.Join(codexHome, localDaemonSocketDir)
	if err := os.MkdirAll(socketDir, 0o700); err != nil {
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
	var listCalls atomic.Int32
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		conn, upgradeErr := upgrader.Upgrade(writer, request, nil)
		if upgradeErr != nil {
			return
		}
		defer conn.Close()
		for {
			var frame struct {
				ID     int64          `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if readErr := conn.ReadJSON(&frame); readErr != nil {
				return
			}
			switch frame.Method {
			case "initialized":
				continue
			case "initialize":
				_ = conn.WriteJSON(map[string]any{
					"id": frame.ID,
					"result": map[string]any{
						"userAgent": "mimi_remote_restart_guard/0.147.0",
						"codexHome": codexHome,
					},
				})
			case "thread/loaded/list":
				call := int(listCalls.Add(1)) - 1
				result := map[string]any{"data": []string{}, "nextCursor": nil}
				if loadedResult != nil {
					result = loadedResult(call, frame.Params)
				} else if len(loaded) > 0 {
					result["data"] = loaded[min(call, len(loaded)-1)]
				}
				_ = conn.WriteJSON(map[string]any{
					"id":     frame.ID,
					"result": result,
				})
			case "thread/read":
				threadID, _ := frame.Params["threadId"].(string)
				_ = conn.WriteJSON(map[string]any{
					"id": frame.ID,
					"result": map[string]any{
						"thread": map[string]any{
							"id":     threadID,
							"status": map[string]any{"type": statuses[threadID]},
						},
					},
				})
			default:
				_ = conn.WriteJSON(map[string]any{
					"id":    frame.ID,
					"error": map[string]any{"code": -32601, "message": "unsupported"},
				})
			}
		}
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		_ = server.Close()
		_ = listener.Close()
	})
	return socketPath, &listCalls
}
