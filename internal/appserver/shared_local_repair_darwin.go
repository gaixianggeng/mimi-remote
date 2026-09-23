//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/sys/unix"
)

const (
	sharedLocalRepairDefaultTimeout = 15 * time.Second
	sharedLocalRepairExitTimeout    = 5 * time.Second
	sharedLocalRepairRPCFrameCap    = 1 << 20
	sharedLocalRepairPageLimit      = 100
	sharedLocalRepairMaxPages       = 1000
	sharedLocalRepairLsofOutputCap  = 64 << 10
)

type sharedLocalRepairProcess struct {
	PID       int
	UID       uint32
	StartSec  int64
	StartUSec int32
	Name      string
}

type sharedLocalRepairRPC interface {
	Call(context.Context, string, any, any) error
}

type sharedLocalRepairConnection interface {
	Initialize(context.Context) error
	PeerIdentity() (int, uint32, error)
	ValidateSession(context.Context) error
	ResetAfterSessionProbe() error
	RPC() sharedLocalRepairRPC
	Close() error
}

type sharedLocalRepairOps struct {
	validateLaunch func(context.Context) error
	socketState    func(string) (bool, bool, error)
	dial           func(context.Context, SharedLocalOptions) (sharedLocalRepairConnection, error)
	process        func(int) (sharedLocalRepairProcess, bool, error)
	socketNames    func(context.Context, int, string) (int, error)
	signalTERM     func(int) error
	now            func() time.Time
	wait           func(context.Context, time.Duration) error
}

func ReleaseSharedLocalBackgroundServer(ctx context.Context, options SharedLocalOptions) (SharedLocalSessionRepairResult, error) {
	return releaseSharedLocalBackgroundServer(ctx, options, defaultSharedLocalRepairOps())
}

func releaseSharedLocalBackgroundServer(
	ctx context.Context,
	options SharedLocalOptions,
	ops sharedLocalRepairOps,
) (SharedLocalSessionRepairResult, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, sharedLocalRepairDefaultTimeout)
		defer cancel()
	}
	if err := ops.validateLaunch(ctx); err != nil {
		return SharedLocalSessionRepairResult{}, err
	}
	socket, err := SharedLocalSocketPath(options.Env)
	if err != nil {
		return SharedLocalSessionRepairResult{}, err
	}
	exists, isSocket, err := ops.socketState(socket)
	if err != nil {
		return SharedLocalSessionRepairResult{}, fmt.Errorf("检查共享 Codex socket 失败：%w", err)
	}
	if !exists {
		return SharedLocalSessionRepairResult{Message: "未发现共享 Codex App Server，无需释放"}, nil
	}
	if !isSocket {
		return SharedLocalSessionRepairResult{}, errors.New("共享 Codex socket 路径被非 socket 文件占用，拒绝释放")
	}

	conn, err := ops.dial(ctx, options)
	if err != nil {
		return SharedLocalSessionRepairResult{}, fmt.Errorf("连接已有共享 Codex App Server 失败：%w", err)
	}
	defer conn.Close()
	if err := conn.Initialize(ctx); err != nil {
		return SharedLocalSessionRepairResult{}, fmt.Errorf("初始化已有共享 Codex App Server 连接失败：%w", err)
	}
	pid, peerUID, err := conn.PeerIdentity()
	if err != nil {
		return SharedLocalSessionRepairResult{}, fmt.Errorf("读取共享 Codex App Server Unix peer 身份失败：%w", err)
	}
	if pid <= 1 || pid == os.Getpid() || peerUID != uint32(os.Getuid()) {
		return SharedLocalSessionRepairResult{}, errors.New("共享 Codex App Server Unix peer 不属于当前用户，拒绝释放")
	}
	original, alive, err := ops.process(pid)
	if err != nil || !alive {
		return SharedLocalSessionRepairResult{}, errors.New("无法确认共享 Codex App Server 进程身份，拒绝释放")
	}
	if err := validateSharedLocalRepairProcess(original, pid, peerUID); err != nil {
		return SharedLocalSessionRepairResult{}, err
	}

	sessionErr := conn.ValidateSession(ctx)
	if sessionErr == nil {
		return SharedLocalSessionRepairResult{Message: "共享 Codex App Server 已在用户登录会话（Aqua），无需释放"}, nil
	}
	var typedSessionErr *SharedLocalSessionError
	if !errors.As(sessionErr, &typedSessionErr) || typedSessionErr.Kind != "background" {
		return SharedLocalSessionRepairResult{}, fmt.Errorf("无法安全确认共享 Codex App Server 为 Background 会话，拒绝释放：%w", sessionErr)
	}
	if err := conn.ResetAfterSessionProbe(); err != nil {
		return SharedLocalSessionRepairResult{}, fmt.Errorf("重置共享 Codex App Server 探针连接失败：%w", err)
	}

	if err := requireSharedLocalRepairClientCount(ctx, ops, original, socket); err != nil {
		return SharedLocalSessionRepairResult{}, err
	}
	if err := requireSharedLocalRepairIdle(ctx, conn.RPC()); err != nil {
		return SharedLocalSessionRepairResult{}, err
	}
	// 状态检查期间可能出现新客户端或 PID 复用。发信号前必须重新核对两项事实。
	if err := requireSharedLocalRepairClientCount(ctx, ops, original, socket); err != nil {
		return SharedLocalSessionRepairResult{}, err
	}
	current, alive, err := ops.process(pid)
	if err != nil || !alive || current != original {
		return SharedLocalSessionRepairResult{}, errors.New("共享 Codex App Server 进程身份在检查期间发生变化，拒绝释放")
	}
	if err := ctx.Err(); err != nil {
		return SharedLocalSessionRepairResult{}, errors.New("安全释放请求已取消，未向共享 Codex App Server 发送信号")
	}
	if err := ops.signalTERM(pid); err != nil {
		return SharedLocalSessionRepairResult{}, fmt.Errorf("向共享 Codex App Server 发送 SIGTERM 失败：%w", err)
	}
	if err := waitSharedLocalRepairExit(ctx, ops, original, socket); err != nil {
		return SharedLocalSessionRepairResult{}, err
	}
	return SharedLocalSessionRepairResult{
		Released: true,
		Message:  "已安全释放空闲的 Background 共享 Codex App Server",
	}, nil
}

