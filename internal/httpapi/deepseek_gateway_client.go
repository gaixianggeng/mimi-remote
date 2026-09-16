package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件处理移动端发来的 app-server 请求，把它们翻译成 harnessclient 调用。
//
// 进入这里的帧都已经过 appServerGatewayPolicy 的校验与安全改写：方法必须在
// appServerDeepSeekAllowedMethods 里，cwd 必须命中工作区授权，危险沙盒参数已被压回。
// 因此这里只负责"翻译"，不重复做权限判断。

// appServerDeepSeekRootAgentPreset 是新建 Harness 会话时使用的预设。
const appServerDeepSeekRootAgentPreset = "default"

// readClientFrames 读移动端帧直到连接结束。
func (c *deepSeekGatewayConn) readClientFrames(ctx context.Context) string {
	for {
		messageType, payload, err := c.client.ReadMessage()
		if err != nil {
			return gatewayCloseReason("client_read", err)
		}
		rewritten, policyErr := c.policy.validateClientFrameContext(ctx, messageType, payload)
		if policyErr != nil {
			if !writeGatewayPolicyError(c.client, &c.writeMu, policyErr) {
				return "client_policy_error_write_failed"
			}
			continue
		}
		if err := c.handleClientFrame(ctx, rewritten); err != nil {
			log.Printf("deepseek gateway 处理客户端帧失败 err=%v", err)
		}
	}
}

// handleClientFrame 分派一条已经过策略校验的帧。
func (c *deepSeekGatewayConn) handleClientFrame(ctx context.Context, payload []byte) error {
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return err
	}
	// 没有 method 且带 id 的帧是对反向请求的应答。
	if strings.TrimSpace(frame.Method) == "" {
		return c.handleClientResponse(ctx, &frame)
	}
	if frame.ID == nil {
		// initialized 之类的通知没有 id，也不需要应答。
		return nil
	}
	return c.dispatchClientRequest(ctx, &frame)
}

// handleClientResponse 处理移动端对审批或追问的应答。
func (c *deepSeekGatewayConn) handleClientResponse(ctx context.Context, frame *appServerGatewayFrame) error {
	id, ok := deepSeekFrameIntID(frame.ID)
	if !ok {
		return nil
	}
	pending, ok := c.takeWaterfall(id)
	if !ok {
		// 迟到应答或不属于本连接的应答：空操作，不是错误。
		return nil
	}
	if len(frame.Result) == 0 {
		// 客户端明确回了 error：按不可用回传，不能让 Harness 一直等。
		return c.harness.ResolveApproval(ctx, c.clientID, pending.eventID, harnessclient.OutcomeUnavailable)
	}
	if err := c.respondWaterfall(ctx, pending, frame.Result); err != nil {
		log.Printf("deepseek gateway 回传交互应答失败 event=%s err=%v",
			sanitizeGatewayDiagnostic(pending.eventID), err)
		return nil
	}
	if rawID, err := deepSeekRawID(pending.requestID); err == nil {
		c.policy.forgetPending(rawID)
	}
	return nil
}

// dispatchClientRequest 按方法分派。
func (c *deepSeekGatewayConn) dispatchClientRequest(ctx context.Context, frame *appServerGatewayFrame) error {
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, err.Error())
	}
	switch frame.Method {
	case "initialize":
		return c.writeDeepSeekResult(frame.ID, map[string]any{
			"userAgent":      "mimi-remote/deepseek-harness",
			"platformFamily": "macos",
		})
	case "thread/list":
		return c.handleThreadList(ctx, frame, params)
	case "thread/search":
		return c.handleThreadSearch(ctx, frame, params)
	case "thread/start":
		return c.handleThreadStart(ctx, frame, params)
	case "thread/read":
		return c.handleThreadRead(ctx, frame, params)
	case "thread/turns/list":
		return c.handleThreadTurnsList(ctx, frame, params)
	case "thread/items/list":
		return c.handleThreadItemsList(ctx, frame, params)
	case "turn/start":
		return c.handleTurnStart(ctx, frame, params)
	case "turn/interrupt":
		return c.handleTurnInterrupt(ctx, frame, params)
	case "model/list":
		return c.handleModelList(ctx, frame)
	default:
		// 策略层已按方法白名单拦过，走到这里说明两边登记不一致，如实报错。
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "app-server method 尚未适配："+frame.Method)
	}
}

