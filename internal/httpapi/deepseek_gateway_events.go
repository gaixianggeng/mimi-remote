package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strings"
	"sync/atomic"

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
				return
			}
			c.handleFollowFrame(ctx, follow, frame)
		}
	}
}

func (c *deepSeekGatewayConn) handleFollowFrame(ctx context.Context, follow *deepSeekFollow, frame harnessclient.StreamValue) {
	if c.isClosed() {
		return
	}
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
	follow.note([]harnessclient.SessionWireEvent{event})
	c.noteEventContext(follow.threadID, event)
	if event.Type == deepSeekEventTurnStart {
		// 把真实 turn 编号交给等待 turn/start 应答的请求，避免编造 turn id。
		var data deepSeekTurnData
		if json.Unmarshal(event.Data, &data) == nil {
			follow.noteTurnStart(data.Turn)
		}
	}

	for _, notification := range translateDeepSeekDurableEvent(follow.threadID, event) {
		if err := c.writeDeepSeekNotification(notification.Method, notification.Params); err != nil {
			return
		}
	}
}

// noteEventContext 记录审批归属需要的上下文。
//
// Harness 的审批 waterfall 是宿主级通道，不带会话标识，因此必须从会话自己的事件里
// 建立可核对的相关性：tool/call 的 callId 是实测存在的字段，turn 起止用来判断哪个
// 会话正在跑。
func (c *deepSeekGatewayConn) noteEventContext(threadID string, event harnessclient.SessionWireEvent) {
	switch event.Type {
	case deepSeekEventTurnStart:
		c.mu.Lock()
		c.activeTurns[threadID]++
		c.mu.Unlock()
	case deepSeekEventTurnEnd:
		c.mu.Lock()
		if c.activeTurns[threadID] > 0 {
			c.activeTurns[threadID]--
		}
		delete(c.activeTurns, threadID)
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

// dispatchWaterfall 把一条交互请求翻译后下发。
func (c *deepSeekGatewayConn) dispatchWaterfall(ctx context.Context, request harnessclient.WaterfallRequest) {
	threadID := c.attributeWaterfall(request)
	if threadID == "" {
		// 归属不明时不下发：把审批挂到错误会话上，用户会在一个无关的会话里看到
		// 卡片，还会照着那张卡片放行别人的操作。宁可记诊断。
		// callId 单独记一下，现场才能区分"上游没给方向性证据"（absent）与
		// "证据指向本连接没订阅的会话"（unknown）——两者的处置完全不同。
		callIDPresence := "absent"
		if strings.TrimSpace(request.Request.CallID) != "" {
			callIDPresence = "unknown"
		}
		log.Printf("deepseek gateway 交互请求无法归属会话，已忽略 event=%s callId=%s",
			sanitizeGatewayDiagnostic(request.Event), callIDPresence)
		return
	}
	translated, ok := translateDeepSeekWaterfall(threadID, request)
	if !ok {
		log.Printf("deepseek gateway 暂不支持的交互已忽略 event=%s",
			sanitizeGatewayDiagnostic(request.Event))
		return
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
	if !delivered {
		// 没送到就不能留在待应答表里：否则客户端若应答了，会去解一条它从未见过的请求。
		c.dropWaterfall(request.EventID)
	}
}

// dropWaterfall 撤销一条未能送达的交互请求登记。
func (c *deepSeekGatewayConn) dropWaterfall(eventID string) {
	c.mu.Lock()
	delete(c.waterfalls, eventID)
	c.mu.Unlock()
}

// attributeWaterfall 判断一条交互请求属于哪个会话。
//
// 判据分两类，因为两条 waterfall 携带的证据不同：
//
//  1. 正向证据：帧里直接带了会话标识（不同版本可能补上），或 callId 在本连接的
//     tool/call 记录里出现过。
//  2. 无证据时的兜底：恰好只有一个会话有未结束的 turn。
//
// 关键是第 2 条什么时候才允许用。Harness 的 $events 是宿主级通道，别的会话
// （Harness Web、子 Agent）的审批同样会送到这里，因此"只有一个会话在跑"并不
// 蕴含"这条交互是我的"。callId 带了却查不到映射，恰恰是"这次工具调用不在本连接
// 订阅的会话里"的正向证据——此时再按第 2 条认领，就会把别人的审批卡片挂到用户的
// 会话上：用户以为在批准自己会话的操作，实际放行的是别的会话的。
//
// 所以第 2 条只在完全没有 callId 时生效（追问的载荷只有 questions，没有任何
// 方向性证据），有 callId 就对它负责。
func (c *deepSeekGatewayConn) attributeWaterfall(request harnessclient.WaterfallRequest) string {
	if hint := request.ThreadHint(); hint != "" {
		return hint
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if callID := strings.TrimSpace(request.Request.CallID); callID != "" {
		if threadID, ok := c.callThreads[callID]; ok {
			return threadID
		}
		return ""
	}
	if len(c.activeTurns) == 1 {
		for threadID, count := range c.activeTurns {
			if count > 0 {
				return threadID
			}
		}
	}
	return ""
}

// resolveCancelledWaterfall 通知移动端某条交互请求已作废（其它端先应答了）。
func (c *deepSeekGatewayConn) resolveCancelledWaterfall(eventID string) {
	c.mu.Lock()
	pending, ok := c.waterfalls[eventID]
	if ok {
		delete(c.waterfalls, eventID)
	}
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
