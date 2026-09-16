package httpapi

import (
	"encoding/json"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 事件 fixture 一律使用实测形状（字段名来自真实帧），值用可读的占位符。
func durableEvent(t *testing.T, eventType string, data map[string]any) harnessclient.SessionWireEvent {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("构造事件数据失败：%v", err)
	}
	return harnessclient.SessionWireEvent{Type: eventType, Seq: 1, Time: 2, Data: raw}
}

func notificationsByMethod(notifications []deepSeekNotification, method string) []deepSeekNotification {
	var matched []deepSeekNotification
	for _, notification := range notifications {
		if notification.Method == method {
			matched = append(matched, notification)
		}
	}
	return matched
}

// turn/start 与 turn/end 必须翻译成 Mimi 的 turn 生命周期通知，且带 turn.id。
func TestDeepSeekTurnLifecycleTranslatesToTurnNotifications(t *testing.T) {
	started := translateDeepSeekDurableEvent("s-1", durableEvent(t, "turn/start", map[string]any{"turn": 3}))
	if len(started) != 1 || started[0].Method != "turn/started" {
		t.Fatalf("turn/start 翻译不符：%#v", started)
	}
	if started[0].Params["threadId"] != "s-1" {
		t.Fatalf("threadId 不符：%#v", started[0].Params)
	}
	turn, ok := started[0].Params["turn"].(map[string]any)
	if !ok || turn["id"] != "t3" || turn["status"] != "inProgress" {
		t.Fatalf("turn 形状不符：%#v", started[0].Params["turn"])
	}

	cases := []struct {
		reason string
		want   string
	}{
		{"completed", "completed"},
		{"cancelled", "interrupted"},
		{"failed", "failed"},
	}
	for _, tc := range cases {
		notifications := translateDeepSeekDurableEvent("s-1", durableEvent(t, "turn/end", map[string]any{
			"turn":   3,
			"reason": map[string]any{"kind": tc.reason},
		}))
		if len(notifications) != 1 || notifications[0].Method != "turn/completed" {
			t.Fatalf("turn/end(%s) 翻译不符：%#v", tc.reason, notifications)
		}
		completed, _ := notifications[0].Params["turn"].(map[string]any)
		if completed["id"] != "t3" || completed["status"] != tc.want {
			t.Fatalf("结束状态不符（%s）：%#v", tc.reason, completed)
		}
	}
}

// user/message 必须回显 prompt 的 requestId，否则刷新历史后消息会重复。
func TestDeepSeekUserMessageCarriesClientMessageID(t *testing.T) {
	notifications := translateDeepSeekDurableEvent("s-1", durableEvent(t, "user/message", map[string]any{
		"id":      "msg-user-1",
		"role":    "user",
		"content": []map[string]any{{"type": "text", "text": "跑一下夹具"}},
		"source":  map[string]any{"kind": "user", "rpcId": "req-abc"},
	}))
	if len(notifications) != 1 || notifications[0].Method != "item/completed" {
		t.Fatalf("user/message 翻译不符：%#v", notifications)
	}
	params := notifications[0].Params
	if params["clientUserMessageId"] != "req-abc" {
		t.Fatalf("未回显 clientUserMessageId：%#v", params)
	}
	item, _ := params["item"].(map[string]any)
	if item["type"] != "userMessage" || item["id"] != "u:msg-user-1" || item["clientId"] != "req-abc" {
		t.Fatalf("userMessage item 形状不符：%#v", item)
	}
	content, _ := item["content"].([]map[string]any)
	if len(content) != 1 || content[0]["text"] != "跑一下夹具" {
		t.Fatalf("内容不符：%#v", item["content"])
	}
}

