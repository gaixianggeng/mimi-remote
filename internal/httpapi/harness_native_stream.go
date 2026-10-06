package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

// 本文件是 /api/harness/ws：移动端原生消费 Harness 流的中继。
//
// 它复用 Harness 自己的 remote.mux 结构，而不是另造一层协议：
//
//   - 客户端帧沿用冻结的 open / cancel（`stream/mux-carrier.json`）；
//   - 服务端帧沿用 item / error / end 三类载体帧；
//   - 只在需要回传人机应答时加一个 respond 帧（$events/result 在 H02 里被明确
//     排除在只读中继之外，所以走这条连接，而不是去放宽 /api/harness/rpc）。
//
// 这样 iOS 侧只需要一个解析器，不必为"经由 agentd"再学一套形状。

const (
	// harnessNativeWSMaxStreams 限制单条连接的并发订阅数。每多一条订阅就多一条
	// 到 Harness 的物理连接，没有上限时一个已配对客户端就能把本机连接数打满。
	harnessNativeWSMaxStreams = 8
	// 限制耗时 RPC 等待期间积压的客户端帧；超过上限就关闭连接，不能阻塞读取而漏掉断线。
	harnessNativeWSMaxPendingFrames = 32
	harnessNativeWSWriteWait        = 10 * time.Second
	harnessNativeWSReadLimit        = 1 << 20
	// 读空闲上限：这么久没收到任何帧（含 pong）即判定链路已死。
	harnessNativeWSReadIdle   = 120 * time.Second
	harnessNativeWSPingPeriod = 30 * time.Second
)

// harnessNativeWSEndpoints 是本连接开放的 endpoint。
//
// 白名单而非黑名单：Harness 的 remote.mux 能承载的不止这三条，但中继只放行
// 冻结契约里已证实的三条读订阅。多开一条就等于多一条未经评审的授权面。
var harnessNativeWSEndpoints = map[string]struct{}{
	harnessclient.EndpointEvents:        {},
	harnessclient.MethodSessionFollow:   {},
	harnessNativeEndpointSessionControl: {},
}

// harnessNativeEndpointSessionControl 是控制流 endpoint。
//
// 契约把它列为会话方法，因此 harnessclient 里没有为它单独定义常量。
const harnessNativeEndpointSessionControl = "session/control"

// harnessNativeFrameResponded 是中继的应答回执帧的内层判别值。
//
// 放在 `item` 载体里下发（移动端只解 item/error/end 三种载体帧），字段为
// `{eventId, accepted, responded, error?}`。它是中继的扩展，不是上游 remote.mux
// 的形状——与 respond 请求帧本身同属一层约定。
const harnessNativeFrameResponded = "responded"

// harnessNativeWSClientFrame 是移动端发来的帧。
//
// open / cancel 与上游同形；respond 是中继的扩展，承载 $events/result 的语义。
// 刻意**不接受** clientId：应答要用哪个 clientId 由中继自己持有，让调用方传
// clientId 等于把"当前活连接的关联值"交给外部决定。
type harnessNativeWSClientFrame struct {
	Type     string          `json:"type"`
	StreamID string          `json:"streamId,omitempty"`
	Endpoint string          `json:"endpoint,omitempty"`
	Payload  json.RawMessage `json:"payload,omitempty"`
	EventID  string          `json:"eventId,omitempty"`
	Outcome  json.RawMessage `json:"outcome,omitempty"`
}

// harnessNativeWSStream 是一条逻辑订阅。
type harnessNativeWSStream struct {
	streamID string
	endpoint string
	upstream *harnessclient.Stream
	// sessionID 仅对 session/follow 有意义，用于首帧归属对照。
	sessionID string

	// sessionSlot 表示这条订阅占用了一个全局会话名额（只有 session/follow 会占）。
	// slotReleased 是归还幂等位；两者都由 harnessNativeStreamConn.mu 保护。
	sessionSlot  bool
	slotReleased bool

	closeOnce sync.Once
}

func (stream *harnessNativeWSStream) close() {
	stream.closeOnce.Do(func() {
		if stream.upstream != nil {
			stream.upstream.Close()
		}
	})
}

// releaseSessionSlotLocked 归还一条订阅占用的全局会话名额。幂等；调用方须持有 c.mu。
//
// 三条退役路径（主动退订、上游结束、整条连接关闭）都以"从 c.streams 摘除"为前置条件，
// 所以一条流最多走到这里一次。
func (c *harnessNativeStreamConn) releaseSessionSlotLocked(stream *harnessNativeWSStream) {
	if !stream.sessionSlot || stream.slotReleased {
		return
	}
	stream.slotReleased = true
	c.router.harnessNative.releaseSession()
}

