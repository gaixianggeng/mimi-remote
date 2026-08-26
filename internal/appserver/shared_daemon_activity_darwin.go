//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const sharedDaemonActivityCheckTimeout = 5 * time.Second

const (
	sharedDaemonLoadedThreadPageLimit = 100
	sharedDaemonLoadedThreadMax       = 10_000
)

var (
	sharedDaemonRequireIdle       = requireSharedDaemonIdle
	sharedDaemonInspectBeforeStop = inspectSharedDaemonListenerProcess
)

func requireManagedSharedDaemonIdleForStop(
	ctx context.Context,
	options LocalDaemonOptions,
	socketPath string,
	lifecycle LocalDaemonLifecycleStatus,
	expected *sharedDaemonListenerProcess,
) error {
	if err := sharedDaemonRequireIdle(ctx, socketPath); err != nil {
		return fmt.Errorf("停止官方 Codex daemon 前活动检查失败：%w", err)
	}
	if expected != nil {
		if _, err := captureStableManagedSharedDaemonListenerIdentity(
			ctx, options, socketPath, lifecycle, expected,
			sharedDaemonCaptureSignedRuntimeIdentity,
			sharedDaemonInspectBeforeStop,
		); err != nil {
			return fmt.Errorf("活动检查后 listener 身份发生变化：%w", err)
		}
	}
	if err := requireCodexDesktopStopped(ctx, "活动检查后执行优雅排空前"); err != nil {
		return err
	}
	if expected != nil {
		// Desktop 探测会执行进程枚举。信号前必须再绑定一次真实 socket owner，
		// 不能把探测期间退出或被替换的旧 PID 继续当作目标。
		if _, err := captureStableManagedSharedDaemonListenerIdentity(
			ctx, options, socketPath, lifecycle, expected,
			sharedDaemonCaptureSignedRuntimeIdentity,
			sharedDaemonInspectBeforeStop,
		); err != nil {
			return fmt.Errorf("Desktop 复核后 listener 身份发生变化：%w", err)
		}
	}
	return nil
}

type sharedDaemonActivityRPC struct {
	conn   *websocket.Conn
	nextID int64
}

type sharedDaemonLoadedThreadsResult struct {
	Data       json.RawMessage `json:"data"`
	NextCursor json.RawMessage `json:"nextCursor"`
}

type sharedDaemonThreadReadResult struct {
	Thread struct {
		ID     string `json:"id"`
		Status struct {
			Type string `json:"type"`
		} `json:"status"`
	} `json:"thread"`
}

// requireSharedDaemonIdle 连续取得两份稳定快照。App Server 没有把“检查空闲”
// 与“停止服务”合并成原子操作，因此调用方仍需在检查后再次绑定 Desktop 与
// listener 身份，并发送 graceful-only SIGHUP。任何未知状态都必须拒绝停止。
func requireSharedDaemonIdle(ctx context.Context, socketPath string) error {
	checkCtx, cancel := context.WithTimeout(ctx, sharedDaemonActivityCheckTimeout)
	defer cancel()
	rpc, err := openSharedDaemonActivityRPC(checkCtx, socketPath)
	if err != nil {
		return fmt.Errorf("无法读取共享 daemon 活动状态：%w", err)
	}
	defer rpc.close()

	var previous []string
	for attempt := 0; attempt < 2; attempt++ {
		before, err := rpc.loadedThreads(checkCtx)
		if err != nil {
			return err
		}
		if err := rpc.requireThreadsIdle(checkCtx, before); err != nil {
			return err
		}
		after, err := rpc.loadedThreads(checkCtx)
		if err != nil {
			return err
		}
		if !slices.Equal(before, after) {
			previous = nil
			continue
		}
		if previous != nil && slices.Equal(previous, after) {
			return nil
		}
		previous = after
	}
	return fmt.Errorf("共享 daemon 已加载 task 在检查期间发生变化，拒绝停止")
}

func openSharedDaemonActivityRPC(
	ctx context.Context,
	socketPath string,
) (*sharedDaemonActivityRPC, error) {
	if err := validateExistingLocalDaemonSocket(socketPath); err != nil {
		return nil, err
	}
	dialer := LocalDaemonWebSocketDialer(socketPath, localDaemonProbeTimeout)
	conn, response, err := dialer.DialContext(ctx, localDaemonHandshakeURL, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetWriteDeadline(deadline)
		_ = conn.SetReadDeadline(deadline)
	}
	rpc := &sharedDaemonActivityRPC{conn: conn}
	var initialized InitializeResult
	if err := rpc.call(ctx, "initialize", initializeParams{
		ClientInfo: ClientInfo{
			Name:    "mimi_remote_restart_guard",
			Title:   "Mimi Remote Restart Guard",
			Version: "1",
		},
		Capabilities: map[string]any{"experimentalApi": true},
	}, &initialized); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := conn.WriteJSON(map[string]any{
		"method": "initialized",
		"params": map[string]any{},
	}); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return rpc, nil
}

func (r *sharedDaemonActivityRPC) close() {
	if r != nil && r.conn != nil {
		_ = r.conn.Close()
	}
}

