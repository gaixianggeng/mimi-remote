package harnessclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// 事件流保活与读上限。ping 周期要明显小于任何中间设备的空闲超时，
// 读上限覆盖一次快照回放，避免大历史被截断。
const (
	eventsPingPeriod = 30 * time.Second
	eventsWriteWait  = 10 * time.Second
	eventsPongWait   = 90 * time.Second
	eventsReadLimit  = 32 << 20
)

// Stream 是一条 remote.mux 订阅。一个 Stream 对应一个 endpoint，例如 $events 或
// session/follow。帧按到达顺序进入 Frames，上层用 Until 等待条件成立。
type Stream struct {
	streamID string
	endpoint string
	frames   chan StreamValue

	conn      *websocket.Conn
	closeOnce sync.Once
	closed    chan struct{}
}

// StreamID 是这个订阅的编号，同一条连接上唯一。
func (s *Stream) StreamID() string { return s.streamID }

// Endpoint 是这个订阅的 endpoint。
func (s *Stream) Endpoint() string { return s.endpoint }

// Frames 返回只读帧通道。连接关闭时通道关闭。
func (s *Stream) Frames() <-chan StreamValue { return s.frames }

// Close 关闭这条订阅。重复调用安全。
func (s *Stream) Close() {
	s.closeOnce.Do(func() {
		close(s.closed)
		if s.conn != nil {
			_ = s.conn.Close()
		}
	})
}

// Done 在订阅关闭时关闭，便于 select 等待。
func (s *Stream) Done() <-chan struct{} { return s.closed }

// Until 等待第一个满足条件的帧。超时或连接结束都会返回错误，且错误里带上
// endpoint 与用途标签，便于定位是哪一步没等到。
func (s *Stream) Until(ctx context.Context, label string, timeout time.Duration, match func(StreamValue) bool) (StreamValue, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case frame, ok := <-s.frames:
			if !ok {
				return StreamValue{}, fmt.Errorf("harnessclient: 等待 %s 时订阅已结束（endpoint=%s）", label, s.endpoint)
			}
			if match(frame) {
				return frame, nil
			}
		case <-timer.C:
			return StreamValue{}, fmt.Errorf("harnessclient: 等待 %s 超时（endpoint=%s）", label, s.endpoint)
		case <-ctx.Done():
			return StreamValue{}, ctx.Err()
		}
	}
}

// Ready 等待 ready 帧并返回本次连接的 clientId。clientId 只用于回传应答，
// 属于宿主内部事实，不下发移动端。
func (s *Stream) Ready(ctx context.Context, timeout time.Duration) (string, error) {
	frame, err := s.Until(ctx, "ready", timeout, func(value StreamValue) bool {
		return value.Type == FrameReady
	})
	if err != nil {
		return "", err
	}
	var ready readyFrame
	if err := json.Unmarshal(frame.Raw, &ready); err != nil {
		return "", fmt.Errorf("harnessclient: 解析 ready 帧失败：%w", err)
	}
	if ready.ClientID == "" {
		return "", errors.New("harnessclient: ready 帧缺少 clientId")
	}
	return ready.ClientID, nil
}

// Waterfall 把 waterfall 帧解码成结构化交互请求。
func (frame StreamValue) Waterfall() (WaterfallRequest, error) {
	var decoded WaterfallRequest
	if err := json.Unmarshal(frame.Raw, &decoded); err != nil {
		return WaterfallRequest{}, fmt.Errorf("harnessclient: 解析 waterfall 帧失败：%w", err)
	}
	return decoded, nil
}

// Decode 把帧的 value 解码到 out。
func (frame StreamValue) Decode(out any) error {
	if len(frame.Raw) == 0 {
		return errors.New("harnessclient: 帧没有 value")
	}
	return json.Unmarshal(frame.Raw, out)
}

