package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"strconv"
	"strings"
	"sync"
)

// claudeBridgeRPC 直接对 resident Claude bridge 的 socket 发 JSON-RPC，供 agentd 的
// 内部任务（自动标题）使用。不发 `_alleycat/attach`：bridge 会给这条连接一个匿名
// 隔离会话，连接关闭即回收，不留 replay ring，也不会和移动端会话共用序号。
// 请求/响应语义与 runtimeWebSocketRPC 一致：反向 request 一律拒绝，通知丢弃。
type claudeBridgeRPC struct {
	conn    net.Conn
	reader  *bufio.Reader
	writeMu sync.Mutex
	nextID  int64
	// stopCancelClose 解除 context 取消时的关连接钩子，正常关闭时先解除再关。
	stopCancelClose func() bool
}

func newClaudeBridgeRPC(conn net.Conn) *claudeBridgeRPC {
	return &claudeBridgeRPC{
		conn:   conn,
		reader: bufio.NewReaderSize(conn, 64*1024),
	}
}

func (c *claudeBridgeRPC) close() {
	if c == nil {
		return
	}
	if c.stopCancelClose != nil {
		c.stopCancelClose()
	}
	if c.conn != nil {
		_ = c.conn.Close()
	}
}

func (c *claudeBridgeRPC) initializeClient(ctx context.Context, name string, title string, version string) (string, error) {
	var result struct {
		UserAgent string `json:"userAgent"`
	}
	if err := c.call(ctx, "initialize", map[string]any{
		"clientInfo": map[string]any{
			"name":    name,
			"title":   title,
			"version": version,
		},
		"capabilities": map[string]any{},
	}, &result); err != nil {
		return "", err
	}
	if err := c.notify(ctx, "initialized", map[string]any{}); err != nil {
		return "", err
	}
	return result.UserAgent, nil
}

func (c *claudeBridgeRPC) notify(ctx context.Context, method string, params any) error {
	return c.write(ctx, map[string]any{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
	})
}

func (c *claudeBridgeRPC) call(ctx context.Context, method string, params any, result any) error {
	c.nextID++
	id := c.nextID
	if err := c.write(ctx, map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  method,
		"params":  params,
	}); err != nil {
		return err
	}
	for {
		if err := setRuntimeWebSocketDeadline(ctx, c.conn.SetReadDeadline); err != nil {
			return err
		}
		line, oversize, readErr := readBridgeStdoutLine(c.reader, int(appServerGatewayReadLimit))
		if payload := bytes.TrimSpace(line); !oversize && len(payload) > 0 {
			done, err := c.consumeFrame(ctx, payload, id, result)
			if done || err != nil {
				return err
			}
		}
		if readErr != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return readErr
		}
	}
}

// consumeFrame 处理一帧：目标 id 的响应返回 done=true；反向 request 回标准错误；
// 其余（通知、别的响应）忽略。
func (c *claudeBridgeRPC) consumeFrame(ctx context.Context, payload []byte, id int64, result any) (bool, error) {
	var frame runtimeWebSocketFrame
	if json.Unmarshal(payload, &frame) != nil {
		return false, nil
	}
	if strings.TrimSpace(frame.Method) != "" {
		if runtimeRPCFrameHasID(frame.ID) {
			// 内部任务不拥有审批等宿主能力；拒绝后继续等原调用的响应，
			// 避免相同 id 的反向 request 被误判成成功 response。
			if err := c.write(ctx, map[string]any{
				"jsonrpc": "2.0",
				"id":      frame.ID,
				"error": map[string]any{
					"code":    -32601,
					"message": "internal client does not support server requests",
				},
			}); err != nil {
				return false, err
			}
		}
		return false, nil
	}
	if strings.TrimSpace(string(frame.ID)) != strconv.FormatInt(id, 10) {
		return false, nil
	}
	if frame.Error != nil {
		return true, frame.Error
	}
	if len(frame.Result) == 0 {
		return true, errors.New("Claude bridge RPC 响应缺少 result 或 error")
	}
	if result == nil {
		return true, nil
	}
	return true, json.Unmarshal(frame.Result, result)
}

func (c *claudeBridgeRPC) write(ctx context.Context, payload any) error {
	encoded, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if err := setRuntimeWebSocketDeadline(ctx, c.conn.SetWriteDeadline); err != nil {
		return err
	}
	return writeStdioBridgeCompactedFrame(c.conn, &c.writeMu, encoded)
}

// dialClaudeBridgeRPC 打开一条面向 resident bridge 的内部连接。bridge 未运行时直接
// 报错，调用方按"跳过本次任务"处理，不会为了内部任务去拉起 bridge。
func (r *Router) dialClaudeBridgeRPC(ctx context.Context) (*claudeBridgeRPC, error) {
	if r == nil || r.claudeBridge == nil {
		return nil, errors.New("Claude bridge 未配置")
	}
	conn, _, err := r.claudeBridge.dial()
	if err != nil {
		return nil, err
	}
	// 阻塞读不会因 context 取消自动返回；关闭连接才能保证任务超时或 agentd
	// 关闭时立即退出。
	rpc := newClaudeBridgeRPC(conn)
	rpc.stopCancelClose = context.AfterFunc(ctx, func() {
		_ = conn.Close()
	})
	return rpc, nil
}