// harnessNativeStreamConn 是一条移动端连接的中继状态。
type harnessNativeStreamConn struct {
	router *Router
	conn   *websocket.Conn

	writeMu sync.Mutex

	mu      sync.Mutex
	streams map[string]*harnessNativeWSStream
	closed  bool

	// generation 是本连接的代次。交互应答必须来自投递时的同一代次。
	generation uint64
	// clientID 是上游 $events 的 clientId。它只留在中继内部，不下发移动端：
	// 它是关联值不是凭据，但它决定应答被谁接受，没有理由让外部看见。
	clientID string
	// eventsStreamID 是当前 $events 订阅的 streamId。
	//
	// 应答确认帧必须带上它：移动端的载体解码器要求帧有非空 streamId，
	// 否则整帧被判为"无法归属"而丢弃（`HarnessCarrierDecoder.decode`）。
	// 不带 streamId 的成功回执等于没有回执。
	eventsStreamID string
	// 每条移动连接只绑定一个 $events 生命周期；事件流退役时关闭整条连接。
	eventsOpened bool

	registry *harnessNativeInteractionRegistry
	wg       sync.WaitGroup
	// closedCh 在 shutdown 时关闭，用于让 relay / ping 协程立刻退出。
	closedCh chan struct{}
	// cancel 结束连接内的授权/应答 RPC，避免 shutdown 等待请求上下文自取消。
	cancel context.CancelFunc
}

// harnessNativeStreamGeneration 为每条新连接分配一个进程内唯一代次。
var harnessNativeStreamGeneration struct {
	mu    sync.Mutex
	value uint64
}

func nextHarnessNativeStreamGeneration() uint64 {
	harnessNativeStreamGeneration.mu.Lock()
	defer harnessNativeStreamGeneration.mu.Unlock()
	harnessNativeStreamGeneration.value++
	return harnessNativeStreamGeneration.value
}

// harnessNativeStreamHandler 处理 GET /api/harness/ws。
func (r *Router) harnessNativeStreamHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !sameOriginOrNoOrigin(req) {
		writeError(w, http.StatusForbidden, "origin 不被允许")
		return
	}
	// 先确认这确实是一次 WebSocket 升级：普通 GET 或畸形握手不能触发本机到
	// Harness 的拨号，否则一个有效 token 就能被用来批量消耗上游连接。
	if !websocket.IsWebSocketUpgrade(req) {
		writeError(w, http.StatusBadRequest, "原生流中继需要 WebSocket Upgrade")
		return
	}
	conn, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		// Upgrade 已经写过 HTTP 响应，这里不再二次写。
		return
	}

	ctx, cancel := context.WithCancel(req.Context())
	session := &harnessNativeStreamConn{
		router:     r,
		conn:       conn,
		streams:    map[string]*harnessNativeWSStream{},
		generation: nextHarnessNativeStreamGeneration(),
		registry:   newHarnessNativeInteractionRegistry(),
		closedCh:   make(chan struct{}),
		cancel:     cancel,
	}
	if !r.harnessNative.register(session) {
		session.stop()
		return
	}
	defer r.harnessNative.release(session)
	session.serve(ctx)
}

// serve 读取客户端帧直到连接结束，结束时一次性释放全部资源。
func (c *harnessNativeStreamConn) serve(ctx context.Context) {
	defer c.shutdown()

	c.conn.SetReadLimit(harnessNativeWSReadLimit)
	_ = c.conn.SetReadDeadline(time.Now().Add(harnessNativeWSReadIdle))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(harnessNativeWSReadIdle))
	})
	frames := make(chan []byte, harnessNativeWSMaxPendingFrames)
	// 帧处理串行执行，读取独立前进，授权/应答 RPC 等待期间也能发现 EOF 并取消请求。
	c.wg.Add(2)
	go c.pingLoop()
	go c.handleFrames(ctx, frames)

	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		// 读到东西就续期，避免把"帧很密但一直没 pong"的健康连接判死。
		_ = c.conn.SetReadDeadline(time.Now().Add(harnessNativeWSReadIdle))
		select {
		case frames <- raw:
		case <-ctx.Done():
			return
		default:
			return
		}
	}
}

// handleFrames 保持 open/cancel/respond 的接收顺序；由 serve 负责关闭并等待本协程。
func (c *harnessNativeStreamConn) handleFrames(ctx context.Context, frames <-chan []byte) {
	defer c.wg.Done()
	for {
		var raw []byte
		select {
		case raw = <-frames:
		case <-ctx.Done():
			return
		}
		// 关闭与已缓冲帧可能同时可读，关闭后不再执行队列里的命令。
		if ctx.Err() != nil {
			return
		}
		var frame harnessNativeWSClientFrame
		if err := harnessNativeDecodeStrict(raw, &frame); err != nil {
			c.writeStreamError("", harnessNativeWSError("gateway/bad-request", "帧不是合法 JSON"))
			continue
		}
		switch strings.TrimSpace(frame.Type) {
		case "open":
			c.handleOpen(ctx, frame)
		case "cancel":
			c.handleCancel(frame)
		case "respond":
			c.handleRespond(ctx, frame)
		default:
			c.writeStreamError(frame.StreamID, harnessNativeWSError("gateway/bad-request", "未知的客户端帧类型"))
		}
	}
}

func (c *harnessNativeStreamConn) pingLoop() {
	defer c.wg.Done()
	ticker := time.NewTicker(harnessNativeWSPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			c.writeMu.Lock()
			_ = c.conn.SetWriteDeadline(time.Now().Add(harnessNativeWSWriteWait))
			err := c.conn.WriteMessage(websocket.PingMessage, nil)
			c.writeMu.Unlock()
			if err != nil {
				// ping 写不出去说明链路已断。必须关连接：只退出本协程的话，
				// 读循环会永远阻塞在 ReadMessage 上，资源也就不会释放。
				_ = c.conn.Close()
				return
			}
		case <-c.done():
			return
		}
	}
}