// OpenStream 在已有连接上声明一条新订阅。
//
// 返回的 Stream 必须在用完后 Close，否则连接上的读协程会一直等这条流的帧。
func (c *Client) OpenStream(ctx context.Context, endpoint string, args any) (*Stream, error) {
	if err := ValidateMethod(endpoint); err != nil {
		return nil, err
	}
	c.mu.RLock()
	cookie := c.cookie
	c.mu.RUnlock()
	if cookie == "" {
		return nil, ErrNotAuthenticated
	}

	dialer := c.config.Dialer
	if dialer == nil {
		dialer = websocket.DefaultDialer
	}
	target, err := websocketURL(c.config.BaseURL, gatewayPath)
	if err != nil {
		return nil, err
	}
	header := http.Header{}
	header.Set("Cookie", cookie)
	conn, response, err := dialer.DialContext(ctx, target, header)
	if err != nil {
		if response != nil {
			_ = response.Body.Close()
			return nil, fmt.Errorf("harnessclient: 连接事件流失败，status=%d：%w", response.StatusCode, err)
		}
		return nil, fmt.Errorf("harnessclient: 连接事件流失败：%w", err)
	}
	conn.SetReadLimit(eventsReadLimit)

	stream := &Stream{
		streamID: newStreamID(endpoint),
		endpoint: endpoint,
		frames:   make(chan StreamValue, 256),
		conn:     conn,
		closed:   make(chan struct{}),
	}

	frame := openFrame{Type: "open", StreamID: stream.streamID, Endpoint: endpoint}
	frame.Payload.Args = args
	if err := writeJSON(conn, frame); err != nil {
		stream.Close()
		return nil, fmt.Errorf("harnessclient: 声明订阅失败：%w", err)
	}

	go stream.readLoop()
	go stream.pingLoop()
	return stream, nil
}

func (s *Stream) readLoop() {
	defer close(s.frames)
	for {
		_, raw, err := s.conn.ReadMessage()
		if err != nil {
			return
		}
		var frame muxFrame
		if err := json.Unmarshal(raw, &frame); err != nil {
			// 单帧无法解析不终止订阅：Harness 的帧类型会演进，丢掉不认识的帧
			// 比整条订阅失效更安全。上层需要的能力都靠 Until 主动等待。
			continue
		}
		var discriminator valueType
		_ = json.Unmarshal(frame.Value, &discriminator)
		value := StreamValue{
			Type: discriminator.Type,
			Raw:  frame.Value,
		}
		if discriminator.Event != nil {
			value.EventType = discriminator.Event.Type
			if value.Type == "" {
				value.Type = FrameDurableEvent
			}
		}
		select {
		case s.frames <- value:
		case <-s.closed:
			return
		}
	}
}

func (s *Stream) pingLoop() {
	ticker := time.NewTicker(eventsPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			_ = s.conn.SetWriteDeadline(time.Now().Add(eventsWriteWait))
			if err := s.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		case <-s.closed:
			return
		}
	}
}

// Respond 回传一次交互应答。
//
// Harness 的 outcome 只有 result 一种成功形态：审批结论本身作为 value 传回
// （allowed-once / rejected / cancelled / unavailable），追问则以 {answers:[...]} 作为
// value。隔离实验里拒绝审批用的就是 {kind:'result', value:'rejected'}，
// 因此这里不发明 rejection 之类的其它 kind。
//
// eventId 必须来自触发它的 waterfall 帧。首个有效应答生效，其它端会收到 cancel；
// 迟到应答是空操作而非错误，所以这里不把竞态当成失败。
func (c *Client) Respond(ctx context.Context, clientID, eventID string, value any) error {
	args := map[string]any{
		"clientId": clientID,
		"eventId":  eventID,
		"outcome":  map[string]any{"kind": "result", "value": value},
	}
	return c.Call(ctx, EndpointEventsResult, args, nil)
}

// AnswerQuestions 回传结构化追问答案。answers 必须逐条对应提问的 id。
func (c *Client) AnswerQuestions(ctx context.Context, clientID, eventID string, answers []Answer) error {
	return c.Respond(ctx, clientID, eventID, map[string]any{"answers": answers})
}