func validateSharedLocalRepairProcess(process sharedLocalRepairProcess, pid int, uid uint32) error {
	if process.PID != pid || process.UID != uid || process.Name != "codex" || process.StartSec <= 0 {
		return errors.New("Unix peer 不是可确认的当前用户 codex 进程，拒绝释放")
	}
	return nil
}

func requireSharedLocalRepairClientCount(
	ctx context.Context,
	ops sharedLocalRepairOps,
	process sharedLocalRepairProcess,
	socket string,
) error {
	current, alive, err := ops.process(process.PID)
	if err != nil || !alive || current != process {
		return errors.New("共享 Codex App Server 进程身份已变化，拒绝释放")
	}
	count, err := ops.socketNames(ctx, process.PID, socket)
	if err != nil {
		return fmt.Errorf("核对共享 Codex socket 客户端失败：%w", err)
	}
	if count != 2 {
		return fmt.Errorf("共享 Codex socket 仍有其他客户端或文件描述符状态未知（目标引用数=%d），拒绝释放", count)
	}
	return nil
}

func requireSharedLocalRepairIdle(ctx context.Context, rpc sharedLocalRepairRPC) error {
	if rpc == nil {
		return errors.New("共享 Codex App Server RPC 未初始化，拒绝释放")
	}
	cursor := ""
	seenCursors := map[string]struct{}{}
	seenThreads := map[string]struct{}{}
	for page := 0; page < sharedLocalRepairMaxPages; page++ {
		params := map[string]any{"limit": sharedLocalRepairPageLimit}
		if cursor != "" {
			params["cursor"] = cursor
		}
		var result sharedLocalRepairPage
		if err := rpc.Call(ctx, "thread/loaded/list", params, &result); err != nil {
			return fmt.Errorf("读取已加载线程失败，拒绝释放：%w", err)
		}
		ids, next, err := result.threadIDs()
		if err != nil {
			return fmt.Errorf("已加载线程响应无效，拒绝释放：%w", err)
		}
		for _, threadID := range ids {
			if _, duplicate := seenThreads[threadID]; duplicate {
				return errors.New("已加载线程分页包含重复线程，拒绝释放")
			}
			seenThreads[threadID] = struct{}{}
			if err := requireSharedLocalRepairThreadIdle(ctx, rpc, threadID); err != nil {
				return err
			}
		}
		if next == "" {
			return nil
		}
		if _, duplicate := seenCursors[next]; duplicate {
			return errors.New("已加载线程分页 cursor 重复，拒绝释放")
		}
		seenCursors[next] = struct{}{}
		cursor = next
	}
	return errors.New("已加载线程分页超过安全上限，拒绝释放")
}