func (c *harnessNativeStreamConn) done() <-chan struct{} {
	return c.closedCh
}

// stop 可由资源 owner 调用：取消网络请求并唤醒读循环，由 serve 统一释放订阅。
func (c *harnessNativeStreamConn) stop() {
	c.cancel()
	_ = c.conn.Close()
}

// shutdown 一次性释放：关闭所有上游订阅、关闭本连接。
//
// 幂等是硬要求——连接断开、主动退订、上游关闭三条路径都会走到这里，
// 重复释放会让 close(channel) 之类的操作 panic 或重复关闭上游连接。
func (c *harnessNativeStreamConn) shutdown() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	streams := make([]*harnessNativeWSStream, 0, len(c.streams))
	for _, stream := range c.streams {
		streams = append(streams, stream)
	}
	c.streams = map[string]*harnessNativeWSStream{}
	// 整条连接退役也必须归还会话名额：漏了这条，断线重连就会一直撞全局上限。
	for _, stream := range streams {
		c.releaseSessionSlotLocked(stream)
	}
	c.mu.Unlock()

	// 先关信号再等协程：顺序反了会死等还在 select 上的 relay。
	close(c.closedCh)
	c.stop()
	for _, stream := range streams {
		stream.close()
	}
	c.wg.Wait()
}