func (r *sharedDaemonActivityRPC) call(
	ctx context.Context,
	method string,
	params any,
	result any,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	r.nextID++
	id := r.nextID
	if err := r.conn.WriteJSON(map[string]any{
		"id":     id,
		"method": method,
		"params": params,
	}); err != nil {
		return err
	}
	wantID := newRequestID(id)
	for {
		_, payload, err := r.conn.ReadMessage()
		if err != nil {
			return err
		}
		var frame wireMessage
		if err := json.Unmarshal(payload, &frame); err != nil {
			return fmt.Errorf("解析共享 daemon %s 响应失败：%w", method, err)
		}
		if frame.Method != "" && frame.ID != nil {
			return fmt.Errorf("共享 daemon 在停止检查期间请求了客户端操作，拒绝停止")
		}
		if frame.ID == nil || requestIDFromRaw(*frame.ID) != wantID {
			continue
		}
		if frame.Error != nil {
			return frame.Error
		}
		if result == nil {
			return nil
		}
		if err := json.Unmarshal(frame.Result, result); err != nil {
			return fmt.Errorf("解析共享 daemon %s 结果失败：%w", method, err)
		}
		return nil
	}
}

func (r *sharedDaemonActivityRPC) loadedThreads(ctx context.Context) ([]string, error) {
	seenThreads := make(map[string]struct{})
	seenCursors := make(map[string]struct{})
	threads := make([]string, 0)
	cursor := ""
	for {
		params := map[string]any{"limit": sharedDaemonLoadedThreadPageLimit}
		if cursor != "" {
			params["cursor"] = cursor
		}
		var result sharedDaemonLoadedThreadsResult
		if err := r.call(ctx, "thread/loaded/list", params, &result); err != nil {
			return nil, fmt.Errorf("读取共享 daemon 已加载 task 失败：%w", err)
		}
		data, nextCursor, err := decodeSharedDaemonLoadedThreadsResult(result)
		if err != nil {
			return nil, err
		}
		for _, threadID := range data {
			if strings.TrimSpace(threadID) == "" {
				return nil, fmt.Errorf("共享 daemon 返回了无效 task 身份，拒绝停止")
			}
			if _, exists := seenThreads[threadID]; exists {
				return nil, fmt.Errorf("共享 daemon 返回了重复 task 身份，拒绝停止")
			}
			seenThreads[threadID] = struct{}{}
			threads = append(threads, threadID)
			if len(threads) > sharedDaemonLoadedThreadMax {
				return nil, fmt.Errorf("共享 daemon 已加载 task 数量超出安全检查上限，拒绝停止")
			}
		}
		if nextCursor == "" {
			break
		}
		if _, exists := seenCursors[nextCursor]; exists {
			return nil, fmt.Errorf("共享 daemon 返回了重复分页 cursor，拒绝停止")
		}
		seenCursors[nextCursor] = struct{}{}
		cursor = nextCursor
	}
	sort.Strings(threads)
	return threads, nil
}

func decodeSharedDaemonLoadedThreadsResult(
	result sharedDaemonLoadedThreadsResult,
) ([]string, string, error) {
	if len(result.Data) == 0 || bytes.Equal(bytes.TrimSpace(result.Data), []byte("null")) {
		return nil, "", fmt.Errorf("共享 daemon 已加载 task 响应缺少 data，拒绝停止")
	}
	var data []string
	if err := json.Unmarshal(result.Data, &data); err != nil || data == nil {
		return nil, "", fmt.Errorf("共享 daemon 已加载 task 响应 data 无效，拒绝停止")
	}
	if len(result.NextCursor) == 0 {
		return nil, "", fmt.Errorf("共享 daemon 已加载 task 响应缺少 nextCursor，拒绝停止")
	}
	if bytes.Equal(bytes.TrimSpace(result.NextCursor), []byte("null")) {
		return data, "", nil
	}
	var nextCursor string
	if err := json.Unmarshal(result.NextCursor, &nextCursor); err != nil || strings.TrimSpace(nextCursor) == "" {
		return nil, "", fmt.Errorf("共享 daemon 已加载 task 响应 nextCursor 无效，拒绝停止")
	}
	return data, nextCursor, nil
}

func (r *sharedDaemonActivityRPC) requireThreadsIdle(
	ctx context.Context,
	threadIDs []string,
) error {
	active := 0
	for _, threadID := range threadIDs {
		var result sharedDaemonThreadReadResult
		if err := r.call(ctx, "thread/read", map[string]any{
			"threadId":     threadID,
			"includeTurns": false,
		}, &result); err != nil {
			return fmt.Errorf("读取共享 daemon task 状态失败：%w", err)
		}
		if result.Thread.ID != threadID {
			return fmt.Errorf("共享 daemon 返回了不匹配的 task 身份，拒绝停止")
		}
		switch strings.TrimSpace(result.Thread.Status.Type) {
		case "idle":
		case "active":
			active++
		case "systemError":
			return fmt.Errorf("共享 daemon 存在系统错误状态的 task，拒绝停止")
		default:
			return fmt.Errorf("共享 daemon 返回了未知 task 状态，拒绝停止")
		}
	}
	if active > 0 {
		return fmt.Errorf("共享 daemon 仍有 %d 个活动 Turn，拒绝停止", active)
	}
	return nil
}
