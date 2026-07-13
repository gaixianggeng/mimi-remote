package appserver

import (
	"encoding/json"
	"fmt"
	"strconv"
)

type requestID string

func newRequestID(value int64) requestID {
	return requestID(strconv.FormatInt(value, 10))
}

// wireMessage 是 app-server JSON-RPC-like 协议的最小公共外壳。
// 官方协议在线路上省略 jsonrpc 字段，所以这里只按 id/method/result/error 分流。
type wireMessage struct {
	ID     *json.RawMessage `json:"id,omitempty"`
	Method string           `json:"method,omitempty"`
	Params json.RawMessage  `json:"params,omitempty"`
	Result json.RawMessage  `json:"result,omitempty"`
	Error  *RPCError        `json:"error,omitempty"`
}

type RPCError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *RPCError) Error() string {
	if e == nil {
		return ""
	}
	if e.Code == 0 {
		return e.Message
	}
	return fmt.Sprintf("%s (code=%d)", e.Message, e.Code)
}

type Notification struct {
	Method string
	Params json.RawMessage
}

type ServerRequest struct {
	ID     json.RawMessage
	Method string
	Params json.RawMessage
}

type Diagnostics struct {
	Running               bool     `json:"running"`
	Initialized           bool     `json:"initialized"`
	PendingRequests       int      `json:"pending_requests"`
	DroppedNotifications  uint64   `json:"dropped_notifications"`
	DroppedServerRequests uint64   `json:"dropped_server_requests"`
	StderrTail            []string `json:"stderr_tail"`
}

type InitializeResult struct {
	UserAgent      string `json:"userAgent,omitempty"`
	CodexHome      string `json:"codexHome,omitempty"`
	PlatformFamily string `json:"platformFamily,omitempty"`
	PlatformOS     string `json:"platformOs,omitempty"`
}

type ClientInfo struct {
	Name    string `json:"name"`
	Title   string `json:"title,omitempty"`
	Version string `json:"version,omitempty"`
}

type initializeParams struct {
	ClientInfo   ClientInfo     `json:"clientInfo"`
	Capabilities map[string]any `json:"capabilities,omitempty"`
}

type responseEnvelope struct {
	ID     json.RawMessage `json:"id"`
	Result any             `json:"result,omitempty"`
	Error  *RPCError       `json:"error,omitempty"`
}

func encodeParams(params any) (json.RawMessage, error) {
	if params == nil {
		return json.RawMessage(`{}`), nil
	}
	if raw, ok := params.(json.RawMessage); ok {
		if len(raw) == 0 {
			return json.RawMessage(`{}`), nil
		}
		return raw, nil
	}
	data, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	return data, nil
}

func requestIDFromRaw(raw json.RawMessage) requestID {
	if len(raw) == 0 {
		return ""
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return requestID(text)
	}
	var number int64
	if err := json.Unmarshal(raw, &number); err == nil {
		return requestID(strconv.FormatInt(number, 10))
	}
	return requestID(string(raw))
}
