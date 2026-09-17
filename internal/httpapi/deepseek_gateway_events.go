package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件把 Harness 的两条事件流接到移动端：$events 只承载交互 waterfall，会话订阅
// 承载 turn 生命周期、消息与直播正文。翻译规则在 deepseek_translate.go，这里负责
// 读帧、维护上下文、并把结果写出去。

// readEvents 读 $events 订阅。ready 已在订阅阶段消费，这里只处理交互与作废。
func (c *deepSeekGatewayConn) readEvents(ctx context.Context, events *harnessclient.Stream) string {
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		case frame, ok := <-events.Frames():
			if !ok {
				return "harness_events_closed"
			}
			c.handleInteractionFrame(ctx, frame)
		}
	}
}

// readFollow 读一条会话订阅：持久事件、直播片段与交互。
func (c *deepSeekGatewayConn) readFollow(ctx context.Context, follow *deepSeekFollow) {
	for {
		select {
		case <-ctx.Done():
			return
		case frame, ok := <-follow.stream.Frames():
			if !ok {
				if follow.isReleased() {
					// 本地主动回收（名额达到上限时淘汰空闲订阅）或整条连接正在关闭。
					// 这不是上游断流：名额已在回收时归还，其余订阅与客户端连接都不受影响，
					// 因此只结束这条读协程，不报告连接级失败。
					return
				}
				// 上游断流。三件事都必须做，缺一件都会留下一个"看起来还活着"的连接：
				//
				//   - 摘掉订阅：留在 follows 里的话，ensureFollow 会把这条不再产帧的
				//     订阅继续交给后续请求，历史读不完、turn/start 等不到编号，而调用方
				//     看到的是"没有错误、也没有结果"。
				//   - 归还名额：否则每断一次订阅就少一个可用并发数，最后表现为一个明明
				//     可用却连不上的运行时。
				//   - 结束连接：会话订阅断线后没有别人会重新订阅，只有断开才能走到
				//     客户端重连并重新订阅这条既有恢复路径。
				c.forgetFollow(follow)
				c.reportFollowStreamClosed()
				return
			}
			c.handleFollowFrame(ctx, follow, frame)
		}
	}
}

// forgetFollow 摘掉一条断掉的会话订阅并归还它占用的名额。
func (c *deepSeekGatewayConn) forgetFollow(follow *deepSeekFollow) {
	c.mu.Lock()
	current, ok := c.follows[follow.threadID]
	if !ok || current != follow {
		// 已经不是登记中的那一条：连接正在关闭（close 已清空 follows 并归还名额），
		// 或同一 thread 已经重新订阅过。这两种情况下名额都不该由这里归还。
		c.mu.Unlock()
		return
	}
	delete(c.follows, follow.threadID)
	c.mu.Unlock()

	follow.stream.Close()
	c.router.releaseDeepSeekSession()
}

// reportFollowStreamClosed 让一条断掉的会话订阅结束整条连接。
//
// 非阻塞：done 满说明已经有人报过退出原因，serve 会照着退出，这里不必等。
func (c *deepSeekGatewayConn) reportFollowStreamClosed() {
	if c.done == nil {
		return
	}
	select {
	case c.done <- "follow_stream_closed":
	default:
	}
}

func (c *deepSeekGatewayConn) handleFollowFrame(ctx context.Context, follow *deepSeekFollow, frame harnessclient.StreamValue) {
	if c.isClosed() {
		return
	}
	// 有帧到达说明这条订阅正在被使用：空闲回收的候选顺序要反映真实的活跃程度。
	follow.touch()
	switch frame.Type {
	case harnessclient.FrameDurableEvent:
		c.handleDurableEvent(follow, frame)
	case harnessclient.FrameAssistantStream:
		c.handleAssistantStream(follow, frame)
	case harnessclient.FrameWaterfall, harnessclient.FrameCancel:
		// 两条流都可能承载交互：waterfall 是宿主级的，但会话订阅上也可能出现。
		c.handleInteractionFrame(ctx, frame)
	}
}

