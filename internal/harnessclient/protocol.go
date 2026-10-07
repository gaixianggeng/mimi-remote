// Package harnessclient 是 agentd 连接 DeepSeek Harness 本地服务的薄客户端。
//
// 职责边界：只做认证、HTTP Connection RPC 封装和 remote.mux 事件流订阅，不包含
// 任何到 Mimi app-server 协议的转换（那份映射在 internal/httpapi 的 DeepSeek gateway）。
// 这样协议事实可以单独测试，不需要真的跑一个 Harness。
//
// 报文形状取自 #492 固定的 Harness 0.1.5-rc.2 及其实验程序，属于已验证事实：
//
//   - 认证：GET /?token=<启动 token> 返回 303 并下发绑定 hostname+port 的 Cookie。
//     普通 API 不接受 Authorization 头，无 Cookie 为 401。
//   - RPC：POST /api/<method>，body 为 client-request 外壳，业务结果在 result 里，
//     必须检查 result.ok —— 只用 API Gateway 文档的 {args:...} 会拿到 gateway/bad-request，
//     即使 HTTP 状态码是 200。
//   - 事件：WebSocket /api/remote.mux，客户端发 open 帧声明 streamId 与 endpoint，
//     服务端帧带同一个 streamId。
//   - 反向交互：POST /api/$events/result，带 clientId、eventId 和 outcome。
//
// 凭据纪律：启动 token 只在 Authenticate 里使用一次，换到的 Cookie 只留在本进程内存。
// 两者都不写日志、不进配置文件、不下发给移动端。
package harnessclient

import (
	"encoding/json"
	"fmt"
	"strings"
)

// Remote 方法名。登记的是原生通道（/api/harness/rpc 与 /api/harness/ws）实际使用的方法集，
// 也是 `internal/httpapi` 授权策略 `harnessNativeCWDScopedMethods` 等处的依据；
// 新增方法必须同时改这两处，否则要么移动端拿不到能力，要么声明了用不了的方法。
const (
	MethodSessionList         = "session/list"
	MethodSessionSearch       = "session/search"
	MethodSessionCreate       = "session/create"
	MethodSessionPage         = "session/page"
	MethodSessionFollow       = "session/follow"
	MethodSessionPrompt       = "session/prompt"
	MethodSessionCancel       = "session/cancel"
	MethodSessionModelCatalog = "session/modelCatalog"
	MethodSessionSelectModel  = "session/selectModel"
)

// Remote 的 stream endpoint。
const (
	EndpointEvents       = "$events"
	EndpointEventsResult = "$events/result"
)

// remote.mux 帧类型。durable event 与 assistant-stream 是分开的两类：
// 前者是会话持久事件，后者是直播输出片段，收尾时归并到持久 assistant 记录。
const (
	FrameReady           = "ready"
	FrameSnapshot        = "snapshot"
	FrameWaterfall       = "waterfall"
	FrameCancel          = "cancel"
	FrameAssistantStream = "assistant-stream"
	FrameDurableEvent    = "event"
)

// 载体层判别值。服务端**每帧**都在顶层带 type，取值只有这三个
// （`stream/mux-carrier.json` 的 server.item / server.error / server.end）。
//
// 它与 value 内部的判别式（ready/snapshot/waterfall/…）不是同一层：
// item 的 value 里才有内层判别式，error/end 根本没有 value。
// 把两层混为一谈正是契约 §8 缺陷 2 的成因。
const (
	CarrierItem  = "item"
	CarrierError = "error"
	CarrierEnd   = "end"
)

// FrameCarrierError 与 FrameCarrierEnd 是载体层事件在 StreamValue.Type 上的表示。
//
// 它们不是服务端 value 里的类型名，而是把「载体说了什么」抬进同一套判别式，
// 让上层可以用一个 switch 处理完整条链路。取与 wire 不同的字面量是刻意的：
// 万一将来服务端真的发出内层 type 为 "error" 的 value，两者不会互相冒充。
const (
	FrameCarrierError = "carrier-error"
	FrameCarrierEnd   = "carrier-end"
)

// waterfall 事件名。Harness 只经这两条 waterfall 向客户端发起交互。
const (
	WaterfallApprovalRequest = "approval/request"
	WaterfallUserQuestions   = "user-questions/request"
)