// handleThreadList 列出授权工作区内的会话。
//
// session/list 的请求体里没有 cwd，返回的是本机可见的全部会话，因此按授权工作区裁剪
// 必须在这里做。裁剪发生在分页边界之后，所以不用 Harness 的游标，而是把过滤后的结果
// 作为一份稳定列表按偏移分页：把上游游标直接透传会让"下一页"丢掉被裁掉的空档，
// 客户端看到的页大小与游标语义就不再一致。
func (c *deepSeekGatewayConn) handleThreadList(ctx context.Context, frame *appServerGatewayFrame, params map[string]any) error {
	cwd, _ := gatewayStringParam(params, "cwd")
	scope, ok := c.router.gatewayScopeForPath(cwd)
	if !ok {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "thread/list.cwd 必须来自 projects allowlist 或 browse_roots")
	}
	sessions, err := c.harness.ListSessions(ctx, harnessclient.SessionListRequest{})
	if err != nil {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "读取 Harness 会话列表失败")
	}
	visible := make([]harnessclient.SessionSummary, 0, len(sessions))
	for _, session := range sessions {
		if strings.TrimSpace(session.CWD) == "" {
			// 没有 cwd 的会话无法证明属于授权工作区，fail closed。
			continue
		}
		if !gatewayScopeContainsPath(scope, session.CWD) {
			continue
		}
		if session.Blank {
			// 还没有任何轮次的会话在 Mimi 里是空会话，列表不展示。
			continue
		}
		visible = append(visible, session)
	}
	// 最近活动的在前，与 Mimi 侧栏的"最近"一致。
	sort.SliceStable(visible, func(i, j int) bool { return visible[i].UpdatedAt > visible[j].UpdatedAt })

	offset, _ := deepSeekOffsetCursor(gatewayCursorParam(params))
	limit := deepSeekListLimit(params)
	page, nextOffset := deepSeekSessionPage(visible, offset, limit)

	rows := make([]any, 0, len(page))
	for _, session := range page {
		rows = append(rows, deepSeekThreadWire(session, nil, false))
	}
	return c.writeDeepSeekResult(frame.ID, deepSeekPageResult(rows, nextOffset))
}

// deepSeekSearchLocalResultCap 限制本地兜底搜索返回的行数。
const deepSeekSearchLocalResultCap = 50

// handleThreadSearch 搜索会话。
//
// 优先用 Harness 的会话检索；部署未开启检索索引时 Harness 返回 gateway/internal，
// 这时退化为按 session/list 的标题与轮次摘要做本地包含匹配。降级而不是报错：索引是
// 宿主侧的可选配置，缺它不应该让搜索入口整体不可用。
//
// 两条硬约束决定了这里必须先把会话摘要补齐：
//
//   - Harness 的检索结果只有 {sessionId, snippet}，**不带 cwd**；而 iOS 的
//     threadSearchPage 逐行要求 {thread: {…含 cwd…}, snippet}，缺任一项会抛
//     invalidResponse 让整页搜索失败。
//   - cwd 同时是结果授权的唯一依据。检索索引覆盖本机全部会话，而 thread/search
//     请求里没有 cwd，请求侧无从比对；只有把 cwd 补回去，policy 的响应侧裁剪
//     （sanitizeThreadSearchResponse）才能按 projects/browse_roots 判归属。
//
// 拿不到摘要的命中直接丢弃：补不出 cwd 就无法证明它属于授权工作区，fail closed。
func (c *deepSeekGatewayConn) handleThreadSearch(ctx context.Context, frame *appServerGatewayFrame, params map[string]any) error {
	query := firstNonEmpty(
		gatewayParamString(params, "searchTerm"),
		gatewayParamString(params, "query"),
	)
	if query == "" {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "thread/search.searchTerm 不能为空")
	}
	sessions, err := c.harness.ListSessions(ctx, harnessclient.SessionListRequest{})
	if err != nil {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "读取 Harness 会话列表失败")
	}
	byID := make(map[string]harnessclient.SessionSummary, len(sessions))
	for _, session := range sessions {
		byID[session.SessionID] = session
	}

	if result, searchErr := c.harness.SearchSessions(ctx, query); searchErr == nil {
		rows := make([]any, 0, len(result.Items))
		for _, item := range result.Items {
			session, ok := byID[item.SessionID]
			if !ok {
				continue
			}
			if row, ok := deepSeekSearchRowWire(session, item.Snippet); ok {
				rows = append(rows, row)
			}
		}
		return c.writeDeepSeekResult(frame.ID, deepSeekPageResult(rows, 0))
	} else {
		log.Printf("deepseek gateway 会话检索不可用，退化为本地匹配 err=%v", sanitizeGatewayDiagnostic(searchErr.Error()))
	}

	needle := strings.ToLower(query)
	rows := make([]any, 0, 16)
	for _, session := range sessions {
		if session.Blank {
			continue
		}
		haystack, snippet := deepSeekSearchHaystack(session)
		if !strings.Contains(haystack, needle) {
			continue
		}
		if row, ok := deepSeekSearchRowWire(session, snippet); ok {
			rows = append(rows, row)
		}
		if len(rows) >= deepSeekSearchLocalResultCap {
			break
		}
	}
	return c.writeDeepSeekResult(frame.ID, deepSeekPageResult(rows, 0))
}