// handleOpen 处理一次订阅声明。
//
// 顺序是安全边界：先做全部本地校验（streamId、endpoint、资源上限、目标授权），
// 再建上游连接。被拒的订阅因此不会产生任何一次 Harness 访问。
func (c *harnessNativeStreamConn) handleOpen(ctx context.Context, frame harnessNativeWSClientFrame) {
	streamID := strings.TrimSpace(frame.StreamID)
	if streamID == "" {
		c.writeStreamError("", harnessNativeWSError("gateway/bad-request", "open 缺少 streamId"))
		return
	}
	endpoint := strings.TrimSpace(frame.Endpoint)
	if _, allowed := harnessNativeWSEndpoints[endpoint]; !allowed {
		c.writeStreamError(streamID, harnessNativeWSError("gateway/method-unavailable", "该 endpoint 不开放"))
		return
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	if _, exists := c.streams[streamID]; exists {
		c.mu.Unlock()
		c.writeStreamError(streamID, harnessNativeWSError("gateway/bad-request", "streamId 已被占用"))
		return
	}
	if endpoint == harnessclient.EndpointEvents && c.eventsOpened {
		c.mu.Unlock()
		c.writeStreamError(streamID, harnessNativeWSError("gateway/bad-request", "$events 已绑定，请在新连接上重新订阅"))
		return
	}
	if len(c.streams) >= harnessNativeWSMaxStreams {
		c.mu.Unlock()
		// 订阅额度满是**可恢复**的明确错误，不是静默丢弃。
		c.writeStreamError(streamID, harnessNativeWSError("gateway/service-unavailable", "订阅数已达上限，请先退订"))
		return
	}
	// 会话订阅在建立上游连接**之前**先占全局名额：物理连接就是这一步产生的。
	// 与本函数开头的顺序约定一致——被拒的订阅不产生任何一次 Harness 访问。
	sessionSlot := false
	if endpoint == harnessclient.MethodSessionFollow {
		if !c.router.harnessNative.acquireSession(c.router.cfg.DeepSeek.MaxConcurrentSessions) {
			c.mu.Unlock()
			c.writeStreamError(streamID, harnessNativeWSError("gateway/service-unavailable", "同时打开的会话订阅数已达上限，请先退订其它会话"))
			return
		}
		sessionSlot = true
	}
	c.mu.Unlock()

	// 授权失败、建连失败或连接已关闭时，名额必须原路归还；登记成功后改由退役路径负责。
	slotHeld := sessionSlot
	defer func() {
		if slotHeld {
			c.router.harnessNative.releaseSession()
		}
	}()

	args, sessionID, err := c.router.harnessNativeAuthorizeStreamOpen(ctx, endpoint, frame.Payload)
	if err != nil {
		c.writeStreamError(streamID, harnessNativeRemoteErrorFrom(err))
		return
	}

	client, err := c.router.harnessNativeClientFor(ctx)
	if err != nil {
		c.writeStreamError(streamID, harnessNativeRemoteErrorFrom(err))
		return
	}
	upstream, err := client.OpenStream(ctx, endpoint, args)
	if err != nil {
		c.writeStreamError(streamID, harnessNativeWSError("gateway/service-unavailable", "无法建立 Harness 订阅，请在电脑运行 agentd doctor"))
		return
	}

	stream := &harnessNativeWSStream{
		streamID:    streamID,
		endpoint:    endpoint,
		upstream:    upstream,
		sessionID:   sessionID,
		sessionSlot: sessionSlot,
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		stream.close()
		return
	}
	c.streams[streamID] = stream
	// 名额所有权移交给流本身，推迟到这里的 defer 不能再归还。
	slotHeld = false
	if endpoint == harnessclient.EndpointEvents {
		c.eventsOpened = true
		// 应答确认帧要带上它，否则移动端无法归属。
		c.eventsStreamID = streamID
	}
	// wg.Add 必须与登记在同一把锁里完成：否则 shutdown 的 wg.Wait 可能在 Add
	// 之前返回，留下一个不会被等待的 relay 协程。
	c.wg.Add(1)
	c.mu.Unlock()

	go c.relay(ctx, client, stream)
}

// relay 把一条上游订阅的帧搬到移动端，直到订阅结束。
func (c *harnessNativeStreamConn) relay(ctx context.Context, client *harnessclient.Client, stream *harnessNativeWSStream) {
	defer c.wg.Done()
	defer c.finishStream(stream)

	awaitingSnapshot := stream.endpoint == harnessclient.MethodSessionFollow
	for {
		select {
		case frame, ok := <-stream.upstream.Frames():
			if !ok {
				if c.isCurrentStream(stream) {
					// 本地主动退订不走这里。上游物理断流必须让手机感知，
					// 不能留下“WS 保活但逻辑订阅已死”的连接。
					c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/service-unavailable", "Harness 订阅已断开，请重新连接"))
					_ = c.conn.Close()
				}
				return
			}
			if !c.isCurrentStream(stream) {
				return
			}
			if !c.forwardFrame(ctx, client, stream, frame, awaitingSnapshot) {
				return
			}
			if frame.Type == harnessclient.FrameSnapshot {
				awaitingSnapshot = false
			}
		case <-ctx.Done():
			return
		case <-c.done():
			return
		}
	}
}

// forwardFrame 转发一帧，返回 false 表示这条订阅应当结束。
func (c *harnessNativeStreamConn) forwardFrame(
	ctx context.Context,
	client *harnessclient.Client,
	stream *harnessNativeWSStream,
	frame harnessclient.StreamValue,
	awaitingSnapshot bool,
) bool {
	// 载体层错误必须如实上报。契约 §8 缺陷 2 的后果正是这里：丢掉它，一次上游
	// 报错会伪装成一次静默超时，用户与诊断都看不出区别。
	if remoteErr, isFailure := frame.CarrierFailure(); isFailure {
		c.writeStreamError(stream.streamID, remoteErr)
		return false
	}
	if frame.IsCarrierEnd() {
		c.writeEnd(stream.streamID)
		return false
	}

	switch stream.endpoint {
	case harnessclient.EndpointEvents:
		return c.forwardEventsFrame(ctx, client, stream, frame)
	case harnessclient.MethodSessionFollow:
		return c.forwardFollowFrame(stream, frame, awaitingSnapshot)
	default:
		return c.forwardControlFrame(ctx, client, stream, frame)
	}
}

// forwardEventsFrame 处理宿主级事件流。
func (c *harnessNativeStreamConn) forwardEventsFrame(
	ctx context.Context,
	client *harnessclient.Client,
	stream *harnessNativeWSStream,
	frame harnessclient.StreamValue,
) bool {
	switch frame.Type {
	case harnessclient.FrameReady:
		// ready 里的 clientId 与 host.home 都不下发：前者是宿主内部关联值，
		// 后者是无必要元数据（契约 §2.8 明确 host.home 不得下发或写日志）。
		var ready struct {
			ClientID string `json:"clientId"`
		}
		if json.Unmarshal(frame.Raw, &ready) != nil || strings.TrimSpace(ready.ClientID) == "" {
			c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "$events ready 缺少有效关联值"))
			return false
		}
		c.mu.Lock()
		if c.clientID != "" && c.clientID != ready.ClientID {
			c.mu.Unlock()
			c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "$events 代次发生变化，请重新连接"))
			return false
		}
		c.clientID = ready.ClientID
		c.mu.Unlock()
		c.writeItem(stream.streamID, json.RawMessage(`{"type":"ready"}`))
		return true

	case harnessclient.FrameWaterfall:
		c.deliverWaterfall(ctx, client, stream, frame)
		return true

	case harnessclient.FrameCancel:
		// 其它端先应答了：本地终结，并让移动端撤下卡片。
		var cancel struct {
			EventID string `json:"eventId"`
		}
		_ = json.Unmarshal(frame.Raw, &cancel)
		if c.registry.cancelDelivered(cancel.EventID) {
			c.writeItem(stream.streamID, frame.Raw)
		}
		return true

	default:
		// $events 是宿主级通道，未实现授权裁剪的 emit/扩展事件不透传。
		// 目录由只读 list 刷新；不拿泄露其它会话的事件来替代目录发现。
		return true
	}
}