// 审批应答取值，对齐 Harness 的 result outcome。
const (
	OutcomeAllowedOnce = "allowed-once"
	OutcomeRejected    = "rejected"
	OutcomeCancelled   = "cancelled"
	OutcomeUnavailable = "unavailable"
)

// clientRequest 是 Connection RPC 的请求外壳。裸 {args:...} 会被服务端判为
// gateway/bad-request，即使 HTTP 200。
type clientRequest struct {
	Type    string         `json:"type"`
	RPCID   string         `json:"rpcId"`
	Method  string         `json:"method"`
	Payload requestPayload `json:"payload"`
}

type requestPayload struct {
	Args any `json:"args"`
}

// serverResponse 是 Connection RPC 的响应外壳。业务结果一律在 result 里，
// 必须检查 result.ok，不能只看 HTTP 状态码。
type serverResponse struct {
	Type   string          `json:"type"`
	RPCID  string          `json:"rpcId"`
	Result *resultEnvelope `json:"result"`
}

type resultEnvelope struct {
	OK    bool            `json:"ok"`
	Value json.RawMessage `json:"value"`
	Error *RemoteError    `json:"error"`
}

// RemoteError 是 Harness 侧返回的业务错误。
//
// 第三个字段的 wire 名是 "details"，不是 "data"——这是实跑核对过的：隔离环境里
// 触发 gateway/arguments-invalid 与 session/agent-busy 时，错误对象都是
// {code, message, details}。按 "data" 解码会静默丢掉这一项。
type RemoteError struct {
	Code    string          `json:"code,omitempty"`
	Message string          `json:"message,omitempty"`
	Details json.RawMessage `json:"details,omitempty"`
}

func (e *RemoteError) Error() string {
	if e == nil {
		return ""
	}
	code := e.Code
	if code == "" {
		code = "error"
	}
	if e.Message == "" {
		return code
	}
	return fmt.Sprintf("%s: %s", code, e.Message)
}

// openFrame 是客户端在 remote.mux 上声明一条订阅流。
type openFrame struct {
	Type     string `json:"type"`
	StreamID string `json:"streamId"`
	Endpoint string `json:"endpoint"`
	Payload  struct {
		Args any `json:"args"`
	} `json:"payload"`
}

// muxFrame 是 remote.mux 上收到的帧。
//
// 三个键都是**载体层**字段：type 是服务端的判别值（item/error/end），
// streamId 把帧归到对应订阅，item 的 value 结构由 value.type 决定（保持
// RawMessage 由上层按类型解码）。
//
// 契约 §8 缺陷 2：旧实现只有 {streamId,value} 两个键，于是服务端的顶层 type 被
// 整个丢掉。error/end 帧没有 value，就被当成空帧推入通道——流级错误因此只能
// 表现为上层超时，而超时无法区分「对端报错」与「对端只是没说话」。
type muxFrame struct {
	Type     string          `json:"type,omitempty"`
	StreamID string          `json:"streamId,omitempty"`
	Value    json.RawMessage `json:"value,omitempty"`
	// Error 仅在 type 为 error 时存在。形状与 RemoteError 一致（code/message/details）。
	Error *RemoteError `json:"error,omitempty"`
}

// valueType 只解出帧的判别字段，避免两次完整解码。
type valueType struct {
	Type string `json:"type,omitempty"`
	// event 存在时说明这是 durable event 信封，真正的判别字段在 event.type。
	Event *struct {
		Type string `json:"type,omitempty"`
	} `json:"event,omitempty"`
}

// StreamValue 是 remote.mux 上一帧的判别结果。
type StreamValue struct {
	// Type 是顶层类型：ready、snapshot、waterfall、cancel、assistant-stream、event；
	// 以及载体层的 carrier-error、carrier-end（见 FrameCarrierError / FrameCarrierEnd）。
	Type string
	// EventType 仅在 Type 为 event 时给出 durable event 类型，例如 turn/start、turn/end。
	EventType string
	// Raw 是原始 value，供上层按类型解码。载体为 error/end 时为空。
	Raw json.RawMessage
	// CarrierType 是服务端的载体层判别值：item / error / end。
	// 上层据此区分「载体级故障」与「业务帧」。
	CarrierType string
	// CarrierError 仅在 CarrierType 为 error 时给出，是流级错误的真实原因。
	CarrierError *RemoteError
}