// deepSeekSearchHaystack 拼出参与本地匹配的文本与可展示的命中摘要。
func deepSeekSearchHaystack(session harnessclient.SessionSummary) (string, string) {
	if session.Projections == nil {
		return strings.ToLower(session.SessionID), ""
	}
	values := session.Projections.Values
	title := strings.TrimSpace(values.Title)
	snippet := title
	parts := []string{title, session.SessionID}
	for index := len(values.TurnOutline) - 1; index >= 0; index-- {
		outline := values.TurnOutline[index]
		parts = append(parts, outline.Prompt, outline.Response)
		if snippet == "" {
			snippet = firstNonEmpty(outline.Prompt, outline.Response)
		}
	}
	return strings.ToLower(strings.Join(parts, "\n")), snippet
}

// handleThreadStart 新建会话。
func (c *deepSeekGatewayConn) handleThreadStart(ctx context.Context, frame *appServerGatewayFrame, params map[string]any) error {
	cwd, _ := gatewayStringParam(params, "cwd")
	created, err := c.harness.CreateSession(ctx, harnessclient.CreateSessionRequest{
		CWD:         cwd,
		AgentPreset: appServerDeepSeekRootAgentPreset,
	})
	if err != nil {
		log.Printf("deepseek gateway 新建会话失败 err=%v", sanitizeGatewayDiagnostic(err.Error()))
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "在 Harness 上新建会话失败")
	}
	if _, err := c.ensureFollow(ctx, created.SessionID); err != nil {
		log.Printf("deepseek gateway 订阅新会话失败 err=%v", sanitizeGatewayDiagnostic(err.Error()))
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "订阅 Harness 会话失败")
	}
	thread := map[string]any{
		"id":     created.SessionID,
		"cwd":    cwd,
		"status": "notLoaded",
	}
	if preset := strings.TrimSpace(created.AgentPreset); preset != "" {
		thread["agentPreset"] = preset
	}
	return c.writeDeepSeekResult(frame.ID, map[string]any{"thread": thread})
}

// handleThreadRead 读取会话元数据。
//
// Harness 没有单独的 read 方法：元数据来自 session/list 的同一条摘要。刻意不在这里
// 顺带返回 turns——客户端会为此发 thread/turns/list，混在两处会让"turns 是否权威"
// 出现两种说法。
func (c *deepSeekGatewayConn) handleThreadRead(ctx context.Context, frame *appServerGatewayFrame, params map[string]any) error {
	threadID := gatewayParamString(params, "threadId")
	if threadID == "" {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "thread/read.threadId 不能为空")
	}
	summary, err := c.findSession(ctx, threadID)
	if err != nil {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "读取 Harness 会话失败")
	}
	return c.writeDeepSeekResult(frame.ID, map[string]any{
		"thread": deepSeekThreadWire(summary, nil, false),
	})
}

