package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strconv"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件把 Harness 的持久事件记录投影成 Mimi 的 turn / item 形状。
//
// 分页契约（依据 iOS 读取点，见 docs/deepseek-harness-protocol.md 第二节）：
//
//	thread/turns/list → {data: [{id, status, itemsView, items, ...}], nextCursor}
//	thread/items/list → {data: [{turnId, item}], nextCursor}
//
// nextCursor 键必须存在（可为 null），缺失会让整页被判为无效响应。

// deepSeekTurnCursorPrefix 让 cursor 自带出处，便于在日志里分辨是哪条分页链。
// 值本身是 Harness 的 seq：session/page 的 beforeSeq 正是按 seq 前进的。
const deepSeekTurnCursorPrefix = "ds-seq:"

func encodeDeepSeekCursor(seq int64) string {
	if seq <= 0 {
		return ""
	}
	return deepSeekTurnCursorPrefix + base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(seq, 10)))
}

func decodeDeepSeekCursor(cursor string) (int64, bool) {
	value := strings.TrimSpace(cursor)
	if value == "" {
		return 0, false
	}
	if !strings.HasPrefix(value, deepSeekTurnCursorPrefix) {
		// 不认识的 cursor 一律当成"从头开始"，而不是猜一个 seq；
		// 猜错会静默返回错误的一页。
		return 0, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(value, deepSeekTurnCursorPrefix))
	if err != nil {
		return 0, false
	}
	seq, err := strconv.ParseInt(string(raw), 10, 64)
	if err != nil || seq <= 0 {
		return 0, false
	}
	return seq, true
}

// deepSeekTurnStatusFor 把 turn 桶映射成 Mimi 的 turn 状态。
//
// 没有 turn/end 的 turn 如实报 inProgress：Harness 的 turn/end 在异常路径上也会落，
// 因此缺它就是真的没结束。把它报成 completed 会让界面显示一个从未完成的回合。
func deepSeekTurnStatusFor(bucket deepSeekTurnBucket) string {
	if !bucket.Ended {
		return "inProgress"
	}
	return deepSeekTurnStatus(bucket.Reason)
}

// deepSeekTurnItems 把一个 turn 的记录投影成 Mimi item。
//
// 首版只产出 userMessage 与 agentMessage：工具调用的名称与参数 schema 未验证，
// 映射成 commandExecution 或 fileChange 等于虚构语义（见 PR #499 的"刻意不做"）。
func deepSeekTurnItems(bucket deepSeekTurnBucket) []map[string]any {
	items := make([]map[string]any, 0, len(bucket.Records))
	for _, record := range bucket.Records {
		switch record.Type {
		case deepSeekEventUserMessage:
			item, ok := deepSeekUserMessageItem(record.Data)
			if ok {
				items = append(items, item)
			}
		case deepSeekEventAssistantMessage:
			item, ok := deepSeekAgentMessageItem(bucket.Turn, record.Data)
			if ok {
				items = append(items, item)
			}
		}
	}
	return items
}

// deepSeekUserMessageItem 投影一条用户消息。clientId 必须回显，否则 iOS 会整条丢弃。
func deepSeekUserMessageItem(data json.RawMessage) (map[string]any, bool) {
	var decoded deepSeekMessageData
	if json.Unmarshal(data, &decoded) != nil || strings.TrimSpace(decoded.ID) == "" {
		return nil, false
	}
	content := deepSeekUserContent(decoded.Content)
	if len(content) == 0 {
		return nil, false
	}
	item := map[string]any{
		"type":    deepSeekItemUserMessage,
		"id":      "u:" + decoded.ID,
		"content": content,
	}
	if decoded.Source != nil && strings.TrimSpace(decoded.Source.RPCID) != "" {
		item["clientId"] = decoded.Source.RPCID
	}
	return item, true
}

// deepSeekAgentMessageItem 投影一条 Agent 正文。
//
// item id 用 (turn, step) 合成，与直播增量用的是同一套：直播路径的 (turn, step) 来自
// assistant-stream.start，历史路径来自 assistant/message，两者实测都存在。id 一致，
// Mimim 的原位覆盖才成立，否则刷新历史会出现重复气泡。
func deepSeekAgentMessageItem(turn int64, data json.RawMessage) (map[string]any, bool) {
	var decoded deepSeekMessageData
	if json.Unmarshal(data, &decoded) != nil {
		return nil, false
	}
	content := decoded.Content
	if decoded.Message != nil {
		content = decoded.Message.Content
	}
	text := deepSeekAssistantText(content)
	if text == "" {
		return nil, false
	}
	effectiveTurn := turn
	if decoded.Turn != 0 {
		effectiveTurn = decoded.Turn
	}
	return map[string]any{
		"type": deepSeekItemAgentMessage,
		"id":   deepSeekMessageItemID(effectiveTurn, decoded.Step),
		"text": text,
	}, true
}

