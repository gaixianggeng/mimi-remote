package appserver

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const overloadedErrorCode = -32001

type ServerRequestHandler func(ctx context.Context, req ServerRequest) (any, *RPCError)

type ClientOptions struct {
	ClientInfo           ClientInfo
	Capabilities         map[string]any
	NotificationBuffer   int
	ServerRequestTimeout time.Duration
	OverloadRetries      int
	OverloadBackoff      time.Duration
	ServerRequestHandler ServerRequestHandler
}

type Client struct {
	reader *bufio.Reader
	writer io.Writer

	options ClientOptions

	writeMu  sync.Mutex
	notifyMu sync.RWMutex
	mu       sync.Mutex
	nextID   int64
	pending  map[requestID]chan rpcResponse

	notifications chan Notification
	closed        chan struct{}
	closeOnce     sync.Once
	startOnce     sync.Once

	initialized bool
	readErr     error

	droppedNotifications  uint64
	droppedServerRequests uint64
}

type rpcResponse struct {
	result json.RawMessage
	err    *RPCError
}

func NewClient(stdout io.Reader, stdin io.Writer, options ClientOptions) *Client {
	if options.NotificationBuffer <= 0 {
		options.NotificationBuffer = 128
	}
	if options.ServerRequestTimeout <= 0 {
		options.ServerRequestTimeout = 30 * time.Second
	}
	if options.OverloadBackoff <= 0 {
		options.OverloadBackoff = 50 * time.Millisecond
	}
	if options.OverloadRetries < 0 {
		options.OverloadRetries = 0
	}
	if options.ClientInfo.Name == "" {
		options.ClientInfo = ClientInfo{Name: "mimi_remote", Title: "Mimi Remote", Version: "0.1.0"}
	}
	return &Client{
		reader:        bufio.NewReader(stdout),
		writer:        stdin,
		options:       options,
		pending:       map[requestID]chan rpcResponse{},
		notifications: make(chan Notification, options.NotificationBuffer),
		closed:        make(chan struct{}),
	}
}

func (c *Client) Start() {
	c.startOnce.Do(func() {
		go c.readLoop()
	})
}

func (c *Client) Initialize(ctx context.Context) (InitializeResult, error) {
	c.Start()
	params := initializeParams{
		ClientInfo:   c.options.ClientInfo,
		Capabilities: c.options.Capabilities,
	}
	var result InitializeResult
	if err := c.Call(ctx, "initialize", params, &result); err != nil {
		return InitializeResult{}, err
	}
	if err := c.Notify("initialized", map[string]any{}); err != nil {
		return InitializeResult{}, err
	}
	c.mu.Lock()
	c.initialized = true
	c.mu.Unlock()
	return result, nil
}

func (c *Client) Call(ctx context.Context, method string, params any, result any) error {
	if strings.TrimSpace(method) == "" {
		return fmt.Errorf("app-server method 不能为空")
	}
	attempts := c.options.OverloadRetries + 1
	for attempt := 0; attempt < attempts; attempt++ {
		raw, err := c.callOnce(ctx, method, params)
		if err == nil {
			if result == nil || len(raw) == 0 {
				return nil
			}
			if err := json.Unmarshal(raw, result); err != nil {
				return fmt.Errorf("解析 app-server %s 响应失败：%w", method, err)
			}
			return nil
		}
		var rpcErr *RPCError
		if !errors.As(err, &rpcErr) || rpcErr.Code != overloadedErrorCode || attempt == attempts-1 {
			return err
		}
		timer := time.NewTimer(c.options.OverloadBackoff * time.Duration(attempt+1))
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-c.closed:
			timer.Stop()
			return c.closeError()
		case <-timer.C:
		}
	}
	return nil
}

func (c *Client) Notify(method string, params any) error {
	rawParams, err := encodeParams(params)
	if err != nil {
		return fmt.Errorf("编码 app-server notification 参数失败：%w", err)
	}
	message := map[string]any{
		"method": method,
		"params": json.RawMessage(rawParams),
	}
	return c.writeJSON(message)
}

func (c *Client) Notifications() <-chan Notification {
	return c.notifications
}

func (c *Client) Diagnostics() Diagnostics {
	c.mu.Lock()
	defer c.mu.Unlock()
	return Diagnostics{
		Running:               c.readErr == nil,
		Initialized:           c.initialized,
		PendingRequests:       len(c.pending),
		DroppedNotifications:  atomic.LoadUint64(&c.droppedNotifications),
		DroppedServerRequests: atomic.LoadUint64(&c.droppedServerRequests),
	}
}

func (c *Client) Close() error {
	c.closeWithError(fmt.Errorf("app-server client 已关闭"))
	return nil
}

func (c *Client) callOnce(ctx context.Context, method string, params any) (json.RawMessage, error) {
	c.Start()
	rawParams, err := encodeParams(params)
	if err != nil {
		return nil, fmt.Errorf("编码 app-server %s 参数失败：%w", method, err)
	}
	idNum := atomic.AddInt64(&c.nextID, 1)
	id := newRequestID(idNum)
	responseCh := make(chan rpcResponse, 1)
	c.mu.Lock()
	if c.readErr != nil {
		err := c.readErr
		c.mu.Unlock()
		return nil, err
	}
	c.pending[id] = responseCh
	c.mu.Unlock()

	message := map[string]any{
		"id":     idNum,
		"method": method,
		"params": json.RawMessage(rawParams),
	}
	if err := c.writeJSON(message); err != nil {
		c.removePending(id)
		return nil, err
	}

	select {
	case response := <-responseCh:
		if response.err != nil {
			return nil, response.err
		}
		return response.result, nil
	case <-ctx.Done():
		c.removePending(id)
		return nil, ctx.Err()
	case <-c.closed:
		c.removePending(id)
		return nil, c.closeError()
	}
}