// handleThreadTurnsList 返回一页 turn。items 随页给出，itemsView 标为 full，
// 客户端因此不会为这些 turn 再补发 items/list。
func (c *deepSeekGatewayConn) handleThreadTurnsList(ctx context.Context, frame *appServerGatewayFrame, params map[string]any) error {
	threadID := gatewayParamString(params, "threadId")
	if threadID == "" {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "thread/turns/list.threadId 不能为空")
	}
	follow, err := c.ensureFollow(ctx, threadID)
	if err != nil {
		return c.deepSeekFollowError(frame, err)
	}
	buckets, nextOffset, err := c.deepSeekTurnPage(ctx, follow, params)
	if err != nil {
		return c.deepSeekFollowError(frame, err)
	}
	rows := make([]any, 0, len(buckets))
	for _, bucket := range buckets {
		rows = append(rows, deepSeekTurnWire(bucket, true))
	}
	return c.writeDeepSeekResult(frame.ID, deepSeekPageResult(rows, nextOffset))
}

// handleThreadItemsList 返回一个 turn 的 item。
func (c *deepSeekGatewayConn) handleThreadItemsList(ctx context.Context, frame *appServerGatewayFrame, params map[string]any) error {
	threadID := gatewayParamString(params, "threadId")
	if threadID == "" {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "thread/items/list.threadId 不能为空")
	}
	turn, ok := deepSeekTurnNumber(gatewayParamString(params, "turnId"))
	if !ok {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "thread/items/list.turnId 无效")
	}
	follow, err := c.ensureFollow(ctx, threadID)
	if err != nil {
		return c.deepSeekFollowError(frame, err)
	}
	bucket, err := c.ensureTurnRecords(ctx, follow, turn)
	if err != nil {
		if errors.Is(err, errDeepSeekThreadUnknown) {
			return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "thread/items/list.turnId 不在该会话中")
		}
		return c.deepSeekFollowError(frame, err)
	}
	items := deepSeekTurnItems(bucket)
	rows := make([]any, 0, len(items))
	for _, item := range items {
		rows = append(rows, map[string]any{
			"turnId": deepSeekTurnID(turn),
			"item":   item,
		})
	}
	// item 页一次给完：记录已经在本地缓存里，继续分页只会把同一条记录再要一遍。
	return c.writeDeepSeekResult(frame.ID, deepSeekPageResult(rows, 0))
}

// handleTurnStart 投递一次输入。
func (c *deepSeekGatewayConn) handleTurnStart(ctx context.Context, frame *appServerGatewayFrame, params map[string]any) error {
	threadID := gatewayParamString(params, "threadId")
	if threadID == "" {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "turn/start.threadId 不能为空")
	}
	content, ok := deepSeekPromptContent(params["input"])
	if !ok {
		// 非文本输入首版未开放。静默丢弃会让用户以为附件已经发出去。
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "turn/start.input 首版只支持纯文本")
	}
	follow, err := c.ensureFollow(ctx, threadID)
	if err != nil {
		return c.deepSeekFollowError(frame, err)
	}
	// requestId 直接复用客户端的 clientUserMessageId：Harness 按 requestId 去重，
	// 而 user/message 事件会把它作为 source.rpcId 回传，客户端据此把乐观消息对上。
	requestID := gatewayParamString(params, "clientUserMessageId")
	if requestID == "" {
		requestID = harnessclient.NewRequestID()
	}
	follow.drainTurnStarts()
	if err := c.harness.Prompt(ctx, harnessclient.PromptRequest{
		SessionID: threadID,
		RequestID: requestID,
		Mode:      harnessclient.PromptModeQueue,
		Content:   content,
	}); err != nil {
		log.Printf("deepseek gateway 投递输入失败 err=%v", sanitizeGatewayDiagnostic(err.Error()))
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "向 Harness 投递输入失败")
	}
	// 等 Harness 把 turn 编号发出来，把真实 turn id 回给客户端。等不到就不带 id
	// 回应——编一个 turn 号会让客户端的中断对账与 active 清理指向错误的 turn。
	turn := map[string]any{"status": "inProgress"}
	if number, ok := follow.awaitTurnStart(ctx, deepSeekTurnStartAckTimeout); ok {
		turn["id"] = deepSeekTurnID(number)
	}
	return c.writeDeepSeekResult(frame.ID, map[string]any{"turn": turn})
}

