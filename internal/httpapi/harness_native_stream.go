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
	harnessNativeWSWriteWait  = 10 * time.Second
	harnessNativeWSReadLimit  = 1 << 20
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

	closeOnce sync.Once
}

func (stream *harnessNativeWSStream) close() {
	stream.closeOnce.Do(func() {
		if stream.upstream != nil {
			stream.upstream.Close()
		}
	})
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

	registry *harnessNativeInteractionRegistry
	wg       sync.WaitGroup
	// closedCh 在 shutdown 时关闭，用于让 relay / ping 协程立刻退出。
	closedCh chan struct{}
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

	session := &harnessNativeStreamConn{
		router:     r,
		conn:       conn,
		streams:    map[string]*harnessNativeWSStream{},
		generation: nextHarnessNativeStreamGeneration(),
		registry:   newHarnessNativeInteractionRegistry(),
		closedCh:   make(chan struct{}),
	}
	session.serve(req.Context())
}

// serve 读取客户端帧直到连接结束，结束时一次性释放全部资源。
func (c *harnessNativeStreamConn) serve(ctx context.Context) {
	defer c.shutdown()

	c.conn.SetReadLimit(harnessNativeWSReadLimit)
	_ = c.conn.SetReadDeadline(time.Now().Add(harnessNativeWSReadIdle))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(harnessNativeWSReadIdle))
	})
	go c.pingLoop()

	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		// 读到东西就续期，避免把"帧很密但一直没 pong"的健康连接判死。
		_ = c.conn.SetReadDeadline(time.Now().Add(harnessNativeWSReadIdle))

		var frame harnessNativeWSClientFrame
		if err := json.Unmarshal(raw, &frame); err != nil {
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
	c.mu.Unlock()

	// 先关信号再等协程：顺序反了会死等还在 select 上的 relay。
	close(c.closedCh)
	for _, stream := range streams {
		stream.close()
	}
	_ = c.conn.Close()
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
	if len(c.streams) >= harnessNativeWSMaxStreams {
		c.mu.Unlock()
		// 订阅额度满是**可恢复**的明确错误，不是静默丢弃。
		c.writeStreamError(streamID, harnessNativeWSError("gateway/service-unavailable", "订阅数已达上限，请先退订"))
		return
	}
	c.mu.Unlock()

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
		streamID:  streamID,
		endpoint:  endpoint,
		upstream:  upstream,
		sessionID: sessionID,
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		stream.close()
		return
	}
	c.streams[streamID] = stream
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
				return
			}
			if !c.forwardFrame(ctx, client, stream, frame, awaitingSnapshot) {
				return
			}
			awaitingSnapshot = false
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
		return true
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
		_ = json.Unmarshal(frame.Raw, &ready)
		if clientID := strings.TrimSpace(ready.ClientID); clientID != "" {
			c.mu.Lock()
			c.clientID = clientID
			c.mu.Unlock()
		}
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
		if eventID := strings.TrimSpace(cancel.EventID); eventID != "" {
			c.registry.settle(eventID)
		}
		c.writeItem(stream.streamID, frame.Raw)
		return true

	default:
		c.writeItem(stream.streamID, frame.Raw)
		return true
	}
}

// deliverWaterfall 认领一条交互请求并按归属投递。
//
// 四条前置条件缺一不可，任何一条不成立都**不投递**（宁可不显示，也不泄露）：
//  1. 该 eventId 尚未终结（已终结的不得复活成新卡片）；
//  2. 归属可证明——取不到证据就暂存等待，不猜；
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
		// 归属不可证明。暂存等待（后续帧可能带来 callId 映射），当前不下发。
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

	accepted := c.registry.deliver(harnessNativeInteraction{
		EventID:    eventID,
		SessionID:  sessionID,
		Event:      request.Event,
		Request:    request.Request,
		Generation: c.generation,
	})
	if !accepted {
		if c.registry.isTerminal(eventID) {
			return
		}
		// 溢出必须可观测失败：用户看不到卡片就会以为没有需要他决定的事。
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/service-unavailable", "待应答交互已达上限"))
		return
	}
	c.writeItem(stream.streamID, frame.Raw)
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
	if got := strings.TrimSpace(snapshot.Header.ID); got != "" && got != stream.sessionID {
		c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "snapshot 归属与订阅目标不一致"))
		return false
	}
	if cwd := strings.TrimSpace(snapshot.Header.CWD); cwd != "" {
		if _, ok := c.router.gatewayScopeForPath(cwd); !ok {
			c.writeStreamError(stream.streamID, harnessNativeWSError("gateway/result-invalid", "snapshot 的工作目录不在授权范围内"))
			return false
		}
	}
	c.writeItem(stream.streamID, frame.Raw)
	return true
}

