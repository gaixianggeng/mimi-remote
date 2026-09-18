package httpapi

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件把 Harness 的事件与帧翻译成 Mimi 已消费的 app-server 形状。
//
// 两边协议不同，因此这里是翻译而不是透传：Harness 用数字 turn/step 与自定义事件名，
// Mimi 用字符串 id 与 item/turn 通知。翻译规则全部取自
// docs/deepseek-harness-protocol.md 里标注为"实测"的字段。

// 标识合成。
//
// Harness 的 turn 与 step 都是数字。适配层用 (turn, step) 合成 item 标识，因为
// 这两个字段同时存在于直播的 assistant-stream.start 与持久的 assistant/message、
// tool/call 事件里：同一条消息在直播间与历史回读两条路径上因此会得到同一个 id。
// 这一点必须成立——Mimi 用 id 做原位覆盖，id 不一致会显示重复气泡。
func deepSeekTurnID(turn int64) string {
	return "t" + strconv.FormatInt(turn, 10)
}

func deepSeekMessageItemID(turn, step int64) string {
	return fmt.Sprintf("m:%d:%d", turn, step)
}

// deepSeekNotification 是要下发给移动端的一条 app-server 通知。
type deepSeekNotification struct {
	Method string
	Params map[string]any
}

// deepSeekServerRequest 是要下发给移动端的一条反向请求（审批或追问）。
type deepSeekServerRequest struct {
	Method string
	Params map[string]any
}

// Harness 持久事件名（实测出现过的相关子集）。
const (
	deepSeekEventTurnStart        = "turn/start"
	deepSeekEventTurnEnd          = "turn/end"
	deepSeekEventUserMessage      = "user/message"
	deepSeekEventAssistantMessage = "assistant/message"
	deepSeekEventSessionTitle     = "session/title"
	// deepSeekEventToolCall 只用于建立 callId → 会话的相关性，不产出可见 item。
	deepSeekEventToolCall = "tool/call"
	// deepSeekEventModelSelection 是会话记录的"下一次请求用哪个模型"（含 provider）。
	deepSeekEventModelSelection = "model/selection"
	// deepSeekEventRequestHeader 记录一次请求实际使用的 provider/model。
	deepSeekEventRequestHeader = "request/header"
)

// Harness assistant-stream chunk 的判别值（实测）。
const (
	deepSeekChunkTextDelta  = "text-delta"
	deepSeekStreamBlockText = "text"
)

// assistant-stream 帧的三态。只有 start 带 turn/step，chunk 靠它定位。
const (
	deepSeekStreamFrameStart = "start"
	deepSeekStreamFrameChunk = "chunk"
	deepSeekStreamFrameEnd   = "end"
)

// Mimi item 类型。只使用已确认会被渲染的类型。
const deepSeekItemUserMessage = "userMessage"

const deepSeekItemAgentMessage = "agentMessage"

// deepSeekItemSystemContext 是 Harness 注入上下文（工作区指令/技能目录/运行时快照等）在
// Mimi 端的 item 类型：它不能落在用户气泡里，而应作为 system 侧的折叠上下文呈现。
const deepSeekItemSystemContext = "systemContext"

// deepSeekTurnData 是 turn/start 与 turn/end 的 data。
type deepSeekTurnData struct {
	Turn   int64 `json:"turn"`
	Reason *struct {
		Kind string `json:"kind"`
	} `json:"reason,omitempty"`
}

// deepSeekStepData 是带 turn+step 定位的事件 data。
type deepSeekStepData struct {
	Turn int64 `json:"turn"`
	Step int64 `json:"step"`
}

// deepSeekContentBlock 是消息内容块。实测出现过的字段。
type deepSeekContentBlock struct {
	Type       string `json:"type"`
	Text       string `json:"text"`
	ToolCallID string `json:"toolCallId,omitempty"`
	IsError    bool   `json:"isError,omitempty"`
	Content    []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content,omitempty"`
}

// deepSeekMessageSource 是 user/message 的 source：kind 区分真实用户消息与 Harness
// 注入的上下文（工作区指令/技能目录/运行时快照等），rpcId 是 prompt 的 requestId。
type deepSeekMessageSource struct {
	Kind  string `json:"kind"`
	Form  string `json:"form"`
	RPCID string `json:"rpcId"`
}