// handleTurnInterrupt 取消当前轮次。
func (c *deepSeekGatewayConn) handleTurnInterrupt(ctx context.Context, frame *appServerGatewayFrame, params map[string]any) error {
	threadID := gatewayParamString(params, "threadId")
	if threadID == "" {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "turn/interrupt.threadId 不能为空")
	}
	if err := c.harness.Cancel(ctx, threadID); err != nil {
		log.Printf("deepseek gateway 取消轮次失败 err=%v", sanitizeGatewayDiagnostic(err.Error()))
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "取消 Harness 轮次失败")
	}
	return c.writeDeepSeekResult(frame.ID, map[string]any{})
}

// handleModelList 返回 Harness 自己声明的模型目录。
func (c *deepSeekGatewayConn) handleModelList(ctx context.Context, frame *appServerGatewayFrame) error {
	catalog, err := c.harness.ModelCatalog(ctx)
	if err != nil {
		log.Printf("deepseek gateway 读取模型目录失败 err=%v", sanitizeGatewayDiagnostic(err.Error()))
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "读取 Harness 模型目录失败")
	}
	return c.writeDeepSeekResult(frame.ID, deepSeekPageResult(deepSeekModelListWire(catalog), 0))
}

// deepSeekFollowError 把订阅与历史读取的失败翻译成固定文案。
func (c *deepSeekGatewayConn) deepSeekFollowError(frame *appServerGatewayFrame, err error) error {
	if errors.Is(err, errDeepSeekSessionLimit) {
		return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "Harness 会话并发数已达上限，请稍后重试")
	}
	log.Printf("deepseek gateway 会话订阅失败 err=%v", sanitizeGatewayDiagnostic(err.Error()))
	return c.writeDeepSeekError(frame.ID, appServerPolicyErrorCode, "订阅 Harness 会话失败")
}

// findSession 按 id 找一条会话摘要。
func (c *deepSeekGatewayConn) findSession(ctx context.Context, threadID string) (harnessclient.SessionSummary, error) {
	sessions, err := c.harness.ListSessions(ctx, harnessclient.SessionListRequest{})
	if err != nil {
		return harnessclient.SessionSummary{}, err
	}
	for _, session := range sessions {
		if session.SessionID == threadID {
			return session, nil
		}
	}
	return harnessclient.SessionSummary{}, errDeepSeekThreadUnknown
}

// deepSeekTurnPage 取一页 turn。offset 由本层游标给出，向前翻页时才向 Harness 取记录。
func (c *deepSeekGatewayConn) deepSeekTurnPage(
	ctx context.Context,
	follow *deepSeekFollow,
	params map[string]any,
) ([]deepSeekTurnBucket, int, error) {
	offset, _ := deepSeekOffsetCursor(gatewayCursorParam(params))
	limit := deepSeekTurnListLimit(params)
	if limit <= 0 {
		limit = 40
	}
	// 向前翻页需要的记录可能还没有从 Harness 取过；取到 offset+limit 个 turn 为止。
	for page := 0; page < deepSeekMaxHistoryFetchPages; page++ {
		buckets := deepSeekSplitTurns(follow.snapshot())
		if len(buckets) >= offset+limit || follow.atStart() {
			break
		}
		before := follow.oldestCachedSeq()
		if before <= 0 {
			break
		}
		records, hasMore, err := c.fetchDeepSeekHistoryPage(ctx, follow, before, deepSeekHistoryPageSize)
		if err != nil {
			return nil, 0, err
		}
		if len(records) == 0 {
			follow.markReachedStart()
			break
		}
		follow.note(records)
		if !hasMore {
			follow.markReachedStart()
			break
		}
	}
	// 缓存与 Mimi 一样按时间正序展示；下游请求的是 desc（最近的在前）。
	buckets := deepSeekSplitTurns(follow.snapshot())
	ordered := make([]deepSeekTurnBucket, 0, len(buckets))
	for index := len(buckets) - 1; index >= 0; index-- {
		ordered = append(ordered, buckets[index])
	}
	if offset >= len(ordered) {
		// 缓存里没有这一页了。宿主历史还没读完时不能收尾：客户端收到 null 游标就
		// 认为会话到此为止，把游标留在原地，下一次请求会继续向前取。
		if follow.atStart() {
			return nil, 0, nil
		}
		return nil, offset, nil
	}
	end := offset + limit
	if end > len(ordered) {
		end = len(ordered)
	}
	page := ordered[offset:end]
	// 缓存读完不等于宿主历史读完：订阅开场快照只覆盖到 cursor 切点为止，更早的轮次
	// 还在 Harness 上，也可能落在一次请求的取页上限之外。只有确实读到了会话开头才
	// 收尾，否则必须继续给游标——在这里回 null，客户端会把缓存边界当成会话开头，
	// 更早的轮次再也翻不出来，而且不报错，只是历史看起来变短了。
	if end < len(ordered) || !follow.atStart() {
		return page, end, nil
	}
	return page, 0, nil
}