// forwardControlFrame 处理控制流。
//
// 控制帧的会话、投影、jobs 条目都要按授权范围裁剪。这里对能直接看到 sessionId 的
// 帧逐帧重新授权（不缓存，撤权因此天然生效）；**baseline 帧内嵌的 jobs/projections
// 条目尚未做逐条裁剪**——那需要按版本形状解析，属本任务未完成部分，已在交接中
// 列为待办，不假装已覆盖。
func (c *harnessNativeStreamConn) forwardControlFrame(
	ctx context.Context,
	client *harnessclient.Client,
	stream *harnessNativeWSStream,
	frame harnessclient.StreamValue,
) bool {
	var probe struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(frame.Raw, &probe)
	if sessionID := strings.TrimSpace(probe.SessionID); sessionID != "" {
		if err := c.router.harnessNativeAuthorizeSession(ctx, client, sessionID, nil); err != nil {
			// 不属于授权范围的会话，整帧丢弃。
			return true
		}
	}
	c.writeItem(stream.streamID, frame.Raw)
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
	}
	c.mu.Unlock()
	if !ok {
		// 退订一条不存在或已结束的订阅是空操作，不是错误：客户端与中继对
		// "谁先发现流已结束"本来就有竞态。
		return
	}
	// 退订该会话时一并丢弃它的待应答卡片：用户已经离开这个上下文，
	// 再让它留在待应答表里会允许一个已经离开的视图做出决定。
	c.registry.forgetSession(stream.sessionID)
	stream.close()
	c.writeEnd(streamID)
}

// handleRespond 处理一次人机应答回传。
func (c *harnessNativeStreamConn) handleRespond(ctx context.Context, frame harnessNativeWSClientFrame) {
	eventID := strings.TrimSpace(frame.EventID)
	pending, result, err := c.registry.claim(eventID, c.generation)
	if err != nil {
		c.writeStreamError("", harnessNativeRemoteErrorFrom(err))
		return
	}
	if result == harnessNativeClaimSettled {
		// 契约：迟到应答是空操作而非错误。不转发（转发只会拿到上游
		// lookup-not-found），也不谎报成功。
		c.writeStreamError("", harnessNativeWSError("harness/interaction-settled", "该交互已终结，应答是空操作"))
		return
	}

	outcome, err := harnessNativeValidateOutcome(pending.Event, frame.Outcome)
	if err != nil {
		c.registry.release(eventID)
		c.writeStreamError("", harnessNativeRemoteErrorFrom(err))
		return
	}

	c.mu.Lock()
	clientID := c.clientID
	c.mu.Unlock()
	if clientID == "" {
		// 还没收到 ready，就没有可用的 clientId。不能猜一个。
		c.registry.release(eventID)
		c.writeStreamError("", harnessNativeWSError("gateway/service-unavailable", "尚未建立事件代次，请稍后重试"))
		return
	}

	client, err := c.router.harnessNativeClientFor(ctx)
	if err != nil {
		c.registry.release(eventID)
		c.writeStreamError("", harnessNativeRemoteErrorFrom(err))
		return
	}
	if err := client.RespondOutcome(ctx, clientID, eventID, json.RawMessage(mustMarshalRaw(outcome))); err != nil {
		// 结果未知：解锁卡片让用户能重试，但**不自动重发**（契约要求）。
		c.registry.release(eventID)
		c.writeStreamError("", harnessNativeRemoteErrorFrom(err))
		return
	}
	// 只有上游接受了才终结。服务器收到应答 != Harness 已接受。
	c.registry.settle(eventID)
}

// finishStream 在一条订阅结束时把它从表里摘掉并释放上游。
func (c *harnessNativeStreamConn) finishStream(stream *harnessNativeWSStream) {
	c.mu.Lock()
	if current, ok := c.streams[stream.streamID]; ok && current == stream {
		delete(c.streams, stream.streamID)
	}
	c.mu.Unlock()
	c.registry.forgetSession(stream.sessionID)
	stream.close()
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