// handleDurableEvent 翻译一条持久事件并下发。
func (c *deepSeekGatewayConn) handleDurableEvent(follow *deepSeekFollow, frame harnessclient.StreamValue) {
	var record harnessclient.SessionHistoryRecord
	if err := json.Unmarshal(frame.Raw, &record); err != nil {
		return
	}
	event := record.Wire()
	if strings.TrimSpace(event.Type) == "" {
		return
	}
	// 缓存必须包含直播期间到达的记录：客户端随后用 items/list 补历史时，
	// 这一段只能从本地缓存拿，Harness 的分页只到订阅切点为止。
	// 投递对账所需的 user/message 也在其中，因此 note 之后等待者即可自行取用，
	// 不需要在这里额外分发 turn 编号。
	follow.note([]harnessclient.SessionWireEvent{event})
	c.noteEventContext(follow.threadID, event)

	for _, notification := range translateDeepSeekDurableEvent(follow.threadID, event) {
		if err := c.writeDeepSeekNotification(notification.Method, notification.Params); err != nil {
			return
		}
	}
}

// noteEventContext 记录审批归属与订阅回收需要的上下文。
//
// Harness 的审批 waterfall 是宿主级通道，会话标识由帧上的 agentId 给出；callId 映射
// 是复核用的次选判据，因此这里照旧维护它。turn 起止用来判断哪个会话正在跑，订阅回收
// 用它区分"运行中的会话"与"只是被浏览过"。
func (c *deepSeekGatewayConn) noteEventContext(threadID string, event harnessclient.SessionWireEvent) {
	switch event.Type {
	case deepSeekEventTurnStart:
		c.mu.Lock()
		c.activeTurns[threadID]++
		c.mu.Unlock()
	case deepSeekEventTurnEnd:
		c.mu.Lock()
		// 只有归零才删除：同一个会话可以排着多轮，turn 计数不为零就说明还有轮次在跑，
		// 而回收空闲订阅的判据正是它。
		if count := c.activeTurns[threadID]; count > 1 {
			c.activeTurns[threadID] = count - 1
		} else {
			delete(c.activeTurns, threadID)
		}
		c.mu.Unlock()
	case deepSeekEventToolCall:
		var data deepSeekToolCallData
		if json.Unmarshal(event.Data, &data) != nil {
			return
		}
		if strings.TrimSpace(data.CallID) == "" {
			return
		}
		c.mu.Lock()
		c.callThreads[data.CallID] = threadID
		c.mu.Unlock()
		// 映射刚补上，可能正好有暂存的审批在等这条 callId。
		c.retryPendingInteractions()
	}
}

// handleAssistantStream 处理直播输出片段。
func (c *deepSeekGatewayConn) handleAssistantStream(follow *deepSeekFollow, frame harnessclient.StreamValue) {
	var envelope struct {
		Frame harnessclient.SessionAssistantStreamFrame `json:"frame"`
	}
	if err := json.Unmarshal(frame.Raw, &envelope); err != nil {
		return
	}
	streamFrame := envelope.Frame
	switch streamFrame.Type {
	case deepSeekStreamFrameStart:
		follow.noteAttempt(streamFrame.AttemptID, streamFrame.Turn, streamFrame.Step)
	case deepSeekStreamFrameChunk:
		attempt, ok := follow.attempt(streamFrame.AttemptID)
		if !ok {
			// 没有 start 定位的片段无法映射到 item，丢掉而不是猜一个 (turn, step)。
			return
		}
		for _, notification := range translateDeepSeekAssistantChunk(
			follow.threadID,
			attempt.Turn,
			attempt.Step,
			streamFrame.Chunk,
		) {
			if err := c.writeDeepSeekNotification(notification.Method, notification.Params); err != nil {
				return
			}
		}
	case deepSeekStreamFrameEnd:
		follow.forgetAttempt(streamFrame.AttemptID)
	}
}

// handleInteractionFrame 处理 waterfall 与 cancel。
func (c *deepSeekGatewayConn) handleInteractionFrame(ctx context.Context, frame harnessclient.StreamValue) {
	if c.isClosed() {
		return
	}
	switch frame.Type {
	case harnessclient.FrameWaterfall:
		request, err := frame.Waterfall()
		if err != nil {
			return
		}
		c.dispatchWaterfall(ctx, request)
	case harnessclient.FrameCancel:
		var cancel struct {
			EventID string `json:"eventId"`
		}
		if err := frame.Decode(&cancel); err != nil {
			return
		}
		c.resolveCancelledWaterfall(cancel.EventID)
	}
}

// deepSeekDeliveryStatus 描述一次尝试下发交互请求的结果。
type deepSeekDeliveryStatus int

const (
	// deepSeekDelivered 已送达客户端，登记待应答。
	deepSeekDelivered deepSeekDeliveryStatus = iota
	// deepSeekDropped 永久放弃：交互形态不受支持，或连接已关闭。不重试。
	deepSeekDropped
	// deepSeekDeferred 暂不可达：策略层按会话授权丢掉了它（本连接还没打开该会话）。
	// 这恰好随客户端打开该会话而恢复，暂存等重试。
	deepSeekDeferred
)