// deliverWaterfall 认领一条交互请求并按归属投递。
//
// 四条前置条件缺一不可，任何一条不成立都**不投递**（宁可不显示，也不泄露）：
//  1. 该 eventId 尚未终结（已终结的不得复活成新卡片）；
//  2. 归属可证明——取不到证据就显式诊断，不猜；
//  3. 归属到的会话确实落在授权范围内（拿可信会话摘要证明，不用调用方自报）；
//  4. 注册表接纳（未超上限）。
func (c *harnessNativeStreamConn) deliverWaterfall(
	ctx context.Context,
	client *harnessclient.Client,
	stream *harnessNativeWSStream,
	frame harnessclient.StreamValue,
) {
	request, err := frame.Waterfall()
	if err != nil {
		return
	}
	eventID := strings.TrimSpace(request.EventID)
	if eventID == "" {
		// 没有 eventId 就无法回传应答，也无法去重；不投递比投一张答不了的卡片好。
		return
	}
	if c.registry.isTerminal(eventID) {
		return
	}

	sessionID, _ := c.registry.attribute(request)
	if sessionID == "" {
		// 本层没有暂存队列；不能注释声称“稍后重试”，实际却静默丢失。
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "交互缺少可验证的会话归属"))
		return
	}
	// 归属只是候选，仍需用可信会话摘要证明它落在授权范围内。
	if err := c.router.harnessNativeAuthorizeSession(ctx, client, sessionID, nil); err != nil {
		return
	}
	if request.Event != harnessclient.WaterfallApprovalRequest &&
		request.Event != harnessclient.WaterfallUserQuestions {
		// 认不出的交互类型不投递：移动端无法为它构造合法应答。
		return
	}

	delivery := c.registry.registerDelivery(harnessNativeInteraction{
		EventID:    eventID,
		SessionID:  sessionID,
		Event:      request.Event,
		Request:    request.Request,
		Generation: c.generation,
	})
	switch delivery {
	case harnessNativeDeliveryNew:
		c.writeItem(stream.streamID, frame.Raw)
	case harnessNativeDeliveryDuplicate, harnessNativeDeliveryTerminal:
		return
	case harnessNativeDeliveryFull:
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/service-unavailable", "待应答交互已达上限"))
	default:
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "交互身份与已投递请求不一致"))
	}
}

// forwardFollowFrame 处理会话跟随流。
//
// 首帧必须是 snapshot，且必须与订阅目标一致：订阅时校验的是"请求的目标"，
// 这里校验的是"上游实际给的"。两者都成立才允许下发——否则一次越权的 follow
// 就能靠上游返回别人的快照把内容读走。契约明确要求"授权未证实前不得下发 snapshot"。
func (c *harnessNativeStreamConn) forwardFollowFrame(
	stream *harnessNativeWSStream,
	frame harnessclient.StreamValue,
	awaitingSnapshot bool,
) bool {
	if !awaitingSnapshot {
		c.writeItem(stream.streamID, frame.Raw)
		return true
	}
	if frame.Type != harnessclient.FrameSnapshot {
		// 首帧不是 snapshot，说明订阅没有按契约打开。不下发任何内容。
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "follow 首帧不是 snapshot"))
		return false
	}
	var snapshot struct {
		Header struct {
			ID  string `json:"id"`
			CWD string `json:"cwd"`
		} `json:"header"`
	}
	if err := json.Unmarshal(frame.Raw, &snapshot); err != nil {
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "snapshot 头部无法解析"))
		return false
	}
	if got := strings.TrimSpace(snapshot.Header.ID); got == "" || got != stream.sessionID {
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "snapshot 归属与订阅目标不一致"))
		return false
	}
	cwd := strings.TrimSpace(snapshot.Header.CWD)
	if _, ok := c.router.gatewayScopeForPath(cwd); cwd == "" || !ok {
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "snapshot 的工作目录不在授权范围内"))
		return false
	}
	c.writeItem(stream.streamID, frame.Raw)
	return true
}

// forwardControlFrame 每帧最多读取一次可信目录；不复用跨帧授权结论。
func (c *harnessNativeStreamConn) forwardControlFrame(
	ctx context.Context,
	client *harnessclient.Client,
	stream *harnessNativeWSStream,
	frame harnessclient.StreamValue,
) bool {
	var allowed map[string]bool
	raw, err := harnessNativeFilterControl(frame.Raw, func(id string) (bool, error) {
		if allowed == nil {
			sessions, err := client.ListSessions(ctx, harnessclient.SessionListRequest{})
			if err != nil {
				return false, err
			}
			allowed = make(map[string]bool, len(sessions))
			for _, session := range sessions {
				_, ok := c.router.gatewayScopeForPath(session.CWD)
				ok = ok && strings.TrimSpace(session.CWD) != ""
				// 同 ID 的任一摘要不属于授权范围，就不能靠另一条重复项放行。
				if previous, exists := allowed[session.SessionID]; exists {
					ok = ok && previous
				}
				allowed[session.SessionID] = ok
			}
		}
		return allowed[id], nil
	})
	if err != nil {
		code := "gateway/service-unavailable"
		if errors.Is(err, errHarnessNativeControlShape) {
			code = "gateway/result-invalid"
		}
		c.writeStreamError(stream.streamID, harnessNativeWSError(code, "控制流无法安全校验，已停止该订阅"))
		return false
	}
	if raw != nil {
		c.writeItem(stream.streamID, raw)
	}
	return true
}

// handleCancel 处理主动退订。
func (c *harnessNativeStreamConn) handleCancel(frame harnessNativeWSClientFrame) {
	streamID := strings.TrimSpace(frame.StreamID)
	if streamID == "" {
		c.writeStreamError("", harnessNativeWSError("gateway/bad-request", "cancel 缺少 streamId"))
		return
	}
	c.mu.Lock()
	stream, ok := c.streams[streamID]
	if ok {
		delete(c.streams, streamID)
		c.releaseSessionSlotLocked(stream)
		if stream.endpoint == harnessclient.EndpointEvents {
			c.clientID = ""
			c.eventsStreamID = ""
		}
	}
	c.mu.Unlock()
	if !ok {
		// 退订一条不存在或已结束的订阅是空操作，不是错误：客户端与中继对
		// "谁先发现流已结束"本来就有竞态。
		return
	}
	// follow 是观察租约，不是交互授权。页面离开不得删除有效 pending。
	stream.close()
	c.writeEnd(streamID)
	if stream.endpoint == harnessclient.EndpointEvents {
		// 不在同一移动连接上复用旧 clientId 或旧 pending。结束帧必须先于关闭
		// 写出：倒过来移动端只会收到 1006，无法区分正常退役与链路故障。
		_ = c.conn.Close()
	}
}

