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
// 首版只产出 userMessage、agentMessage 与 systemContext：工具调用的名称与参数 schema
// 未验证，映射成 commandExecution 或 fileChange 等于虚构语义（见 PR #499 的"刻意不做"）。
// systemContext 承载 Harness 注入的上下文，与直播路径共用 deepSeekSystemContextItem。
//
// item 一律带上记录自带的 time（毫秒）。Harness 的 item 里没有时间字段，历史页也只在
// turn 层给起止时间；不把记录时间透传出去，客户端就只能把整段历史兜底成"没有时间"，
// 实测退化成 epoch 并显示成 01/01 08:00，同一条消息也无法与直播副本按时间对齐。
func deepSeekTurnItems(bucket deepSeekTurnBucket) []map[string]any {
	items := make([]map[string]any, 0, len(bucket.Records))
	for _, record := range bucket.Records {
		switch record.Type {
		case deepSeekEventUserMessage:
			item, ok := deepSeekUserMessageItem(record.Data, record.Time)
			if ok {
				items = append(items, item)
			}
		case deepSeekEventAssistantMessage:
			item, ok := deepSeekAgentMessageItem(bucket.Turn, record.Data, record.Time)
			if ok {
				items = append(items, item)
			}
		}
	}
	return items
}

// deepSeekUserMessageItem 投影一条用户消息。clientId 必须回显，否则 iOS 会整条丢弃。
//
// Harness 注入的上下文同样落在 user/message 里，只有 source.kind 能把它与真实用户消息
// 区分开。历史必须与直播给出同一套语义，否则刷新历史后这些内容会重新回到用户气泡。
func deepSeekUserMessageItem(data json.RawMessage, time int64) (map[string]any, bool) {
	var decoded deepSeekMessageData
	if json.Unmarshal(data, &decoded) != nil || strings.TrimSpace(decoded.ID) == "" {
		return nil, false
	}
	if sourceKind := deepSeekInjectedSourceKind(decoded.Source); sourceKind != "" {
		return deepSeekSystemContextItem(decoded, sourceKind, time)
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
	deepSeekAttachItemTime(item, time)
	return item, true
}

// deepSeekAgentMessageItem 投影一条 Agent 正文。
//
// item id 用 (turn, step) 合成，与直播增量用的是同一套：直播路径的 (turn, step) 来自
// assistant-stream.start，历史路径来自 assistant/message，两者实测都存在。id 一致，
// Mimim 的原位覆盖才成立，否则刷新历史会出现重复气泡。
func deepSeekAgentMessageItem(turn int64, data json.RawMessage, time int64) (map[string]any, bool) {
	var decoded deepSeekMessageData
	if json.Unmarshal(data, &decoded) != nil {
		return nil, false
	}
	content := decoded.Content
	if decoded.Message != nil {
		content = decoded.Message.Content
	}
	text := deepSeekTextContent(content)
	if text == "" {
		return nil, false
	}
	effectiveTurn := turn
	if decoded.Turn != 0 {
		effectiveTurn = decoded.Turn
	}
	item := map[string]any{
		"type": deepSeekItemAgentMessage,
		"id":   deepSeekMessageItemID(effectiveTurn, decoded.Step),
		"text": text,
	}
	deepSeekAttachItemTime(item, time)
	return item, true
}

// deepSeekAttachItemTime 把记录时间写进 item。
//
// 键名沿用 Mimi 历史读取点认得的 createdAt；单位是 Harness 原样的毫秒，
// 客户端按数量级同时接受秒与毫秒，不做换算以免引入 1000 倍偏差。
// time 为 0 表示记录没带时间：此时不写字段，让客户端按"无时间"处理，
// 而不是塞一个 1970 让它看起来像真时间。
func deepSeekAttachItemTime(item map[string]any, time int64) {
	if time > 0 {
		item["createdAt"] = time
	}
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

// deepSeekTurnWire 投影一个 turn。itemsView 如实反映本页是否带了这一轮的完整 items。
//
// 只有确实见过这个 turn 的 turn/start 才敢标 full：iOS 见到 full 就不再请求
// items/list，一个被分页切掉开头的 turn 会因此以"只有 turn/end、没有正文"的样子
// 定稿——它看起来是完整的一轮，实际少了一整轮内容，而且不报错。
//
// startedAt / completedAt 取记录自带的时间（毫秒）。客户端读 turn 级时间作为 item 的
// 兜底：缺它时整轮历史会退化成"没有时间"，实测显示成 01/01 08:00。两个字段都只是
// 有则给出，缺一部分就少写一部分，不补 0。
func deepSeekTurnWire(bucket deepSeekTurnBucket, includeItems bool) map[string]any {
	turn := map[string]any{
		"id":     deepSeekTurnID(bucket.Turn),
		"status": deepSeekTurnStatusFor(bucket),
	}
	if bucket.StartedAt > 0 {
		turn["startedAt"] = bucket.StartedAt
	}
	if bucket.EndedAt > 0 {
		turn["completedAt"] = bucket.EndedAt
	}
	if includeItems && bucket.Started {
		items := deepSeekTurnItems(bucket)
		turn["items"] = toDeepSeekAnySlice(items)
		turn["itemsView"] = "full"
	} else {
		// summary 让 iOS 继续逐 turn 请求 items/list，那条路径会把缺的历史补回来。
		turn["items"] = []any{}
		turn["itemsView"] = "summary"
	}
	return turn
}

// deepSeekSearchRowWire 投影一行搜索结果。
//
// 形状必须是 {thread: {...}, snippet}：iOS 的 threadSearchPage 逐行解这两个键，
// 缺任一项会抛 invalidResponse 让整页搜索失败。
//
// thread 里必须带 cwd，它同时承担两件事：iOS 据此确定会话归属目录；
// policy 的响应侧裁剪（sanitizeThreadSearchResponse）以它为唯一判据决定这行
// 能不能下发。Harness 的检索结果本身不带 cwd，因此调用方要先从 session/list
// 的摘要把它补回来——补不出 cwd 的行如实丢弃，而不是塞一个默认目录。
func deepSeekSearchRowWire(session harnessclient.SessionSummary, snippet string) (map[string]any, bool) {
	if strings.TrimSpace(session.SessionID) == "" || strings.TrimSpace(session.CWD) == "" {
		return nil, false
	}
	return map[string]any{
		"thread":  deepSeekThreadWire(session, nil, false),
		"snippet": snippet,
	}, true
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
				// 使用 Mimi model/list 的标准字段，避免 iOS 目录解析丢失真实档位。
				row["supportedReasoningEfforts"] = efforts
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

// ensureTurnRecords 保证缓存里含有指定 turn 的完整记录。
//
// 分页只能向前：从缓存里最老的 seq 继续向 Harness 取，直到拿到这个 turn 或确认已经
// 到会话开头。deepSeekMaxHistoryFetchPages 给出上限，避免一个很旧的 turn 把连接拖在一次
// 请求里无限翻页。
func (c *deepSeekGatewayConn) ensureTurnRecords(ctx context.Context, follow *deepSeekFollow, turn int64) (deepSeekTurnBucket, error) {
	// 缓存里有这个 turn 还不够：桶可能被分页切掉了开头（Started=false），那里面只剩
	// 一条 turn/end，内容整个缺着。当成答案返回会把"少了整整一轮正文"的 turn 定稿。
	if bucket, ok := deepSeekTurnByNumber(follow.snapshot(), turn); ok && bucket.Started {
		return bucket, nil
	}
	if follow.atStart() {
		return deepSeekTurnBucket{}, errDeepSeekThreadUnknown
	}
	for page := 0; page < deepSeekMaxHistoryFetchPages; page++ {
		if err := c.readEarlierDeepSeekHistory(ctx, follow); err != nil {
			return deepSeekTurnBucket{}, err
		}
		if bucket, ok := deepSeekTurnByNumber(follow.snapshot(), turn); ok && bucket.Started {
			return bucket, nil
		}
		if follow.atStart() {
			break
		}
	}
	// 补不全就如实报"取不到"，让客户端重试。把残缺的桶当答案返回，用户会以为这一轮
	// 本来就没有内容。
	return deepSeekTurnBucket{}, errDeepSeekThreadUnknown
}

// readEarlierDeepSeekHistory 统一维护缓存的读取进度与结束标记。
// hasMore=true 的空页或重复页不能被认作会话开头，否则另一条读取路径也会丢失历史。
func (c *deepSeekGatewayConn) readEarlierDeepSeekHistory(ctx context.Context, follow *deepSeekFollow) error {
	before := follow.oldestCachedSeq()
	records, hasMore, err := c.fetchDeepSeekHistoryPage(ctx, follow, before, deepSeekHistoryPageSize)
	if err != nil {
		return err
	}
	if len(records) == 0 && hasMore {
		return errDeepSeekHistoryPagingStalled
	}
	follow.note(records)
	if !hasMore {
		follow.markReachedStart()
		return nil
	}
	after := follow.oldestCachedSeq()
	if (before > 0 && after >= before) || (before <= 0 && after <= 0) {
		return errDeepSeekHistoryPagingStalled
	}
	return nil
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