type sharedLocalRepairPage struct {
	Data       json.RawMessage `json:"data"`
	NextCursor json.RawMessage `json:"nextCursor"`
}

func (p sharedLocalRepairPage) threadIDs() ([]string, string, error) {
	if p.Data == nil || p.NextCursor == nil {
		return nil, "", errors.New("缺少 data 或 nextCursor")
	}
	var ids []string
	if err := json.Unmarshal(p.Data, &ids); err != nil || ids == nil {
		return nil, "", errors.New("data 不是线程 ID 数组")
	}
	for _, id := range ids {
		if strings.TrimSpace(id) == "" {
			return nil, "", errors.New("线程 ID 为空")
		}
	}
	next, err := sharedLocalRepairNextCursor(p.NextCursor)
	return ids, next, err
}

func sharedLocalRepairNextCursor(raw json.RawMessage) (string, error) {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return "", nil
	}
	var cursor string
	if json.Unmarshal(raw, &cursor) != nil || strings.TrimSpace(cursor) == "" {
		return "", errors.New("nextCursor 不是 null 或非空字符串")
	}
	return cursor, nil
}

func requireSharedLocalRepairThreadIdle(ctx context.Context, rpc sharedLocalRepairRPC, threadID string) error {
	var read struct {
		Thread json.RawMessage `json:"thread"`
	}
	if err := rpc.Call(ctx, "thread/read", map[string]any{
		"threadId": threadID, "includeTurns": false,
	}, &read); err != nil {
		return fmt.Errorf("读取线程状态失败，拒绝释放：%w", err)
	}
	var thread struct {
		ID     *string `json:"id"`
		Status *struct {
			Type *string `json:"type"`
		} `json:"status"`
	}
	if read.Thread == nil || json.Unmarshal(read.Thread, &thread) != nil ||
		thread.ID == nil || *thread.ID != threadID || thread.Status == nil || thread.Status.Type == nil {
		return errors.New("线程状态响应缺失必要字段，拒绝释放")
	}
	if *thread.Status.Type != "idle" && *thread.Status.Type != "notLoaded" {
		return errors.New("共享 Codex App Server 仍有活动或等待中的线程，拒绝释放")
	}
	return requireSharedLocalRepairQueueEmpty(ctx, rpc, threadID)
}

func requireSharedLocalRepairQueueEmpty(ctx context.Context, rpc sharedLocalRepairRPC, threadID string) error {
	cursor := ""
	seen := map[string]struct{}{}
	for page := 0; page < sharedLocalRepairMaxPages; page++ {
		params := map[string]any{"threadId": threadID, "limit": sharedLocalRepairPageLimit}
		if cursor != "" {
			params["cursor"] = cursor
		}
		var result sharedLocalRepairPage
		if err := rpc.Call(ctx, "thread/queue/list", params, &result); err != nil {
			return fmt.Errorf("读取线程等待队列失败，拒绝释放：%w", err)
		}
		if result.Data == nil || result.NextCursor == nil {
			return errors.New("线程等待队列响应缺失 data 或 nextCursor，拒绝释放")
		}
		var pending []json.RawMessage
		if json.Unmarshal(result.Data, &pending) != nil || pending == nil {
			return errors.New("线程等待队列 data 不是数组，拒绝释放")
		}
		if len(pending) != 0 {
			return errors.New("共享 Codex App Server 仍有等待中的输入，拒绝释放")
		}
		next, err := sharedLocalRepairNextCursor(result.NextCursor)
		if err != nil {
			return fmt.Errorf("线程等待队列响应无效，拒绝释放：%w", err)
		}
		if next == "" {
			return nil
		}
		if _, duplicate := seen[next]; duplicate {
			return errors.New("线程等待队列分页 cursor 重复，拒绝释放")
		}
		seen[next] = struct{}{}
		cursor = next
	}
	return errors.New("线程等待队列分页超过安全上限，拒绝释放")
}