// deepSeekMessageData 是 user/message 与 assistant/message 的 data。
type deepSeekMessageData struct {
	Message *struct {
		ID      string                 `json:"id"`
		Role    string                 `json:"role"`
		Content []deepSeekContentBlock `json:"content"`
	} `json:"message,omitempty"`
	// user/message 把消息字段直接放在 data 上。
	ID      string                 `json:"id,omitempty"`
	Content []deepSeekContentBlock `json:"content,omitempty"`
	Source  *deepSeekMessageSource `json:"source,omitempty"`
	Turn    int64                  `json:"turn,omitempty"`
	Step    int64                  `json:"step,omitempty"`
}

// deepSeekTitleData 是 session/title 的 data。
type deepSeekTitleData struct {
	Title string `json:"title"`
}

// deepSeekToolCallData 是 tool/call 的 data。只取实测存在的 callId：
// 交互 waterfall 的会话标识由帧上的 agentId 给出，callId 是复核用的次选判据。
type deepSeekToolCallData struct {
	CallID string `json:"callId,omitempty"`
	Turn   int64  `json:"turn,omitempty"`
	Step   int64  `json:"step,omitempty"`
}

// deepSeekModelSelectionData 是 model/selection 的 data：会话记录下来的
// "下一次请求用哪个模型"。provider 与 model 都是必填（schema 里 min(1)）。
type deepSeekModelSelectionData struct {
	Provider        string `json:"provider,omitempty"`
	Model           string `json:"model,omitempty"`
	ReasoningEffort string `json:"reasoningEffort,omitempty"`
}

// deepSeekRequestHeaderData 是 request/header 的 data：一次请求实际使用的模型配置。
//
// 只取 provider 与 model。刻意不解析 reasoningEffort：Harness 的模型选择投影对它做的是
// `String(...)`，说明该字段可能是数字，而这里用不到它——一个类型不匹配会让整个记录解码
// 失败，连带丢掉本可用的 provider 依据。
type deepSeekRequestHeaderData struct {
	Header struct {
		Config struct {
			Provider string `json:"provider,omitempty"`
			Model    string `json:"model,omitempty"`
		} `json:"config"`
	} `json:"header"`
}

// deepSeekStreamChunk 是 assistant-stream chunk 的载荷。实测判别字段是 Type。
type deepSeekStreamChunk struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

