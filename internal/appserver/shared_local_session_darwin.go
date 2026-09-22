//go:build darwin

package appserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const (
	sharedLocalSessionRequestID = "mimi-runtime-session"
	sharedLocalSessionTimeout   = 3 * time.Second
	sharedLocalCommandTimeoutMS = 2000
	sharedLocalOutputBytesCap   = 128
	sharedLocalFrameBytesCap    = 8 << 10
)

// SharedLocalSessionError 表示现有 shared App Server 无法安全复用用户登录会话。
// Kind 只描述失败类别；Error 不包含命令输出或 RPC 文本，避免泄露用户数据。
type SharedLocalSessionError struct {
	Kind string
	Err  error
}

func (e *SharedLocalSessionError) Error() string {
	if e == nil {
		return ""
	}
	switch e.Kind {
	case "background":
		return "已有共享本机 Codex App Server 运行在后台安全会话（Background），无法继承用户登录授权"
	case "unexpected_manager":
		return "已有共享本机 Codex App Server 不在用户登录会话（Aqua），无法继承用户登录授权"
	case "invalid_response":
		return "无法确认已有共享本机 Codex App Server 的登录会话，拒绝复用可能无法继承用户登录授权的后台安全环境"
	case "rpc_error":
		return "已有共享本机 Codex App Server 无法检查登录会话，可能运行在无法继承用户登录授权的后台安全环境"
	case "timeout":
		return "检查已有共享本机 Codex App Server 的登录会话超时，无法确认它能继承用户登录授权"
	default:
		return "检查已有共享本机 Codex App Server 的登录会话失败，无法确认它能继承用户登录授权"
	}
}

func (e *SharedLocalSessionError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// validateSharedLocalSession 在已完成 initialize 的连接上检查 app-server
// 进程所属的 launchd manager。探针不读取 Token，也不创建 thread 或 turn。
func validateSharedLocalSession(ctx context.Context, conn *websocket.Conn) error {
	if conn == nil {
		return newSharedLocalSessionError("invalid_response", errors.New("WebSocket connection 为空"))
	}
	if ctx == nil {
		ctx = context.Background()
	}
	probeCtx, cancel := context.WithTimeout(ctx, sharedLocalSessionTimeout)
	defer cancel()

	deadline, _ := probeCtx.Deadline()
	_ = conn.SetReadDeadline(deadline)
	_ = conn.SetWriteDeadline(deadline)
	conn.SetReadLimit(sharedLocalFrameBytesCap)
	// context 被主动取消时立即打断阻塞的 WebSocket I/O；WithTimeout 会保留调用方
	// 更早的 deadline，因此探针不会延长现有调用的总预算。
	stopInterrupt := context.AfterFunc(probeCtx, func() {
		// Close 可以与 gorilla 的读写并发；SetReadDeadline 本身不是并发安全的。
		_ = conn.Close()
	})
	defer stopInterrupt()

	request := map[string]any{
		"id":     sharedLocalSessionRequestID,
		"method": "command/exec",
		"params": map[string]any{
			"command":        []string{"/bin/launchctl", "managername"},
			"processId":      sharedLocalSessionRequestID,
			"timeoutMs":      sharedLocalCommandTimeoutMS,
			"outputBytesCap": sharedLocalOutputBytesCap,
			"sandboxPolicy":  map[string]any{"type": "dangerFullAccess"},
		},
	}
	if err := conn.WriteJSON(request); err != nil {
		return sharedLocalSessionIOError(probeCtx, err)
	}

	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return sharedLocalSessionIOError(probeCtx, err)
		}
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Result json.RawMessage `json:"result"`
			Error  *RPCError       `json:"error"`
		}
		if err := json.Unmarshal(raw, &frame); err != nil {
			return newSharedLocalSessionError("invalid_response", errors.New("响应不是合法 JSON"))
		}
		// 同一连接可能先到达通知或其他请求的响应；这里只消费自己的固定 ID。
		if frame.Method != "" || !sharedLocalSessionResponseID(frame.ID) {
			continue
		}
		if frame.Error != nil {
			return newSharedLocalSessionError(
				"rpc_error",
				fmt.Errorf("app-server command/exec RPC code=%d", frame.Error.Code),
			)
		}
		return validateSharedLocalSessionResult(frame.Result)
	}
}

func sharedLocalSessionResponseID(raw json.RawMessage) bool {
	var id string
	return json.Unmarshal(raw, &id) == nil && id == sharedLocalSessionRequestID
}

func validateSharedLocalSessionResult(raw json.RawMessage) error {
	var result struct {
		ExitCode *int    `json:"exitCode"`
		Stdout   *string `json:"stdout"`
		Stderr   *string `json:"stderr"`
	}
	if len(raw) == 0 || json.Unmarshal(raw, &result) != nil ||
		result.ExitCode == nil || result.Stdout == nil || result.Stderr == nil {
		return newSharedLocalSessionError("invalid_response", errors.New("command/exec 结果字段缺失"))
	}
	if *result.ExitCode != 0 {
		return newSharedLocalSessionError("invalid_response", errors.New("launchctl managername 执行失败"))
	}
	switch strings.TrimSpace(*result.Stdout) {
	case "Aqua":
		return nil
	case "Background":
		return newSharedLocalSessionError("background", nil)
	default:
		return newSharedLocalSessionError("unexpected_manager", nil)
	}
}

func sharedLocalSessionIOError(ctx context.Context, err error) error {
	if ctxErr := ctx.Err(); ctxErr != nil {
		kind := "transport"
		if errors.Is(ctxErr, context.DeadlineExceeded) {
			kind = "timeout"
		}
		return newSharedLocalSessionError(kind, ctxErr)
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return newSharedLocalSessionError("timeout", context.DeadlineExceeded)
	}
	// WebSocket 错误可能携带本机路径或帧内容，只保留固定的错误类别。
	return newSharedLocalSessionError("transport", errors.New("WebSocket I/O 失败"))
}

func newSharedLocalSessionError(kind string, err error) error {
	return &SharedLocalSessionError{Kind: kind, Err: err}
}