// dispatchWaterfall 把一条交互请求向下发，送不到时暂存。
func (c *deepSeekGatewayConn) dispatchWaterfall(ctx context.Context, request harnessclient.WaterfallRequest) {
	threadID, evidence := c.attributeWaterfall(request)
	if threadID == "" {
		// 没有方向性证据时不猜一个会话塞进去，而是暂存等关联信息补齐。
		// 这里曾经退回"恰好只有一个会话在跑就认领"，后果是把别的会话（Harness Web、
		// 子 Agent）的审批卡片挂到用户正在看的会话上：用户在那个上下文里点"允许"，
		// 放行的却是另一个会话的工具调用；追问更糟——用户填的答案会被送回发起方。
		// 见 attributeWaterfall 与 holdInteraction 的说明。
		c.holdInteraction(request, "")
		return
	}
	if c.deliverWaterfall(request, threadID, evidence) == deepSeekDeferred {
		c.holdInteraction(request, evidence)
	}
}

// deliverWaterfall 翻译并下发一条已经确定归属的交互请求，并回报结果。
//
// evidence 只用于诊断：它区分"上游直接给了会话身份"与"靠 callId 关联"，现场排查
// 归属问题时要能看出这条卡片是凭什么认领的。未送达时由调用方决定暂存还是放弃。
func (c *deepSeekGatewayConn) deliverWaterfall(
	request harnessclient.WaterfallRequest,
	threadID string,
	evidence string,
) deepSeekDeliveryStatus {
	translated, ok := translateDeepSeekWaterfall(threadID, request)
	if !ok {
		log.Printf("deepseek gateway 暂不支持的交互已忽略 event=%s",
			sanitizeGatewayDiagnostic(request.Event))
		return deepSeekDropped
	}
	requestID := nextDeepSeekServerRequestID()
	// 先登记再下发：客户端应答与事件读协程并发，先写出去再登记会留下一个
	// "应答比登记先到"的窗口，那条应答会被当成迟到应答丢弃。
	c.mu.Lock()
	c.waterfalls[request.EventID] = deepSeekPendingWaterfall{
		requestID: requestID,
		method:    translated.Method,
		threadID:  threadID,
		eventID:   request.EventID,
	}
	c.mu.Unlock()
	// 反向请求的 pending 由 policy 在出站方向上登记（forwardDeepSeekFrame →
	// observeUpstreamFrame），这里不再自己 rememberPendingServerRequest，
	// 否则同一件事记两份，policy 侧那份会覆盖本地的记账。
	delivered, err := c.forwardDeepSeekRequest(requestID, translated.Method, translated.Params)
	if err != nil {
		log.Printf("deepseek gateway 下发交互请求失败 err=%v", err)
	}
	if delivered {
		return deepSeekDelivered
	}
	// 没送到就不能留在待应答表里：否则客户端若应答了，会去解一条它从未见过的请求。
	c.dropWaterfall(request.EventID)
	if c.isClosed() {
		// 连接正在关闭，暂存没有意义。
		return deepSeekDropped
	}
	// 送不到还有一种常见原因：策略层按会话授权丢掉了它——本连接还没打开过这个会话。
	// 这恰恰会随"客户端打开该会话"而恢复，所以交回调用方暂存等一次重试。evidence 的
	// 使命到此为止（仅诊断定位），暂存重试时会重新归属、重新得到依据。
	return deepSeekDeferred
}