// translateDeepSeekDurableEvent 把一条持久事件翻译成零到多条通知。
//
// 不翻译的事件返回 nil：未知事件必须被安全跳过，不能因为上游加了新事件名就让
// 整条连接失败。
func translateDeepSeekDurableEvent(threadID string, event harnessclient.SessionWireEvent) []deepSeekNotification {
	switch event.Type {
	case deepSeekEventTurnStart:
		var data deepSeekTurnData
		if json.Unmarshal(event.Data, &data) != nil {
			return nil
		}
		return []deepSeekNotification{{
			Method: "turn/started",
			Params: map[string]any{
				"threadId": threadID,
				"turn": map[string]any{
					"id":     deepSeekTurnID(data.Turn),
					"status": "inProgress",
				},
			},
		}}

	case deepSeekEventTurnEnd:
		var data deepSeekTurnData
		if json.Unmarshal(event.Data, &data) != nil {
			return nil
		}
		reason := ""
		if data.Reason != nil {
			reason = data.Reason.Kind
		}
		return []deepSeekNotification{{
			Method: "turn/completed",
			Params: map[string]any{
				"threadId": threadID,
				"turn": map[string]any{
					"id":     deepSeekTurnID(data.Turn),
					"status": deepSeekTurnStatus(reason),
				},
			},
		}}

	case deepSeekEventUserMessage:
		var data deepSeekMessageData
		if json.Unmarshal(event.Data, &data) != nil || strings.TrimSpace(data.ID) == "" {
			return nil
		}
		// Harness 里注入的上下文同样以 role="user" 存储，只有 source.kind 能把它与真实
		// 用户消息区分开。这类内容不能进用户气泡：单独翻译成 systemContext，交给客户端
		// 按 system 侧的折叠上下文渲染。历史路径（deepSeekUserMessageItem）必须同样分流。
		if sourceKind := deepSeekInjectedSourceKind(data.Source); sourceKind != "" {
			item, ok := deepSeekSystemContextItem(data, sourceKind)
			if !ok {
				// 没有正文的注入记录没有可展示内容，落成空行反而会被当成故障。
				return nil
			}
			return []deepSeekNotification{{
				Method: "item/completed",
				Params: map[string]any{
					"threadId": threadID,
					"item":     item,
				},
			}}
		}
		// source.rpcId 是 prompt 的 requestId；回显它客户端才能把乐观提交的消息
		// 与持久消息对上，否则刷新历史后同一条消息会显示两次。
		clientMessageID := ""
		if data.Source != nil {
			clientMessageID = data.Source.RPCID
		}
		item := map[string]any{
			"type":    deepSeekItemUserMessage,
			"id":      "u:" + data.ID,
			"content": deepSeekUserContent(data.Content),
		}
		params := map[string]any{
			"threadId": threadID,
			"item":     item,
		}
		if clientMessageID != "" {
			item["clientId"] = clientMessageID
			params["clientUserMessageId"] = clientMessageID
		}
		return []deepSeekNotification{{Method: "item/completed", Params: params}}

	case deepSeekEventAssistantMessage:
		var data deepSeekMessageData
		if json.Unmarshal(event.Data, &data) != nil {
			return nil
		}
		var content []deepSeekContentBlock
		if data.Message != nil {
			content = data.Message.Content
		} else {
			content = data.Content
		}
		text := deepSeekTextContent(content)
		if strings.TrimSpace(text) == "" {
			// 空正文的 assistant 记录没有可展示内容，Mimi 也会丢弃它。
			return nil
		}
		return []deepSeekNotification{{
			Method: "item/completed",
			Params: map[string]any{
				"threadId": threadID,
				"turnId":   deepSeekTurnID(data.Turn),
				"item": map[string]any{
					"type": deepSeekItemAgentMessage,
					"id":   deepSeekMessageItemID(data.Turn, data.Step),
					"text": text,
				},
			},
		}}

	case deepSeekEventSessionTitle:
		var data deepSeekTitleData
		if json.Unmarshal(event.Data, &data) != nil || strings.TrimSpace(data.Title) == "" {
			return nil
		}
		return []deepSeekNotification{{
			Method: "thread/name/updated",
			Params: map[string]any{
				"threadId":   threadID,
				"threadName": data.Title,
			},
		}}
	}
	return nil
}

// translateDeepSeekAssistantChunk 把一片直播输出翻译成正文增量通知。
//
// 只有 text-delta 携带可展示正文；工具参数增量与块边界不在首版展示范围内，
// 因此返回 nil 而不是猜测语义。
func translateDeepSeekAssistantChunk(threadID string, turn, step int64, chunk json.RawMessage) []deepSeekNotification {
	var decoded deepSeekStreamChunk
	if json.Unmarshal(chunk, &decoded) != nil {
		return nil
	}
	if decoded.Type != deepSeekChunkTextDelta || decoded.Text == "" {
		return nil
	}
	return []deepSeekNotification{{
		Method: "item/agentMessage/delta",
		Params: map[string]any{
			"threadId": threadID,
			"turnId":   deepSeekTurnID(turn),
			"itemId":   deepSeekMessageItemID(turn, step),
			"delta":    decoded.Text,
		},
	}}
}