// deepSeekThreadWire 把一个会话摘要与它的 turn 桶投影成 Mimi 的 thread。
func deepSeekThreadWire(summary harnessclient.SessionSummary, buckets []deepSeekTurnBucket, includeTurns bool) map[string]any {
	thread := map[string]any{
		"id": summary.SessionID,
	}
	if cwd := strings.TrimSpace(summary.CWD); cwd != "" {
		thread["cwd"] = cwd
	}
	// updatedAt 在 Harness 里是毫秒，Mimi 侧两种都接受，这里保留数字原样。
	if summary.UpdatedAt > 0 {
		thread["updatedAt"] = summary.UpdatedAt
	}
	// idle/notLoaded 在 Mimi 里都归成 history；只有确实在跑的会话报 running。
	if summary.Running {
		thread["status"] = "running"
	} else {
		thread["status"] = "notLoaded"
	}
	if summary.Projections != nil {
		title := strings.TrimSpace(summary.Projections.Values.Title)
		if title != "" {
			thread["name"] = title
		}
		if preview := deepSeekTurnOutlinePreview(summary.Projections.Values.TurnOutline); preview != "" {
			thread["preview"] = preview
		}
	}
	if includeTurns {
		turns := make([]any, 0, len(buckets))
		for _, bucket := range buckets {
			turns = append(turns, deepSeekTurnWire(bucket, false))
		}
		thread["turns"] = turns
	}
	return thread
}

// deepSeekTurnWire 投影一个 turn。itemsView 如实反映本页确实带了 items。
func deepSeekTurnWire(bucket deepSeekTurnBucket, includeItems bool) map[string]any {
	turn := map[string]any{
		"id":     deepSeekTurnID(bucket.Turn),
		"status": deepSeekTurnStatusFor(bucket),
	}
	if includeItems {
		items := deepSeekTurnItems(bucket)
		turn["items"] = toDeepSeekAnySlice(items)
		// items 已随本页完整给出，标记 full；否则 iOS 会再逐页请求 items/list。
		turn["itemsView"] = "full"
	} else {
		turn["items"] = []any{}
		turn["itemsView"] = "summary"
	}
	return turn
}

// deepSeekSearchThreadWire 把搜索结果投影成 thread 行。搜索不返回 cwd，
// 目录授权由 gateway 在请求侧完成。
func deepSeekSearchThreadWire(item harnessclient.SessionSearchItem) map[string]any {
	thread := map[string]any{
		"id":     item.SessionID,
		"status": "notLoaded",
	}
	if snippet := strings.TrimSpace(item.Snippet); snippet != "" {
		thread["preview"] = snippet
	}
	return thread
}

func deepSeekTurnOutlinePreview(outline []harnessclient.SessionTurnOutline) string {
	for index := len(outline) - 1; index >= 0; index-- {
		if response := strings.TrimSpace(outline[index].Response); response != "" {
			return response
		}
		if prompt := strings.TrimSpace(outline[index].Prompt); prompt != "" {
			return prompt
		}
	}
	return ""
}

// deepSeekModelListWire 把模型目录投影成 model/list 的 data 行。
//
// 只转发 Harness 自己声明的模型与推理档位：agentd 不按模型名推断供应商，
// 也不替用户选择模型。
func deepSeekModelListWire(catalog harnessclient.ModelCatalogResult) []any {
	rows := make([]any, 0, len(catalog.Groups))
	for _, group := range catalog.Groups {
		for _, model := range group.Models {
			row := map[string]any{
				"id":       model.ID,
				"provider": group.ID,
			}
			if name := firstNonEmpty(model.Name, group.Name); name != "" {
				row["displayName"] = name
			}
			if model.Description != "" {
				row["description"] = model.Description
			}
			if model.Reasoning != nil && len(model.Reasoning.Efforts) > 0 {
				efforts := make([]any, 0, len(model.Reasoning.Efforts))
				for _, effort := range model.Reasoning.Efforts {
					entry := map[string]any{"id": effort.ID}
					if effort.Name != "" {
						entry["name"] = effort.Name
					}
					if effort.Description != "" {
						entry["description"] = effort.Description
					}
					efforts = append(efforts, entry)
				}
				row["reasoningEfforts"] = efforts
				if model.Reasoning.DefaultEffort != "" {
					row["defaultReasoningEffort"] = model.Reasoning.DefaultEffort
				}
			}
			rows = append(rows, row)
		}
	}
	return rows
}