// holdInteraction 暂存一条还不能送达客户端的交互请求。
//
// 为什么不能直接丢：关联信息可能还没到，而且不只一种到达方式。
//
//   - callId → 会话的映射由会话订阅上的 tool/call 事件建立，审批却来自另一条
//     $events 连接，两条连接之间没有本实现可以依赖的到达顺序：waterfall 先到、
//     tool/call 后到是正常时序。
//   - 重连时更必然如此：新连接先订阅 $events（挂起的交互立刻按原 eventId 重投），
//     随后才由客户端请求建立会话订阅。此时本地映射一定是空的。
//   - 会话尚未被本连接打开时，策略层会按授权丢弃反向请求；客户端随后打开该会话，
//     这条请求就重新可送达。
//
// 直接丢弃会让这条交互在本连接上永久消失，而 Harness 侧仍在等它应答。
//
// 为什么不能猜一个会话塞进去：见 attributeWaterfall。
//
// 等待窗口有界：超过 deepSeekInteractionHoldTimeout 仍未送达就丢弃并记诊断。
// 期间不做任何"替其他会话作答"的动作——不发 unavailable、不发 rejected，
// 因为那等于替一个我们根本不知道的会话做决定。
func (c *deepSeekGatewayConn) holdInteraction(request harnessclient.WaterfallRequest, evidence string) {
	eventID := strings.TrimSpace(request.EventID)
	if eventID == "" {
		// 没有 eventId 既无法应答也无法按 cancel 撤销，暂存没有意义。
		return
	}
	log.Printf("deepseek gateway 交互请求暂存等待送达 event=%s evidence=%s callId=%s",
		sanitizeGatewayDiagnostic(request.Event), evidence, deepSeekCallIDPresence(request))

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	if c.pendingInteractions == nil {
		c.pendingInteractions = map[string]deepSeekPendingInteraction{}
	}
	if existing, ok := c.pendingInteractions[eventID]; ok {
		// 已经在等：保留原到期时间，否则反复重试会把等待窗口无限延长。
		existing.request = request
		c.pendingInteractions[eventID] = existing
		c.mu.Unlock()
		return
	}
	if len(c.pendingInteractions) >= deepSeekInteractionHoldMax {
		c.mu.Unlock()
		log.Printf("deepseek gateway 暂存的交互请求已达上限，丢弃 event=%s",
			sanitizeGatewayDiagnostic(request.Event))
		return
	}
	c.pendingInteractions[eventID] = deepSeekPendingInteraction{
		request:   request,
		expiresAt: time.Now().Add(deepSeekInteractionHoldTimeout),
	}
	c.mu.Unlock()
	c.scheduleInteractionRetry()
}

// scheduleInteractionRetry 安排下一次暂存重试。
func (c *deepSeekGatewayConn) scheduleInteractionRetry() {
	time.AfterFunc(deepSeekInteractionRetryInterval, func() { c.retryPendingInteractions() })
}

// retryPendingInteractions 重试暂存的交互请求，并清理过期的条目。
//
// 关联信息补齐与超时清理共用这一条路径：每次都重新归属，归属成功就下发并移出暂存；
// 超过等待窗口仍不成功的按诊断丢弃。只要还有未过期的条目就继续排下一次重试——
// 会话订阅建立、callId 落表、客户端打开会话这三件事都可能发生在任意时刻，
// 没有单一事件能把它们全部覆盖，所以用有界轮询兜住。
//
// 用 retryMu 串行化：关联信息补齐（noteEventContext）、订阅建立（ensureFollow）与轮询
// 定时器可能同时触发，并发执行会让同一条暂存交互被下发两次，客户端看到重复卡片。
// 串行化后每个触发点要么自己完成一轮，要么发现已有轮次在跑而跳过；被跳过的触发点
// 所代表的关联信息，要么已被在跑的那轮看到，要么由该轮结束后的下一次轮询接住。
func (c *deepSeekGatewayConn) retryPendingInteractions() {
	if !c.retryMu.TryLock() {
		return
	}
	defer c.retryMu.Unlock()
	if c.isClosed() {
		return
	}

	c.mu.Lock()
	pending := make([]deepSeekPendingInteraction, 0, len(c.pendingInteractions))
	for _, entry := range c.pendingInteractions {
		pending = append(pending, entry)
	}
	c.mu.Unlock()
	if len(pending) == 0 {
		return
	}

	now := time.Now()
	remaining := 0
	for _, entry := range pending {
		eventID := strings.TrimSpace(entry.request.EventID)
		threadID, evidence := c.attributeWaterfall(entry.request)
		if threadID == "" {
			if now.Before(entry.expiresAt) {
				remaining++
				continue
			}
			c.forgetPendingInteraction(eventID)
			log.Printf("deepseek gateway 交互请求在等待窗口内未能归属，已丢弃 event=%s callId=%s",
				sanitizeGatewayDiagnostic(entry.request.Event), deepSeekCallIDPresence(entry.request))
			continue
		}
		switch c.deliverWaterfall(entry.request, threadID, evidence) {
		case deepSeekDelivered, deepSeekDropped:
			// 已送达（登记待应答）或永久放弃（不支持/连接关闭），都不再保留暂存。
			c.forgetPendingInteraction(eventID)
		case deepSeekDeferred:
			// 归属已知但仍无从送达（会话尚未授权/打开）。保留原到期时间继续等，
			// 不因为一次未送达就重开等待窗口——重开会把"等待 2 分钟"退化成"永远等"。
			if now.Before(entry.expiresAt) {
				remaining++
				continue
			}
			c.forgetPendingInteraction(eventID)
			log.Printf("deepseek gateway 交互请求在等待窗口内未能送达，已丢弃 event=%s callId=%s",
				sanitizeGatewayDiagnostic(entry.request.Event), deepSeekCallIDPresence(entry.request))
		}
	}
	if remaining > 0 && !c.isClosed() {
		c.scheduleInteractionRetry()
	}
}