// CarrierFailure 报告这一帧是否是载体层错误，并返回该错误。
//
// 上层必须显式处理它：契约要求流级错误不能被降级成「没有帧」，
// 否则一次上游报错会伪装成一次静默超时。
func (v StreamValue) CarrierFailure() (*RemoteError, bool) {
	if v.CarrierType != CarrierError {
		return nil, false
	}
	if v.CarrierError == nil {
		// 服务端声明了 error 却没带 error 对象。不能当成成功，也不能当成空错误：
		// 合成一个明确的 code，让上层至少有可诊断的失败。
		return &RemoteError{Code: "gateway/internal", Message: "载体错误帧缺少 error 对象"}, true
	}
	return v.CarrierError, true
}

// IsCarrierEnd 报告服务端是否宣告了这条订阅的结束。
func (v StreamValue) IsCarrierEnd() bool {
	return v.CarrierType == CarrierEnd
}

// WaterfallRequest 是需要客户端应答的交互请求。审批与用户追问共用这一层信封，
// 用 Event 字段区分。上层据此合成 app-server 的反向请求。
//
// 会话归属：waterfall 走的是宿主级通道，但它**不是**无身份的。api-gateway
// 0.1.5-rc.2 构造帧时固定填 agentId（见 stream-protocol.ts 的 RemoteEventInvocationFrame：
// agentId 是必填字段，startRemoteEvent 对空值直接抛错），而 Harness 的身份设计是
// "agent 的注册表 id 等于其会话 id"（.agents/notes/implemented/simplification/
// 2026-06-20-unify-agent-and-session-id），因此 agentId 就是会话标识。
//
// 这一条把归属从推断变成了核事实。此前没有解析该字段，才不得不用 callId 映射乃至
// "唯一活跃会话"这类旁证去猜；那些旁证仍然保留为次选，但不再是唯一依据。
type WaterfallRequest struct {
	Type    string           `json:"type"`
	EventID string           `json:"eventId"`
	Event   string           `json:"event"`
	Request WaterfallPayload `json:"request"`
	// AgentID 是帧里的 Agent 身份，等于会话 id。生产帧必然存在。
	AgentID string `json:"agentId,omitempty"`
	// 候选的会话标识键，任一命中即采用。
	SessionID string `json:"sessionId,omitempty"`
	ThreadID  string `json:"threadId,omitempty"`
	// Session 与 Address 是嵌套形态的候选。
	Session *struct {
		SessionID string `json:"sessionId,omitempty"`
		ID        string `json:"id,omitempty"`
	} `json:"session,omitempty"`
	Address *struct {
		SessionID string `json:"sessionId,omitempty"`
	} `json:"address,omitempty"`
}

// ThreadHint 返回 waterfall 帧里能确认的会话标识，取不到时为空串。
//
// agentId 排在最前：它是协议保证存在的字段，也是唯一由上游直接给出的会话标识。
// 其余候选键是不同版本/不同形态的兼容入口，取不到时上层必须按"未知归属"处理，
// 不能猜一个会话塞进去。
func (w WaterfallRequest) ThreadHint() string {
	for _, candidate := range []string{w.AgentID, w.ThreadID, w.SessionID} {
		if strings.TrimSpace(candidate) != "" {
			return strings.TrimSpace(candidate)
		}
	}
	if w.Session != nil {
		for _, candidate := range []string{w.Session.SessionID, w.Session.ID} {
			if strings.TrimSpace(candidate) != "" {
				return strings.TrimSpace(candidate)
			}
		}
	}
	if w.Address != nil && strings.TrimSpace(w.Address.SessionID) != "" {
		return strings.TrimSpace(w.Address.SessionID)
	}
	return ""
}

// WaterfallPayload 是交互请求的载荷。审批只填工具名与理由，追问带结构化问题。
type WaterfallPayload struct {
	// 审批
	ToolName      string `json:"toolName,omitempty"`
	CallID        string `json:"callId,omitempty"`
	Justification string `json:"reason,omitempty"`
	// 用户追问
	Questions []Question `json:"questions,omitempty"`
}

// Question 是结构化追问。答案必须按 id 回填，不能把自然语言回复伪装成答案。
type Question struct {
	ID       string           `json:"id"`
	Question string           `json:"question,omitempty"`
	Options  []QuestionOption `json:"options,omitempty"`
}

type QuestionOption struct {
	Label string `json:"label"`
}

// Answer 是单条追问的应答。
type Answer struct {
	ID       string   `json:"id"`
	Selected []string `json:"selected,omitempty"`
}