// translateDeepSeekWaterfall 把 Harness 的交互请求翻译成 Mimi 的反向请求。
//
// 返回的 ok 为 false 表示这是首版不支持的交互，调用方应当忽略并记诊断，
// 而不是把未知形状硬塞进已有的审批卡片。
func translateDeepSeekWaterfall(threadID string, request harnessclient.WaterfallRequest) (deepSeekServerRequest, bool) {
	switch request.Event {
	case harnessclient.WaterfallApprovalRequest:
		// Harness 的审批载荷只有工具名与理由（实测字段 toolName/reason/callId），
		// 没有命令、cwd 或可用决策列表，因此不虚构这些字段。
		params := map[string]any{
			"threadId": threadID,
			"itemId":   request.EventID,
			"toolName": request.Request.ToolName,
			"reason":   request.Request.Justification,
		}
		if request.Request.CallID != "" {
			params["callId"] = request.Request.CallID
		}
		return deepSeekServerRequest{Method: "item/commandExecution/requestApproval", Params: params}, true

	case harnessclient.WaterfallUserQuestions:
		questions := make([]map[string]any, 0, len(request.Request.Questions))
		for _, question := range request.Request.Questions {
			if strings.TrimSpace(question.ID) == "" {
				// 没有 id 的问题无法回填答案，Mimi 侧也会丢弃整条请求。
				return deepSeekServerRequest{}, false
			}
			entry := map[string]any{
				"id":       question.ID,
				"question": question.Question,
			}
			if len(question.Options) > 0 {
				options := make([]map[string]any, 0, len(question.Options))
				for _, option := range question.Options {
					options = append(options, map[string]any{"label": option.Label})
				}
				entry["options"] = options
			}
			questions = append(questions, entry)
		}
		if len(questions) == 0 {
			return deepSeekServerRequest{}, false
		}
		return deepSeekServerRequest{
			Method: "item/tool/requestUserInput",
			Params: map[string]any{
				"threadId":  threadID,
				"itemId":    request.EventID,
				"questions": questions,
			},
		}, true
	}
	return deepSeekServerRequest{}, false
}

// deepSeekTurnStatus 把 Harness 的结束原因映射成 Mimi 的 turn 状态。
//
// Mimi 只在 completed / failed / interrupted 三类里做区分；未知原因按 completed
// 处理会掩盖失败，因此这里只把明确的原因降级，其余归为 completed。
func deepSeekTurnStatus(reasonKind string) string {
	switch strings.ToLower(strings.TrimSpace(reasonKind)) {
	case "completed", "complete", "succeeded", "success":
		return "completed"
	case "failed", "failure", "error", "systemerror", "system_error":
		return "failed"
	case "cancelled", "canceled", "interrupted", "aborted":
		return "interrupted"
	case "":
		return "completed"
	default:
		return "completed"
	}
}

// deepSeekTextContent 把文本内容块拼成一段纯文本并去掉首尾空白。
func deepSeekTextContent(blocks []deepSeekContentBlock) string {
	var builder strings.Builder
	for _, block := range blocks {
		if block.Type != deepSeekStreamBlockText {
			continue
		}
		builder.WriteString(block.Text)
	}
	return strings.TrimSpace(builder.String())
}

// deepSeekInjectedSourceKind 返回 Harness 注入来源的 kind；真实用户消息返回空串。
// source 整体缺失时也返回空串：老记录没有这个字段，只能按用户消息处理。
func deepSeekInjectedSourceKind(source *deepSeekMessageSource) string {
	if source == nil {
		return ""
	}
	kind := strings.TrimSpace(source.Kind)
	if kind == "" || kind == "user" {
		return ""
	}
	return kind
}

// deepSeekSystemContextItem 把注入上下文投影成 systemContext item，直播与历史共用同一形状。
// 正文为空时不可展示：调用方拿到 false 应整条丢弃，不要留一个没有内容的上下文行。
func deepSeekSystemContextItem(data deepSeekMessageData, sourceKind string) (map[string]any, bool) {
	text := deepSeekTextContent(data.Content)
	if text == "" {
		return nil, false
	}
	item := map[string]any{
		"type":       deepSeekItemSystemContext,
		"id":         "c:" + data.ID,
		"text":       text,
		"sourceKind": sourceKind,
	}
	if data.Source != nil {
		if form := strings.TrimSpace(data.Source.Form); form != "" {
			item["sourceForm"] = form
		}
	}
	return item, true
}

// deepSeekUserContent 把用户消息内容块转成 Mimi 的 userMessage content。
func deepSeekUserContent(blocks []deepSeekContentBlock) []map[string]any {
	content := make([]map[string]any, 0, len(blocks))
	for _, block := range blocks {
		if block.Type != deepSeekStreamBlockText {
			continue
		}
		content = append(content, map[string]any{"type": "text", "text": block.Text})
	}
	return content
}