// handleRespond 处理一次人机应答回传。
//
// 每一次结论都必须带 `eventId` 回传移动端。理由不是"礼貌"，而是移动端**无法**从
// 别处推断结果：`send` 返回只说明帧写进了 socket，中继完全可能在这之后拒绝
// （越权、形状非法、无 clientId）。没有可关联的回执时，手机只能把"写出成功"
// 当成"Harness 已接受"，于是上游随后拒绝时卡片已经消失、用户以为已生效。
func (c *harnessNativeStreamConn) handleRespond(ctx context.Context, frame harnessNativeWSClientFrame) {
	eventID := strings.TrimSpace(frame.EventID)
	pending, result, err := c.registry.claim(eventID, c.generation)
	if err != nil {
		// 认领失败分两类：伪造/代次失效（明确未执行）与"从未投递"。
		// 两者都没触达上游，但**不能**一律当成可重试的拒绝——伪造是安全边界，
		// 移动端不该据此重新开放卡片。用 `unknown` 让它保持锁定并如实提示。
		c.writeRespondOutcome(eventID, harnessNativeRespondOutcomeUnknown, harnessNativeRemoteErrorFrom(err))
		return
	}
	if result == harnessNativeClaimSettled {
		// 契约：迟到应答是空操作而非错误。不转发（转发只会拿到上游
		// lookup-not-found），也不谎报成功。
		// 移动端按 `settled` 撤卡——但不能声称本端回答获胜（也许是另一端先答的）。
		c.writeRespondOutcome(
			eventID,
			harnessNativeRespondOutcomeSettled,
			harnessNativeWSError("harness/interaction-settled", "该交互已终结，应答是空操作"),
		)
		return
	}

	outcome, err := harnessNativeValidateOutcome(pending.Event, frame.Outcome)
	if err != nil {
		c.registry.release(eventID)
		// 形状非法 = 这次应答没有被上游看到，可以改条件重试。
		c.writeRespondOutcome(eventID, harnessNativeRespondOutcomeRejected, harnessNativeRemoteErrorFrom(err))
		return
	}

	c.mu.Lock()
	clientID := c.clientID
	c.mu.Unlock()
	if clientID == "" {
		// 还没收到 ready，就没有可用的 clientId。不能猜一个。
		c.registry.release(eventID)
		// 还没发出，明确未执行。
		c.writeRespondOutcome(
			eventID,
			harnessNativeRespondOutcomeRejected,
			harnessNativeWSError("gateway/service-unavailable", "尚未建立事件代次，请稍后重试"),
		)
		return
	}

	client, err := c.router.harnessNativeClientFor(ctx)
	if err != nil {
		c.registry.release(eventID)
		c.writeRespondOutcome(eventID, harnessNativeRespondOutcomeUnknown, harnessNativeRemoteErrorFrom(err))
		return
	}
	if err := c.router.harnessNativeAuthorizeSession(ctx, client, pending.SessionID, nil); err != nil {
		// 拒绝发送；暂时目录故障不应假装成用户拒绝。
		c.registry.release(eventID)
		var policyErr *harnessNativePolicyError
		if errors.As(err, &policyErr) && policyErr.status == http.StatusForbidden {
			c.registry.forgetSession(pending.SessionID)
		}
		// 授权拒绝 = 没转发，明确未执行。
		c.writeRespondOutcome(eventID, harnessNativeRespondOutcomeRejected, harnessNativeRemoteErrorFrom(err))
		return
	}
	if err := client.RespondOutcome(ctx, clientID, eventID, json.RawMessage(mustMarshalRaw(outcome))); err != nil {
		var remoteErr *harnessclient.RemoteError
		if errors.As(err, &remoteErr) {
			// 明确的业务失败：上游看见了这次应答并拒绝了它，没生效。
			// 只有这种才回 `rejected`，让移动端放回重试。
			c.registry.release(eventID)
			c.writeRespondOutcome(eventID, harnessNativeRespondOutcomeRejected, harnessNativeRemoteErrorFrom(err))
			return
		}
		// HTTP 结果未知：**可能已经生效**。回 `unknown` 而不是 `rejected`——
		// 后者会让移动端把它当成可重试的明确拒绝，从而重复执行一次审批。
		// 不解锁成"尚未生效"；重连后由 Harness 重投仍 pending 的请求，
		// 这里绝不自动重发用户决定。
		c.writeRespondOutcome(eventID, harnessNativeRespondOutcomeUnknown, harnessNativeRemoteErrorFrom(err))
		_ = c.conn.Close()
		return
	}
	// 只有上游接受了才终结。服务器收到应答 != Harness 已接受。
	c.registry.settle(eventID)
	// 明确接受才回执。移动端收到它才撤卡；在此之前卡片停在"提交中"。
	c.writeRespondOutcome(eventID, harnessNativeRespondOutcomeAccepted, nil)
}