// deepSeekPromptContent 把 app-server 的 input 数组收敛成 Harness 的首版输入。
//
// 只接受纯文本：图片与本地文件需要额外的上传回执与媒体校验，未验证前不下发。
// 遇到非文本输入返回 ok=false，由调用方 fail closed，而不是静默丢弃那一段——
// 静默丢弃会让用户以为附件已经发出去。
func deepSeekPromptContent(raw any) ([]harnessclient.PromptContent, bool) {
	if raw == nil {
		return nil, false
	}
	inputs, ok := raw.([]any)
	if !ok {
		return nil, false
	}
	content := make([]harnessclient.PromptContent, 0, len(inputs))
	for _, entry := range inputs {
		item, ok := entry.(map[string]any)
		if !ok {
			return nil, false
		}
		inputType, _ := gatewayStringParam(item, "type")
		if inputType != "text" {
			return nil, false
		}
		text, ok := gatewayStringParam(item, "text")
		if !ok {
			continue
		}
		content = append(content, harnessclient.PromptContent{Type: "text", Text: text})
	}
	if len(content) == 0 {
		return nil, false
	}
	return content, true
}

// deepSeekPromptForJoin 拼接纯文本输入，用于回显给移动端的乐观消息。
func deepSeekPromptJoin(content []harnessclient.PromptContent) string {
	parts := make([]string, 0, len(content))
	for _, part := range content {
		if strings.TrimSpace(part.Text) != "" {
			parts = append(parts, part.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func toDeepSeekAnySlice(items []map[string]any) []any {
	values := make([]any, 0, len(items))
	for _, item := range items {
		values = append(values, item)
	}
	return values
}

// ensureTurnRecords 保证缓存里含有指定 turn 的记录。
//
// 分页只能向前：从缓存里最老的 seq 继续向 Harness 取，直到拿到这个 turn 或确认已经
// 到会话开头。maxDeepSeekHistoryPages 给出上限，避免一个很旧的 turn 把连接拖在一次
// 请求里无限翻页。
func (c *deepSeekGatewayConn) ensureTurnRecords(ctx context.Context, follow *deepSeekFollow, turn int64) (deepSeekTurnBucket, error) {
	const maxDeepSeekHistoryPages = 8

	if bucket, ok := deepSeekTurnByNumber(follow.snapshot(), turn); ok {
		return bucket, nil
	}
	if follow.atStart() {
		return deepSeekTurnBucket{}, errDeepSeekThreadUnknown
	}
	for page := 0; page < maxDeepSeekHistoryPages; page++ {
		before := follow.oldestCachedSeq()
		if before <= 0 {
			return deepSeekTurnBucket{}, errDeepSeekThreadUnknown
		}
		records, hasMore, err := c.fetchDeepSeekHistoryPage(ctx, follow, before, deepSeekHistoryPageSize)
		if err != nil {
			return deepSeekTurnBucket{}, err
		}
		if len(records) == 0 {
			follow.markReachedStart()
			break
		}
		follow.note(records)
		if bucket, ok := deepSeekTurnByNumber(follow.snapshot(), turn); ok {
			return bucket, nil
		}
		if !hasMore {
			follow.markReachedStart()
			break
		}
	}
	return deepSeekTurnBucket{}, errDeepSeekThreadUnknown
}

// deepSeekHistoryPageSize 是内部翻页的固定页大小，与移动端请求的 limit 无关。
const deepSeekHistoryPageSize = 200

// fetchDeepSeekHistoryPage 取一页历史。beforeSeq 为 0 表示不设下界。
func (c *deepSeekGatewayConn) fetchDeepSeekHistoryPage(
	ctx context.Context,
	follow *deepSeekFollow,
	beforeSeq int64,
	maxMessages int,
) ([]harnessclient.SessionWireEvent, bool, error) {
	request := harnessclient.PageRequest{
		Address:     harnessclient.SessionPath(follow.threadID),
		ThroughSeq:  follow.through(),
		MaxMessages: maxMessages,
	}
	if beforeSeq > 0 {
		request.BeforeSeq = beforeSeq
	}
	result, err := c.harness.PageSession(ctx, request)
	if err != nil {
		return nil, false, err
	}
	records := make([]harnessclient.SessionWireEvent, 0, len(result.Records))
	for _, record := range result.Records {
		records = append(records, record.Wire())
	}
	return records, result.HasMore, nil
}