// deepSeekMaxHistoryFetchPages 限制一次请求最多向前取几页记录。
const deepSeekMaxHistoryFetchPages = 8

// deepSeekTurnStartAckTimeout 是等待 Harness 报出 turn 编号的时间。
const deepSeekTurnStartAckTimeout = 5 * time.Second

// deepSeekOffsetCursorPrefix 是本层偏移游标的出处标记。
const deepSeekOffsetCursorPrefix = "ds-offset:"

func deepSeekPageResult(rows []any, nextOffset int) map[string]any {
	// nextCursor 键必须存在（可为 null）：thread/turns/list 缺这个键会让 iOS
	// 把整页判为无效响应，而不是"没有下一页"。
	var next any
	if nextOffset > 0 {
		next = deepSeekOffsetCursorPrefix + strconv.Itoa(nextOffset)
	}
	return map[string]any{
		"data":       rows,
		"nextCursor": next,
	}
}

func deepSeekOffsetCursor(cursor string) (int, bool) {
	value := strings.TrimSpace(cursor)
	if !strings.HasPrefix(value, deepSeekOffsetCursorPrefix) {
		return 0, false
	}
	offset, err := strconv.Atoi(strings.TrimPrefix(value, deepSeekOffsetCursorPrefix))
	if err != nil || offset < 0 {
		return 0, false
	}
	return offset, true
}

func deepSeekSessionPage(sessions []harnessclient.SessionSummary, offset, limit int) ([]harnessclient.SessionSummary, int) {
	if offset >= len(sessions) {
		return nil, 0
	}
	end := offset + limit
	if end > len(sessions) {
		end = len(sessions)
	}
	page := sessions[offset:end]
	if end >= len(sessions) {
		return page, 0
	}
	return page, end
}

// deepSeekListLimit 收敛 thread/list 的 limit。Mimi 侧协议上限是 50。
func deepSeekListLimit(params map[string]any) int {
	limit := gatewayParamInt(params, "limit")
	switch {
	case limit <= 0:
		return 20
	case limit > 50:
		return 50
	default:
		return limit
	}
}

func deepSeekTurnListLimit(params map[string]any) int {
	limit := gatewayParamInt(params, "limit")
	if limit > 200 {
		return 200
	}
	return limit
}

func gatewayCursorParam(params map[string]any) string {
	return gatewayParamString(params, "cursor")
}

func gatewayParamString(params map[string]any, key string) string {
	value, _ := gatewayStringParam(params, key)
	return value
}

func gatewayParamInt(params map[string]any, key string) int {
	value, ok := params[key]
	if !ok {
		return 0
	}
	number, ok := gatewayJSONNumberInt64(value)
	if !ok {
		return 0
	}
	return int(number)
}

// deepSeekTurnNumber 把 Mimi 的 turn id（形如 t3）还原成 Harness 的数字 turn。
func deepSeekTurnNumber(turnID string) (int64, bool) {
	value := strings.TrimSpace(turnID)
	if !strings.HasPrefix(value, "t") {
		return 0, false
	}
	number, err := strconv.ParseInt(strings.TrimPrefix(value, "t"), 10, 64)
	if err != nil {
		return 0, false
	}
	return number, true
}

func deepSeekFrameIntID(raw *json.RawMessage) (int64, bool) {
	if raw == nil {
		return 0, false
	}
	var id int64
	if err := json.Unmarshal(*raw, &id); err != nil {
		return 0, false
	}
	return id, true
}