// assistant/message 的 item id 用 (turn, step) 合成，不使用 message.id。
func TestDeepSeekAssistantMessageUsesTurnStepItemID(t *testing.T) {
	notifications := translateDeepSeekDurableEvent("s-1", durableEvent(t, "assistant/message", map[string]any{
		"turn": 2,
		"step": 1,
		"message": map[string]any{
			"id":      "any-message-id",
			"role":    "assistant",
			"content": []map[string]any{{"type": "text", "text": "夹具完成"}},
		},
	}))
	if len(notifications) != 1 || notifications[0].Method != "item/completed" {
		t.Fatalf("assistant/message 翻译不符：%#v", notifications)
	}
	item, _ := notifications[0].Params["item"].(map[string]any)
	if item["id"] != "m:2:1" {
		t.Fatalf("assistant item id 应为 (turn,step)：%#v", item)
	}
	if item["text"] != "夹具完成" {
		t.Fatalf("正文不符：%#v", item)
	}
	if notifications[0].Params["turnId"] != "t2" {
		t.Fatalf("turnId 不符：%#v", notifications[0].Params)
	}
}

// 直播增量与落定消息必须共用同一个 item id，否则 Mimi 会显示重复气泡。
func TestDeepSeekStreamingAndCommittedShareItemID(t *testing.T) {
	chunk, err := json.Marshal(map[string]any{"type": "text-delta", "text": "夹具", "index": 0})
	if err != nil {
		t.Fatalf("构造 chunk 失败：%v", err)
	}
	streamed := translateDeepSeekAssistantChunk("s-1", 2, 1, chunk)
	if len(streamed) != 1 || streamed[0].Method != "item/agentMessage/delta" {
		t.Fatalf("text-delta 翻译不符：%#v", streamed)
	}
	committed := translateDeepSeekDurableEvent("s-1", durableEvent(t, "assistant/message", map[string]any{
		"turn": 2,
		"step": 1,
		"message": map[string]any{
			"id":      "different-id-space",
			"content": []map[string]any{{"type": "text", "text": "夹具完成"}},
		},
	}))
	streamedID, _ := streamed[0].Params["itemId"].(string)
	committedItem, _ := committed[0].Params["item"].(map[string]any)
	committedID, _ := committedItem["id"].(string)
	if streamedID == "" || streamedID != committedID {
		t.Fatalf("直播与落定的 item id 不一致：%q vs %q", streamedID, committedID)
	}
	if streamed[0].Params["delta"] != "夹具" {
		t.Fatalf("增量文本不符：%#v", streamed[0].Params)
	}
}

// 只有 text-delta 携带可展示正文；其余片段不得被猜成语义。
func TestDeepSeekAssistantChunkIgnoresNonTextFrames(t *testing.T) {
	frames := []map[string]any{
		{"type": "tool-call-delta", "argumentsDelta": "{\"file_", "index": 0},
		{"type": "block-start", "blockType": "tool-call", "index": 0},
		{"type": "usage", "usage": map[string]any{"inputTokens": 1, "outputTokens": 2}},
		{"type": "finish", "reason": map[string]any{"kind": "end_turn"}},
		{"type": "text-delta", "text": "", "index": 0},
	}
	for _, frame := range frames {
		raw, err := json.Marshal(frame)
		if err != nil {
			t.Fatalf("构造 chunk 失败：%v", err)
		}
		if notifications := translateDeepSeekAssistantChunk("s-1", 1, 1, raw); notifications != nil {
			t.Fatalf("片段 %v 不应产生通知：%#v", frame["type"], notifications)
		}
	}
}

// 标题事件映射到 thread/name/updated。
func TestDeepSeekSessionTitleBecomesThreadNameUpdated(t *testing.T) {
	notifications := translateDeepSeekDurableEvent("s-1", durableEvent(t, "session/title", map[string]any{
		"title":       "夹具会话",
		"source":      map[string]any{"kind": "llm"},
		"messageSeqs": []int{1, 2},
	}))
	if len(notifications) != 1 || notifications[0].Method != "thread/name/updated" {
		t.Fatalf("标题翻译不符：%#v", notifications)
	}
	if notifications[0].Params["threadName"] != "夹具会话" || notifications[0].Params["threadId"] != "s-1" {
		t.Fatalf("标题参数不符：%#v", notifications[0].Params)
	}
}

// 未知事件必须被安全跳过，不能因为上游加了新事件就让连接失败。
func TestDeepSeekUnknownEventIsSkipped(t *testing.T) {
	for _, eventType := range []string{"step/start", "step/end", "request/context", "approval/asked", "brand/new/event"} {
		if notifications := translateDeepSeekDurableEvent("s-1", durableEvent(t, eventType, map[string]any{"turn": 1})); notifications != nil {
			t.Fatalf("事件 %s 不应产生通知：%#v", eventType, notifications)
		}
	}
}