func waitSharedLocalRepairExit(
	ctx context.Context,
	ops sharedLocalRepairOps,
	process sharedLocalRepairProcess,
	socket string,
) error {
	exitCtx, cancel := context.WithDeadline(ctx, minSharedLocalRepairDeadline(
		ops.now().Add(sharedLocalRepairExitTimeout), ctx,
	))
	defer cancel()
	for {
		exists, _, socketErr := ops.socketState(socket)
		current, alive, processErr := ops.process(process.PID)
		if socketErr != nil || processErr != nil {
			return errors.New("SIGTERM 后无法确认共享 Codex App Server 已退出")
		}
		originalAlive := alive && current == process
		if !exists && !originalAlive {
			return nil
		}
		if err := ops.wait(exitCtx, 50*time.Millisecond); err != nil {
			return errors.New("SIGTERM 后等待共享 Codex App Server 退出超时；未发送 SIGKILL，也未删除 socket")
		}
	}
}

func minSharedLocalRepairDeadline(limit time.Time, ctx context.Context) time.Time {
	if deadline, ok := ctx.Deadline(); ok && deadline.Before(limit) {
		return deadline
	}
	return limit
}

func defaultSharedLocalRepairOps() sharedLocalRepairOps {
	return sharedLocalRepairOps{
		validateLaunch: validateSharedLocalLaunchSession,
		socketState:    realSharedLocalRepairSocketState,
		dial:           dialSharedLocalRepairConnection,
		process:        realSharedLocalRepairProcess,
		socketNames:    realSharedLocalRepairSocketNames,
		signalTERM:     func(pid int) error { return unix.Kill(pid, unix.SIGTERM) },
		now:            time.Now,
		wait: func(ctx context.Context, delay time.Duration) error {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-timer.C:
				return nil
			}
		},
	}
}

func realSharedLocalRepairSocketState(path string) (bool, bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	return true, info.Mode()&os.ModeSocket != 0, nil
}

type websocketSharedLocalRepairConnection struct {
	conn *websocket.Conn
	rpc  *websocketSharedLocalRepairRPC
}

func dialSharedLocalRepairConnection(
	ctx context.Context,
	options SharedLocalOptions,
) (sharedLocalRepairConnection, error) {
	transport, err := NewSharedLocalTransport(options)
	if err != nil {
		return nil, err
	}
	dialer, err := transport.rawWebSocketDialer(4 * time.Second)
	if err != nil {
		return nil, err
	}
	url, err := transport.WebSocketURL()
	if err != nil {
		return nil, err
	}
	conn, response, err := dialer.DialContext(ctx, url, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return nil, err
	}
	return &websocketSharedLocalRepairConnection{
		conn: conn,
		rpc:  &websocketSharedLocalRepairRPC{conn: conn},
	}, nil
}

func (c *websocketSharedLocalRepairConnection) Initialize(ctx context.Context) error {
	return initializeWebSocket(ctx, c.conn)
}

func (c *websocketSharedLocalRepairConnection) PeerIdentity() (int, uint32, error) {
	return sharedLocalPeerIdentity(c.conn.UnderlyingConn())
}

func (c *websocketSharedLocalRepairConnection) ValidateSession(ctx context.Context) error {
	return validateSharedLocalSession(ctx, c.conn)
}

func (c *websocketSharedLocalRepairConnection) ResetAfterSessionProbe() error {
	if err := c.conn.SetReadDeadline(time.Time{}); err != nil {
		return err
	}
	if err := c.conn.SetWriteDeadline(time.Time{}); err != nil {
		return err
	}
	c.conn.SetReadLimit(sharedLocalRepairRPCFrameCap)
	return nil
}

func (c *websocketSharedLocalRepairConnection) RPC() sharedLocalRepairRPC { return c.rpc }
func (c *websocketSharedLocalRepairConnection) Close() error              { return c.conn.Close() }