// ResolveApproval 回传审批结论。decision 取 Outcome* 常量。
func (c *Client) ResolveApproval(ctx context.Context, clientID, eventID, decision string) error {
	switch decision {
	case OutcomeAllowedOnce, OutcomeRejected, OutcomeCancelled, OutcomeUnavailable:
	default:
		return fmt.Errorf("harnessclient: 未知审批结论 %q", decision)
	}
	return c.Respond(ctx, clientID, eventID, decision)
}

func writeJSON(conn *websocket.Conn, value any) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err := conn.SetWriteDeadline(time.Now().Add(eventsWriteWait)); err != nil {
		return err
	}
	return conn.WriteMessage(websocket.TextMessage, payload)
}

// gatewayPath 是 remote.mux 的路径。
const gatewayPath = "/api/remote.mux"

// GatewayPath 返回事件流路径，供上层在日志里引用而不必重复字面量。
func GatewayPath() string { return gatewayPath }

// websocketURL 把 HTTP origin 换成对应的 WebSocket 地址。http→ws、https→wss，
// 与 Harness 自己的客户端一致。
func websocketURL(baseURL, path string) (string, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return "", fmt.Errorf("harnessclient: 解析 base_url 失败：%w", err)
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "ws":
		parsed.Scheme = "ws"
	case "https", "wss":
		parsed.Scheme = "wss"
	default:
		return "", fmt.Errorf("harnessclient: 不支持的事件流协议 %q", parsed.Scheme)
	}
	parsed.Path = path
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}

var streamSequence atomic.Uint64

// newStreamID 生成连接内唯一的订阅编号。用 endpoint 前缀便于在日志里分辨，
// 但日志本身不应打印 streamId 之外的会话标识。
func newStreamID(endpoint string) string {
	sanitized := strings.NewReplacer("/", "-", "$", "").Replace(endpoint)
	return fmt.Sprintf("%s-%d", sanitized, streamSequence.Add(1))
}

// SessionPath 返回某个会话的地址描述，供 follow 订阅使用。
func SessionPath(sessionID string) SessionAddress {
	return SessionAddress{Kind: "session", SessionID: sessionID}
}

// API 路径前缀。
const apiPrefix = "/api"

// joinAPI 拼接 API 路径。
//
// 这里刻意不做 URL 转义：Harness 按字面路径路由（隔离实验里就是
// POST /api/session/modelCatalog 与 POST /api/$events/result）。把方法名里的 "/"
// 转义成 %2F 会被服务端当成另一个路径而落到 404，所以改为在 ValidateMethod 里
// 直接拒绝不安全的字符。
func joinAPI(base, method string) string {
	return strings.TrimRight(base, "/") + apiPrefix + "/" + method
}

// ValidateMethod 校验方法名。只接受固定 allowlist 里出现过的字符集合，
// 既避免拼接出意外路径，也不做有损转义。
func ValidateMethod(method string) error {
	if method == "" {
		return errors.New("harnessclient: method 不能为空")
	}
	if strings.TrimSpace(method) != method {
		return fmt.Errorf("harnessclient: method 不能有首尾空白：%q", method)
	}
	for _, char := range method {
		switch {
		case char >= 'a' && char <= 'z', char >= 'A' && char <= 'Z', char >= '0' && char <= '9':
		case char == '/', char == '.', char == '_', char == '-', char == '$':
		default:
			return fmt.Errorf("harnessclient: method 含不允许的字符 %q：%q", char, method)
		}
	}
	// 点号本身合法（方法名里没有用到，但保留给未来的版本号后缀），但路径段
	// 不能是 "." 或 ".."，也不能出现空段，否则可以拼出越界路径。
	if strings.HasPrefix(method, "/") || strings.HasSuffix(method, "/") {
		return fmt.Errorf("harnessclient: method 不能以斜杠开头或结尾：%q", method)
	}
	for _, segment := range strings.Split(method, "/") {
		switch segment {
		case "", ".", "..":
			return fmt.Errorf("harnessclient: method 含非法路径段 %q：%q", segment, method)
		}
	}
	return nil
}