// 审批只用实测存在的字段，不虚构 command / availableDecisions。
func TestDeepSeekApprovalTranslatesWithRealFieldsOnly(t *testing.T) {
	request := harnessclient.WaterfallRequest{
		Type:    "waterfall",
		EventID: "event-approval-1",
		Event:   harnessclient.WaterfallApprovalRequest,
		Request: harnessclient.WaterfallPayload{
			ToolName:      "write",
			CallID:        "call-1",
			Justification: "需要写入工作区外的文件",
		},
	}
	serverRequest, ok := translateDeepSeekWaterfall("s-1", request)
	if !ok {
		t.Fatal("审批应被翻译")
	}
	if serverRequest.Method != "item/commandExecution/requestApproval" {
		t.Fatalf("方法不符：%s", serverRequest.Method)
	}
	for _, key := range []string{"threadId", "itemId", "toolName", "reason", "callId"} {
		if _, present := serverRequest.Params[key]; !present {
			t.Fatalf("缺少字段 %s：%#v", key, serverRequest.Params)
		}
	}
	for _, key := range []string{"command", "cwd", "availableDecisions"} {
		if _, present := serverRequest.Params[key]; present {
			t.Fatalf("不应虚构字段 %s：%#v", key, serverRequest.Params)
		}
	}
}

// 追问要求每个问题都有可回填的 id。
func TestDeepSeekUserQuestionsRequireIDs(t *testing.T) {
	valid := harnessclient.WaterfallRequest{
		EventID: "event-question-1",
		Event:   harnessclient.WaterfallUserQuestions,
		Request: harnessclient.WaterfallPayload{Questions: []harnessclient.Question{{
			ID:       "confirm",
			Question: "继续夹具吗？",
			Options:  []harnessclient.QuestionOption{{Label: "继续"}},
		}}},
	}
	serverRequest, ok := translateDeepSeekWaterfall("s-1", valid)
	if !ok || serverRequest.Method != "item/tool/requestUserInput" {
		t.Fatalf("追问翻译不符：%#v", serverRequest)
	}
	questions, _ := serverRequest.Params["questions"].([]map[string]any)
	if len(questions) != 1 || questions[0]["id"] != "confirm" || questions[0]["question"] != "继续夹具吗？" {
		t.Fatalf("问题形状不符：%#v", serverRequest.Params["questions"])
	}
	if _, present := questions[0]["isSecret"]; present {
		t.Fatal("不应虚构 isSecret 等未验证字段")
	}

	missingID := harnessclient.WaterfallRequest{
		EventID: "event-question-2",
		Event:   harnessclient.WaterfallUserQuestions,
		Request: harnessclient.WaterfallPayload{Questions: []harnessclient.Question{{Question: "无 id"}}},
	}
	if _, ok := translateDeepSeekWaterfall("s-1", missingID); ok {
		t.Fatal("缺少 id 的追问应被拒绝")
	}
}

// 首版不支持的交互必须被忽略而不是硬塞进已有卡片。
func TestDeepSeekUnknownWaterfallIsRejected(t *testing.T) {
	request := harnessclient.WaterfallRequest{EventID: "e-1", Event: "some/future/request"}
	if _, ok := translateDeepSeekWaterfall("s-1", request); ok {
		t.Fatal("未知交互应被拒绝")
	}
}

// 缺字段的事件不能panic，也不能产出半成品通知。
func TestDeepSeekMalformedEventsAreDropped(t *testing.T) {
	malformed := []harnessclient.SessionWireEvent{
		{Type: "turn/start", Data: json.RawMessage(`"not-an-object"`)},
		{Type: "user/message", Data: json.RawMessage(`{}`)},
		{Type: "assistant/message", Data: json.RawMessage(`{"message":{"content":[{"type":"text","text":"   "}]}}`)},
		{Type: "session/title", Data: json.RawMessage(`{"title":""}`)},
	}
	for _, event := range malformed {
		if notifications := translateDeepSeekDurableEvent("s-1", event); notifications != nil {
			t.Fatalf("畸形事件 %s 不应产生通知：%#v", event.Type, notifications)
		}
	}
}