// forgetPendingInteraction 从暂存区移除一条交互请求。
func (c *deepSeekGatewayConn) forgetPendingInteraction(eventID string) {
	c.mu.Lock()
	delete(c.pendingInteractions, strings.TrimSpace(eventID))
	c.mu.Unlock()
}

// deepSeekCallIDPresence 区分"上游没给方向性证据"（absent）与"给了但本连接还查不到"
// （unknown）。两者的处置相同（都要等关联信息），但现场排查时必须能分辨。
func deepSeekCallIDPresence(request harnessclient.WaterfallRequest) string {
	if strings.TrimSpace(request.Request.CallID) == "" {
		return "absent"
	}
	return "unknown"
}

// dropWaterfall 撤销一条未能送达的交互请求登记。
func (c *deepSeekGatewayConn) dropWaterfall(eventID string) {
	c.mu.Lock()
	delete(c.waterfalls, eventID)
	c.mu.Unlock()
}

// attributeWaterfall 判断一条交互请求属于哪个会话，并回报依据。
//
// 判据按证据强度排序，全部是上游给出或本地可核对的事实，没有推断：
//
//  1. 帧内会话身份。api-gateway 0.1.5-rc.2 固定填 agentId，而 Harness 的身份设计是
//     "agent 的注册表 id 等于其会话 id"，所以 agentId 就是会话标识。审批与追问
//     都带它，这是生产路径上的主判据。
//  2. callId → 会话映射。只有本连接的会话事件里真的见过这次工具调用才成立，
//     是复核用的次选判据；重连后映射为空时它拿不到结论，此时按"尚未关联"暂存。
//
// 取不到证据时返回空串，由调用方暂存等待（retryPendingInteractions），**不猜测**。
// 这里刻意不再使用"恰好只有一个会话有未结束的 turn 就算它"这条兜底：$events 是宿主级
// 通道，别的会话（Harness Web、子 Agent）的审批与追问同样送到这里，"只有一个会话在跑"
// 并不蕴含"这条交互是我的"。按单例认领会把别人的卡片挂到用户的会话上，用户在那个
// 上下文里做出的授权决定会被用在另一个会话的工具调用上。
func (c *deepSeekGatewayConn) attributeWaterfall(request harnessclient.WaterfallRequest) (string, string) {
	if agentID := strings.TrimSpace(request.AgentID); agentID != "" {
		return agentID, deepSeekEvidenceAgent
	}
	if hint := request.ThreadHint(); hint != "" {
		return hint, deepSeekEvidenceHint
	}
	if callID := strings.TrimSpace(request.Request.CallID); callID != "" {
		c.mu.Lock()
		threadID, ok := c.callThreads[callID]
		c.mu.Unlock()
		if ok {
			return threadID, deepSeekEvidenceCall
		}
	}
	return "", ""
}

// 归属依据，只用于日志与诊断。
const (
	deepSeekEvidenceAgent = "agent"
	deepSeekEvidenceHint  = "hint"
	deepSeekEvidenceCall  = "callId"
)

// resolveCancelledWaterfall 通知移动端某条交互请求已作废（其它端先应答了）。
func (c *deepSeekGatewayConn) resolveCancelledWaterfall(eventID string) {
	c.mu.Lock()
	pending, ok := c.waterfalls[eventID]
	if ok {
		delete(c.waterfalls, eventID)
	}
	// 作废同样适用于还在暂存区里的请求：它已经不可能被应答，继续等送达只会
	// 在等待窗口结束时留下一条误导性的超时诊断。
	delete(c.pendingInteractions, strings.TrimSpace(eventID))
	c.mu.Unlock()
	if !ok {
		return
	}
	if err := c.writeDeepSeekNotification("serverRequest/resolved", map[string]any{
		"threadId":  pending.threadID,
		"requestId": pending.requestID,
	}); err != nil {
		return
	}
	if rawID, err := deepSeekRawID(pending.requestID); err == nil {
		c.policy.forgetPending(rawID)
	}
}