func (c *Client) writeJSON(value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if _, err := c.writer.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("写入 app-server 失败：%w", err)
	}
	return nil
}

func (c *Client) readLoop() {
	for {
		line, err := c.reader.ReadBytes('\n')
		if len(line) > 0 {
			if handleErr := c.handleLine(line); handleErr != nil {
				c.closeWithError(handleErr)
				return
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				c.closeWithError(fmt.Errorf("app-server 输出已关闭"))
				return
			}
			c.closeWithError(fmt.Errorf("读取 app-server 输出失败：%w", err))
			return
		}
	}
}

func (c *Client) handleLine(line []byte) error {
	line = []byte(strings.TrimSpace(string(line)))
	if len(line) == 0 {
		return nil
	}
	var message wireMessage
	if err := json.Unmarshal(line, &message); err != nil {
		return fmt.Errorf("app-server 输出不是合法 JSON：%w", err)
	}
	switch {
	case message.ID != nil && message.Method == "":
		c.handleResponse(*message.ID, rpcResponse{result: message.Result, err: message.Error})
	case message.ID != nil && message.Method != "":
		c.dispatchServerRequest(ServerRequest{ID: *message.ID, Method: message.Method, Params: message.Params})
	case message.Method != "":
		c.dispatchNotification(Notification{Method: message.Method, Params: message.Params})
	default:
		return fmt.Errorf("app-server 消息缺少 method 或 id")
	}
	return nil
}

func (c *Client) handleResponse(rawID json.RawMessage, response rpcResponse) {
	id := requestIDFromRaw(rawID)
	c.mu.Lock()
	ch, ok := c.pending[id]
	if ok {
		delete(c.pending, id)
	}
	c.mu.Unlock()
	if ok {
		ch <- response
	}
}

func (c *Client) dispatchNotification(notification Notification) {
	// stdout reader 同时承载 response 和 notification。这里绝不能阻塞，
	// 否则一个慢订阅者会把所有 pending request 都卡住。
	c.notifyMu.RLock()
	defer c.notifyMu.RUnlock()
	select {
	case <-c.closed:
		return
	default:
	}
	select {
	case c.notifications <- notification:
	case <-c.closed:
	default:
		atomic.AddUint64(&c.droppedNotifications, 1)
	}
}

func (c *Client) dispatchServerRequest(req ServerRequest) {
	handler := c.options.ServerRequestHandler
	if handler == nil {
		handler = defaultServerRequestHandler
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), c.options.ServerRequestTimeout)
		defer cancel()
		type handlerResult struct {
			result any
			err    *RPCError
		}
		resultCh := make(chan handlerResult, 1)
		go func() {
			result, rpcErr := handler(ctx, req)
			resultCh <- handlerResult{result: result, err: rpcErr}
		}()

		var result any
		var rpcErr *RPCError
		select {
		case out := <-resultCh:
			result, rpcErr = out.result, out.err
		case <-ctx.Done():
			result, rpcErr = failClosedResult(req, "approval timeout")
		case <-c.closed:
			return
		}
		if err := c.writeServerResponse(req.ID, result, rpcErr); err != nil {
			atomic.AddUint64(&c.droppedServerRequests, 1)
		}
	}()
}

func (c *Client) writeServerResponse(id json.RawMessage, result any, rpcErr *RPCError) error {
	response := responseEnvelope{ID: id, Result: result, Error: rpcErr}
	return c.writeJSON(response)
}

func defaultServerRequestHandler(ctx context.Context, req ServerRequest) (any, *RPCError) {
	return failClosedResult(req, "no mobile approval client attached")
}

func FailClosedServerRequestResult(req ServerRequest, reason string) (any, *RPCError) {
	return failClosedResult(req, reason)
}

func failClosedResult(req ServerRequest, reason string) (any, *RPCError) {
	if result, ok := failClosedApprovalResult(req.Method); ok {
		return result, nil
	}
	message := "unsupported server request: " + req.Method
	if trimmed := strings.TrimSpace(reason); trimmed != "" {
		message += ": " + trimmed
	}
	return nil, &RPCError{Code: -32601, Message: message}
}

func failClosedApprovalResult(method string) (map[string]any, bool) {
	lower := strings.ToLower(method)
	switch {
	case strings.Contains(lower, "permissions/requestapproval"):
		// 权限审批没有 decision 字段；空 permissions + turn scope 表示不额外授权。
		return map[string]any{
			"permissions":      map[string]any{},
			"scope":            "turn",
			"strictAutoReview": true,
		}, true
	case strings.Contains(lower, "commandexecution/requestapproval"), strings.Contains(lower, "filechange/requestapproval"):
		return map[string]any{
			"decision": "decline",
		}, true
	case strings.Contains(lower, "execcommandapproval"), strings.Contains(lower, "applypatchapproval"):
		return map[string]any{
			"decision": "denied",
		}, true
	}
	return nil, false
}

func (c *Client) removePending(id requestID) {
	c.mu.Lock()
	delete(c.pending, id)
	c.mu.Unlock()
}

func (c *Client) closeWithError(err error) {
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.readErr = err
		pending := c.pending
		c.pending = map[requestID]chan rpcResponse{}
		c.mu.Unlock()
		for _, ch := range pending {
			ch <- rpcResponse{err: &RPCError{Code: -1, Message: err.Error()}}
		}
		close(c.closed)
		c.notifyMu.Lock()
		close(c.notifications)
		c.notifyMu.Unlock()
	})
}

func (c *Client) closeError() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.readErr != nil {
		return c.readErr
	}
	return fmt.Errorf("app-server client 已关闭")
}