type websocketSharedLocalRepairRPC struct {
	conn   *websocket.Conn
	nextID int
}

func (r *websocketSharedLocalRepairRPC) Call(ctx context.Context, method string, params any, result any) error {
	r.nextID++
	id := fmt.Sprintf("mimi-runtime-repair-%d", r.nextID)
	if deadline, ok := ctx.Deadline(); ok {
		_ = r.conn.SetReadDeadline(deadline)
		_ = r.conn.SetWriteDeadline(deadline)
	}
	if err := r.conn.WriteJSON(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		return errors.New("写入 app-server RPC 失败")
	}
	for {
		_, raw, err := r.conn.ReadMessage()
		if err != nil {
			return errors.New("读取 app-server RPC 响应失败")
		}
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Result json.RawMessage `json:"result"`
			Error  *RPCError       `json:"error"`
		}
		if json.Unmarshal(raw, &frame) != nil {
			return errors.New("app-server RPC 响应不是合法 JSON")
		}
		var responseID string
		if frame.Method != "" || json.Unmarshal(frame.ID, &responseID) != nil || responseID != id {
			continue
		}
		if frame.Error != nil {
			return fmt.Errorf("app-server %s RPC error code=%d", method, frame.Error.Code)
		}
		if frame.Result == nil || json.Unmarshal(frame.Result, result) != nil {
			return fmt.Errorf("app-server %s 响应结构无效", method)
		}
		return nil
	}
}

func realSharedLocalRepairProcess(pid int) (sharedLocalRepairProcess, bool, error) {
	infos, err := unix.SysctlKinfoProcSlice("kern.proc.pid", pid)
	if err != nil {
		return sharedLocalRepairProcess{}, false, err
	}
	if len(infos) == 0 {
		return sharedLocalRepairProcess{}, false, nil
	}
	if len(infos) != 1 || int(infos[0].Proc.P_pid) != pid {
		return sharedLocalRepairProcess{}, false, errors.New("sysctl 返回了未知进程")
	}
	info := &infos[0]
	return sharedLocalRepairProcess{
		PID:       pid,
		UID:       info.Eproc.Ucred.Uid,
		StartSec:  info.Proc.P_starttime.Sec,
		StartUSec: info.Proc.P_starttime.Usec,
		Name:      darwinProcessName(info.Proc.P_comm[:]),
	}, true, nil
}

func darwinProcessName(raw []byte) string {
	name := make([]byte, 0, len(raw))
	for _, value := range raw {
		if value == 0 {
			break
		}
		name = append(name, value)
	}
	return string(name)
}

func realSharedLocalRepairSocketNames(ctx context.Context, pid int, socket string) (int, error) {
	commandCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(
		commandCtx,
		"/usr/sbin/lsof", "-nP", "-a", "-U", "-p", strconv.Itoa(pid), "-F", "pn",
	)
	var output cappedSharedLocalRepairBuffer
	output.limit = sharedLocalRepairLsofOutputCap
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return 0, errors.New("lsof 无法确认目标 socket")
	}
	return countSharedLocalRepairSocketNames(output.Bytes(), pid, socket)
}

type cappedSharedLocalRepairBuffer struct {
	bytes.Buffer
	limit int
}

func (b *cappedSharedLocalRepairBuffer) Write(data []byte) (int, error) {
	if len(data) > b.limit-b.Len() {
		return 0, errors.New("lsof 输出超过安全上限")
	}
	return b.Buffer.Write(data)
}

func countSharedLocalRepairSocketNames(output []byte, pid int, socket string) (int, error) {
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	seenPID := false
	count := 0
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "p"):
			value, err := strconv.Atoi(strings.TrimPrefix(line, "p"))
			if err != nil || value != pid || seenPID {
				return 0, errors.New("lsof 返回了未知进程")
			}
			seenPID = true
		case strings.HasPrefix(line, "n"):
			if !seenPID {
				return 0, errors.New("lsof name 缺少进程归属")
			}
			name := strings.TrimPrefix(line, "n")
			if name == socket || strings.HasPrefix(name, socket+" type=") {
				count++
			}
		}
	}
	if !seenPID {
		return 0, errors.New("lsof 未返回目标进程")
	}
	return count, nil
}