// takeWaterfall 取出一条待应答的交互请求。
func (c *deepSeekGatewayConn) takeWaterfall(requestID int64) (deepSeekPendingWaterfall, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for eventID, pending := range c.waterfalls {
		if pending.requestID == requestID {
			delete(c.waterfalls, eventID)
			return pending, true
		}
	}
	return deepSeekPendingWaterfall{}, false
}

// respondWaterfall 把移动端应答翻译成 Harness 的 outcome 并回传。
//
// Harness 的 outcome 只有 result 一种成功形态，审批结论本身作为 value 传回。
func (c *deepSeekGatewayConn) respondWaterfall(ctx context.Context, pending deepSeekPendingWaterfall, rawResult json.RawMessage) error {
	if pending.eventID == "" {
		return errors.New("deepseek gateway: 交互请求缺少 eventId")
	}
	if pending.method == "item/tool/requestUserInput" {
		answers, ok := deepSeekQuestionAnswers(rawResult)
		if !ok {
			return errors.New("deepseek gateway: 追问应答格式无效")
		}
		return c.harness.AnswerQuestions(ctx, c.clientID, pending.eventID, answers)
	}
	decision, ok := deepSeekApprovalDecision(rawResult)
	if !ok {
		return errors.New("deepseek gateway: 审批应答缺少 decision")
	}
	outcome := deepSeekApprovalOutcome(decision)
	return c.harness.ResolveApproval(ctx, c.clientID, pending.eventID, outcome)
}

// deepSeekApprovalDecision 从应答体里取审批结论。
func deepSeekApprovalDecision(raw json.RawMessage) (string, bool) {
	var decoded struct {
		Decision string `json:"decision"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return "", false
	}
	decision := strings.TrimSpace(decoded.Decision)
	if decision == "" {
		return "", false
	}
	return decision, true
}

// deepSeekApprovalOutcome 把 Mimi 的审批结论映射成 Harness 的 outcome。
//
// Harness 只提供 allowed-once 这一种放行语义，没有会话级或长期授权。用户选择
// acceptForSession/acceptAlways 时按一次性放行处理：这是比用户请求更窄的授权，
// 方向是安全的，也不会在下一次工具调用上静默放行。
func deepSeekApprovalOutcome(decision string) string {
	switch strings.ToLower(strings.TrimSpace(decision)) {
	case "accept", "approve", "approved",
		"acceptforsession", "accept_for_session",
		"acceptalways", "accept_always",
		"acceptwithpermissionupdate", "accept_with_permission_update":
		return harnessclient.OutcomeAllowedOnce
	case "decline", "deny", "denied", "reject", "rejected":
		return harnessclient.OutcomeRejected
	case "cancel", "cancelled", "canceled", "abort":
		return harnessclient.OutcomeCancelled
	default:
		// 认不出的结论一律按不可用回传，不能默认放行。
		return harnessclient.OutcomeUnavailable
	}
}

// deepSeekQuestionAnswers 把 Mimi 的追问应答翻译成 Harness 的 answers。
//
// 应答形状：{"answers": {"<questionId>": {"answers": ["..."]}}}，与提问的 id 逐条对应。
func deepSeekQuestionAnswers(raw json.RawMessage) ([]harnessclient.Answer, bool) {
	var decoded struct {
		Answers map[string]struct {
			Answers []string `json:"answers"`
		} `json:"answers"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil || len(decoded.Answers) == 0 {
		return nil, false
	}
	answers := make([]harnessclient.Answer, 0, len(decoded.Answers))
	for id, entry := range decoded.Answers {
		if strings.TrimSpace(id) == "" {
			return nil, false
		}
		answers = append(answers, harnessclient.Answer{ID: id, Selected: entry.Answers})
	}
	return answers, true
}

var deepSeekServerRequestSeq atomic.Int64

func nextDeepSeekServerRequestID() int64 {
	return deepSeekServerRequestSeq.Add(1)
}

func deepSeekRawID(id int64) (*json.RawMessage, error) {
	raw, err := json.Marshal(id)
	if err != nil {
		return nil, err
	}
	message := json.RawMessage(raw)
	return &message, nil
}

// forwardDeepSeekRequest 下发一条带 id 的反向请求，并报告它是否真的到了客户端。
func (c *deepSeekGatewayConn) forwardDeepSeekRequest(id int64, method string, params map[string]any) (bool, error) {
	return c.forwardDeepSeekPayload(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  method,
		"params":  params,
	})
}