// 应答回执的结论判别值。
//
// 一个布尔值不够用：**结果未知**与**明确拒绝**在移动端要求的后续动作完全相反
// ——前者必须保持锁定等对账，后者要放回让用户重试。把两者混成 `accepted:false`
// 会让"上游其实已经接受了、只是 HTTP 响应丢了"被当成"可以重试"，从而可能重复
// 执行一次审批。
const (
	// 上游明确接受。移动端据此撤卡。
	harnessNativeRespondOutcomeAccepted = "accepted"
	// 上游明确拒绝且**未执行**。移动端保留原因并放回重试。
	harnessNativeRespondOutcomeRejected = "rejected"
	// 该交互已由其它路径终结。移动端撤卡，但不声称本端回答获胜。
	harnessNativeRespondOutcomeSettled = "settled"
	// 结果未知，可能已生效。移动端不自动重发、不当明确拒绝，进入对账或重投恢复。
	harnessNativeRespondOutcomeUnknown = "unknown"
)

// writeRespondOutcome 回传一次应答的真实结论。
//
// 每种结论都要带 `eventId`：没有它，移动端只知道"有事发生"，无法判断是哪张卡，
// 于是既不能撤卡也不能放回重试。
func (c *harnessNativeStreamConn) writeRespondOutcome(
	eventID string,
	outcome string,
	remoteErr *harnessclient.RemoteError,
) {
	c.mu.Lock()
	streamID := c.eventsStreamID
	c.mu.Unlock()
	if streamID == "" || eventID == "" {
		// 没有 `$events` 订阅就没有可归属的通道。失败时至少把原因如实发出去，
		// 不静默吞掉；成功时无卡可撤，不回执也不影响正确性。
		if remoteErr != nil {
			c.writeStreamError("", remoteErr)
		}
		return
	}
	payload := map[string]any{
		"eventId":   eventID,
		"outcome":   outcome,
		"responded": true,
	}
	if remoteErr != nil {
		payload["error"] = remoteErr
	}
	c.writeRespondFrame(streamID, payload)
}

// writeRespondFrame 写一帧应答回执。
//
// 走 `item` 载体而不是新的顶层 type：移动端只解 item/error/end 三种载体帧，
// 复用 item 让回执与其它流帧共用同一条解码路径，不必为它新增一套判别。
func (c *harnessNativeStreamConn) writeRespondFrame(streamID string, payload map[string]any) {
	payload["type"] = harnessNativeFrameResponded
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	c.writeItem(streamID, raw)
}

// finishStream 在一条订阅结束时把它从表里摘掉并释放上游。
//
// 关闭移动端连接这件事只能由"摘除者"做一次。本地退订已经在 handleCancel 里
// 摘掉了条目，它紧接着要写一帧 CarrierEnd 再关连接；如果这里也照关一次，两次
// Close 就会和那次 writeEnd 抢同一连接（writeMu 只护写、不护关），移动端会
// 只看到 1006 异常关闭而拿不到结束帧，看不出这是一次正常退役。
func (c *harnessNativeStreamConn) finishStream(stream *harnessNativeWSStream) {
	c.mu.Lock()
	retired := false
	if current, ok := c.streams[stream.streamID]; ok && current == stream {
		delete(c.streams, stream.streamID)
		c.releaseSessionSlotLocked(stream)
		retired = true
		if stream.endpoint == harnessclient.EndpointEvents {
			c.clientID = ""
			c.eventsStreamID = ""
		}
	}
	c.mu.Unlock()
	stream.close()
	if retired && stream.endpoint == harnessclient.EndpointEvents {
		_ = c.conn.Close()
	}
}

func (c *harnessNativeStreamConn) isCurrentStream(stream *harnessNativeWSStream) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.closed && c.streams[stream.streamID] == stream
}

// --- 帧写出 ---

func (c *harnessNativeStreamConn) writeItem(streamID string, value json.RawMessage) {
	c.writeCarrier(map[string]any{
		"type":     harnessclient.CarrierItem,
		"streamId": streamID,
		"value":    value,
	})
}

func (c *harnessNativeStreamConn) writeStreamError(streamID string, remoteErr *harnessclient.RemoteError) {
	payload := map[string]any{
		"type":  harnessclient.CarrierError,
		"error": remoteErr,
	}
	if streamID != "" {
		payload["streamId"] = streamID
	}
	c.writeCarrier(payload)
}

func (c *harnessNativeStreamConn) writeEnd(streamID string) {
	c.writeCarrier(map[string]any{
		"type":     harnessclient.CarrierEnd,
		"streamId": streamID,
	})
}

// writeCarrier 写出一帧载体帧。写失败说明链路已断，关连接即可，不重试。
func (c *harnessNativeStreamConn) writeCarrier(payload map[string]any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(harnessNativeWSWriteWait))
	if err := c.conn.WriteMessage(websocket.TextMessage, raw); err != nil {
		_ = c.conn.Close()
	}
}

// harnessNativeWSError 构造一个载体层错误对象。
func harnessNativeWSError(code, message string) *harnessclient.RemoteError {
	return &harnessclient.RemoteError{Code: code, Message: message}
}

// harnessNativeRemoteErrorFrom 把内部错误转成可下发的错误对象。
//
// 本地策略拒绝（harnessNativePolicyError）带的是可操作文案；其它错误一律收敛成
// 通用文案，避免把上游细节或本机路径透给移动端。
func harnessNativeRemoteErrorFrom(err error) *harnessclient.RemoteError {
	var policyErr *harnessNativePolicyError
	if errors.As(err, &policyErr) {
		return harnessNativeWSError("harness/rejected", policyErr.message)
	}
	var remoteErr *harnessclient.RemoteError
	if errors.As(err, &remoteErr) {
		return remoteErr
	}
	return harnessNativeWSError("gateway/service-unavailable", "无法连接 Harness 服务，请在电脑运行 agentd doctor")
}

// harnessNativeAuthorizeStreamOpen 校验一次订阅声明，并给出要透传给上游的 args。
//
// 返回的 args 是**逐字**透传的形参对象（follow 用 request，$events 用空对象），
// 中继不在这里改写它——改写就会偏离冻结的 wire 形状。
func (r *Router) harnessNativeAuthorizeStreamOpen(
	ctx context.Context,
	endpoint string,
	payload json.RawMessage,
) (any, string, error) {
	client, err := r.harnessNativeClientFor(ctx)
	if err != nil {
		return nil, "", err
	}

	switch endpoint {
	case harnessclient.EndpointEvents, harnessNativeEndpointSessionControl:
		// 零参数订阅：上游按描述符逐字校验，多一个键就 arguments-invalid。
		// 调用方带了参数一律拒绝，而不是替他丢掉。
		args, err := harnessNativeStreamArgs(payload)
		if err != nil {
			return nil, "", harnessNativeReject(http.StatusBadRequest, "订阅参数不是合法对象")
		}
		if len(args) != 0 {
			return nil, "", harnessNativeReject(http.StatusBadRequest, "该订阅不接受参数")
		}
		return map[string]any{}, "", nil

	case harnessclient.MethodSessionFollow:
		// 形参名逐字冻结：follow 的 wire 键是 `request`，它包着 address 等字段
		// （见 `stream/mux-carrier.json` 的 client.open：args.request.address）。
		// 把 address 当成顶层键解会一律失败——那样每个 follow 都会被拒，
		// 而"全都被拒"看起来像安全策略生效，实际是形状写错。
		var envelope struct {
			Request struct {
				Address struct {
					Kind      string `json:"kind"`
					SessionID string `json:"sessionId"`
				} `json:"address"`
				AssistantStream *bool `json:"assistantStream,omitempty"`
				MaxMessages     *int  `json:"maxMessages,omitempty"`
			} `json:"request"`
		}
		if err := harnessNativeDecodeStrict(harnessNativeStreamArgsRaw(payload), &envelope); err != nil {
			return nil, "", harnessNativeReject(http.StatusBadRequest, "follow 参数不是合法对象")
		}
		request := envelope.Request
		sessionID := strings.TrimSpace(request.Address.SessionID)
		if sessionID == "" {
			return nil, "", harnessNativeReject(http.StatusBadRequest, "follow 缺少 address.sessionId")
		}
		if kind := strings.TrimSpace(request.Address.Kind); kind != "session" {
			// 首版只开放 session 形态；subagent 的可见性不自动继承父会话。
			return nil, "", harnessNativeReject(http.StatusBadRequest, "首版只支持 kind=session 的订阅目标")
		}
		if err := r.harnessNativeAuthorizeSession(ctx, client, sessionID, nil); err != nil {
			return nil, "", err
		}
		forward := map[string]any{
			"address": map[string]any{"kind": "session", "sessionId": sessionID},
		}
		if request.AssistantStream != nil {
			forward["assistantStream"] = *request.AssistantStream
		}
		if request.MaxMessages != nil {
			forward["maxMessages"] = *request.MaxMessages
		}
		return map[string]any{"request": forward}, sessionID, nil
	}
	return nil, "", harnessNativeReject(http.StatusBadRequest, "该 endpoint 不开放")
}

// harnessNativeStreamArgsRaw 取出订阅帧 payload 里的 args 原始对象。
//
// 缺失时返回空对象——零参数订阅正是靠它通过"不接受参数"的检查。
func harnessNativeStreamArgsRaw(payload json.RawMessage) json.RawMessage {
	if len(payload) == 0 {
		return json.RawMessage(`{}`)
	}
	var envelope struct {
		Args json.RawMessage `json:"args"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil || len(envelope.Args) == 0 {
		return json.RawMessage(`{}`)
	}
	return envelope.Args
}

// harnessNativeStreamArgs 把 args 解成键值对，供"是否带了参数"的判断使用。
//
// 必须按键判断，不能按字节长度：空对象 `{}` 也有两个字节，用它判空会把所有
// 零参数订阅都误拒。
func harnessNativeStreamArgs(payload json.RawMessage) (map[string]json.RawMessage, error) {
	raw := harnessNativeStreamArgsRaw(payload)
	var args map[string]json.RawMessage
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, err
	}
	return args, nil
}

// mustMarshalRaw 把已解析的 outcome 重新编码。
//
// 重新编码是刻意的：原始 RawMessage 未经校验就转发，会把未知字段一并带给上游，
// 而上游用 exactKeys 校验，多一个键就整条被拒。
func mustMarshalRaw(outcome harnessNativeOutcome) []byte {
	raw, err := json.Marshal(outcome)
	if err != nil {
		return []byte(`{}`)
	}
	return raw
}
