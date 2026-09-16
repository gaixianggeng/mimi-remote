package harnessclient

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// newRequestID 生成一次 prompt 的幂等标识。
//
// Harness 按 requestId 去重：同一个已进入 inbox 或持久 user/message 的 requestId
// 重试不会再插入，因此移动端重发必须复用同一个 requestId，不能每次重新生成。
func newRequestID() string {
	var buffer [16]byte
	if _, err := rand.Read(buffer[:]); err != nil {
		// 随机源不可用时不静默退回可预测值，直接暴露出来由上层失败。
		panic("harnessclient: 无法生成 requestId：" + err.Error())
	}
	return "req_" + hex.EncodeToString(buffer[:])
}

// NewRequestID 供上层在重试时复用同一个标识。
func NewRequestID() string { return newRequestID() }

// SessionAddress 定位一个会话。subagent 形态首版不开放。
type SessionAddress struct {
	Kind      string `json:"kind"`
	SessionID string `json:"sessionId"`
}

// SessionListRequest 是 session/list 的参数。
//
// wire 参数名是 "_request" 而不是 "request"：Harness 侧该参数在实现里未被使用，
// 生成代码保留了带下划线的形参名，网关按描述符逐字校验参数名与个数
// （多一个或少一个都报 gateway/arguments-invalid），因此这里必须原样保留下划线。
type SessionListRequest struct {
	Cursor string `json:"cursor,omitempty"`
}

// SessionSummary 是会话列表里的一项。
//
// Harness 的 session/list 不按目录过滤（请求体里没有 cwd），返回的是本机可见的
// 全部会话，因此按授权工作区裁剪是 agentd 的责任，不能指望上游过滤。
type SessionSummary struct {
	SessionID string `json:"sessionId"`
	// UpdatedAt 是毫秒时间戳，用于 Mimi 侧排序与"最近"展示。
	UpdatedAt int64 `json:"updatedAt"`
	// Running 表示该会话的 Agent 当前是否在跑，映射到 thread 的 active 状态。
	Running bool `json:"running"`
	// Blank 表示还没有任何轮次，Mimi 侧据此隐藏空会话。
	Blank bool   `json:"blank"`
	CWD   string `json:"cwd,omitempty"`
	// Projections 是可选投影；冷会话也可能带标题与轮次大纲。
	Projections *SessionProjectionHints `json:"projections,omitempty"`
}

// SessionProjectionHints 是列表行携带的投影快照。values 字段集与 Harness 版本相关，
// 只声明 Mimi 真正消费的部分。
type SessionProjectionHints struct {
	AsOfSeq int64                  `json:"asOfSeq"`
	Values  SessionProjectionValue `json:"values"`
}

// SessionProjectionValue 只建模已确认存在的投影键。
type SessionProjectionValue struct {
	// Title 是 Harness 自己生成的会话标题，映射到 thread 名称。
	Title string `json:"title,omitempty"`
	// TurnOutline 是逐轮的首末摘录，用作会话预览。
	TurnOutline []SessionTurnOutline `json:"turnOutline,omitempty"`
	// ModelSelection 记录该会话已用/待用的模型选择。
	ModelSelection *SessionModelSelectionState `json:"modelSelection,omitempty"`
}

// SessionTurnOutline 是一轮的摘要摘录。
type SessionTurnOutline struct {
	Prompt   string `json:"prompt,omitempty"`
	Response string `json:"response,omitempty"`
	Seq      int64  `json:"seq"`
	Turn     int64  `json:"turn"`
}

// SessionModelSelectionState 是会话的模型选择投影。
type SessionModelSelectionState struct {
	LastUsed *ModelSelection `json:"lastUsed,omitempty"`
	Next     *ModelSelection `json:"next,omitempty"`
}

// ModelSelection 是一次完整的模型选择。
type ModelSelection struct {
	Provider        string `json:"provider"`
	Model           string `json:"model"`
	ReasoningEffort string `json:"reasoningEffort,omitempty"`
}

// SessionListResult 是 session/list 的响应体。
type SessionListResult struct {
	Items []SessionSummary `json:"items"`
}

// SessionSearchRequest 是 session/search 的参数。
type SessionSearchRequest struct {
	Query string `json:"query"`
}

// SessionSearchItem 是搜索结果的一项。
type SessionSearchItem struct {
	SessionID string `json:"sessionId"`
	Snippet   string `json:"snippet"`
}

// SessionSearchResult 是 session/search 的响应体。
type SessionSearchResult struct {
	Items   []SessionSearchItem `json:"items"`
	HasMore bool                `json:"hasMore"`
}

// CreateSessionRequest 新建会话。cwd 必须已经过 agentd 的工作区授权。
type CreateSessionRequest struct {
	CWD         string `json:"cwd,omitempty"`
	WorkspaceID string `json:"workspaceId,omitempty"`
	SessionID   string `json:"sessionId,omitempty"`
	AgentPreset string `json:"agentPreset,omitempty"`
}

// CreateSessionResult 返回新会话标识。
type CreateSessionResult struct {
	SessionID   string `json:"sessionId"`
	AgentPreset string `json:"agentPreset,omitempty"`
}

// SelectModelRequest 只转发模型选择，不维护供应商配置。
type SelectModelRequest struct {
	SessionID string `json:"sessionId"`
	Provider  string `json:"provider"`
	Model     string `json:"model"`
}

// FollowRequest 订阅一个会话。assistantStream 打开直播输出片段。
type FollowRequest struct {
	Address         SessionAddress `json:"address"`
	MaxMessages     int            `json:"maxMessages,omitempty"`
	AssistantStream bool           `json:"assistantStream,omitempty"`
}

// PromptContent 是一条输入内容。首版只开放纯文本：图片与文件附件需要额外的
// 上传回执与媒体边界校验，未验证前不下发。
type PromptContent struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

// PromptRequest 向会话投递一次输入。
//
// 首版固定 Mode=queue：Harness 的 steer 与 queue 语义不同，且未经验证，
// 不通过移动端暴露。
type PromptRequest struct {
	SessionID string          `json:"sessionId"`
	RequestID string          `json:"requestId"`
	Mode      string          `json:"mode,omitempty"`
	Content   []PromptContent `json:"content"`
}

// CancelRequest 取消会话当前共享轮次。
type CancelRequest struct {
	SessionID string `json:"sessionId"`
}

// PageRequest 取会话的一页历史。
//
// ThroughSeq 是必填：它必须是本次 follow 开场 snapshot 给出的 cursor，
// 表示"读到哪个日志切点"。省略会被网关判为输入非法。
type PageRequest struct {
	Address     SessionAddress `json:"address"`
	ThroughSeq  int64          `json:"throughSeq"`
	BeforeSeq   int64          `json:"beforeSeq,omitempty"`
	MaxMessages int            `json:"maxMessages,omitempty"`
}

// SessionHistoryRecord 是历史页里的一条持久事件记录。
type SessionHistoryRecord struct {
	Type  string           `json:"type"`
	Event SessionWireEvent `json:"event"`
}

// SessionWireEvent 是持久事件信封。data 结构由 type 决定，交给上层按类型解码。
type SessionWireEvent struct {
	Type string          `json:"type"`
	Seq  int64           `json:"seq"`
	Time int64           `json:"time"`
	Data json.RawMessage `json:"data,omitempty"`
	// Ignorable 标记该事件可被不认识它的消费者安全跳过。
	Ignorable bool `json:"ignorable,omitempty"`
}

// SessionPageResult 是 session/page 的响应体。
type SessionPageResult struct {
	Records []SessionHistoryRecord `json:"records"`
	HasMore bool                   `json:"hasMore"`
}

// ModelEntry 是模型目录里的一项。Mimi 只消费并转发，不判断供应商归属。
type ModelEntry struct {
	ID          string          `json:"id"`
	Name        string          `json:"name,omitempty"`
	Description string          `json:"description,omitempty"`
	Reasoning   *ModelReasoning `json:"reasoning,omitempty"`
}

// ModelReasoning 是该模型真正声明的推理档位。
type ModelReasoning struct {
	Efforts       []ModelReasoningEffort `json:"efforts,omitempty"`
	DefaultEffort string                 `json:"defaultEffort,omitempty"`
}

// ModelReasoningEffort 是一个可选的推理档位。
type ModelReasoningEffort struct {
	ID          string `json:"id"`
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
}

// ModelCatalogGroup 是按 provider 分组的目录。
type ModelCatalogGroup struct {
	ID     string       `json:"id"`
	Name   string       `json:"name,omitempty"`
	Models []ModelEntry `json:"models"`
}

// ModelCatalogFailure 是某个 provider 目录加载失败的记录。
type ModelCatalogFailure struct {
	ID      string `json:"id"`
	Name    string `json:"name,omitempty"`
	Message string `json:"message,omitempty"`
}

// ModelCatalogResult 是模型目录响应。
type ModelCatalogResult struct {
	Default           ModelSelection        `json:"default"`
	RoutableProviders []string              `json:"routableProviders,omitempty"`
	Groups            []ModelCatalogGroup   `json:"groups"`
	Failures          []ModelCatalogFailure `json:"failures,omitempty"`
}

// ListSessions 列出持久会话。列表不会因为被读取而激活全部 Agent，
// 因此这里必须由上层按授权工作区裁剪。
func (c *Client) ListSessions(ctx context.Context, request SessionListRequest) ([]SessionSummary, error) {
	// 参数名必须是 "_request"，见 SessionListRequest 的说明。
	var result SessionListResult
	if err := c.Call(ctx, MethodSessionList, map[string]any{"_request": request}, &result); err != nil {
		return nil, err
	}
	return result.Items, nil
}

// SearchSessions 按关键词搜索会话内容。
//
// 该能力依赖部署侧的会话检索索引（session-query）配置；未开启时 Harness 返回
// gateway/internal，上层必须降级而不是把它当成致命错误。
func (c *Client) SearchSessions(ctx context.Context, query string) (SessionSearchResult, error) {
	var result SessionSearchResult
	args := map[string]any{"request": SessionSearchRequest{Query: query}}
	if err := c.Call(ctx, MethodSessionSearch, args, &result); err != nil {
		return SessionSearchResult{}, err
	}
	return result, nil
}

// CreateSession 新建会话。
func (c *Client) CreateSession(ctx context.Context, request CreateSessionRequest) (CreateSessionResult, error) {
	var result CreateSessionResult
	args := map[string]any{"request": request}
	if err := c.Call(ctx, MethodSessionCreate, args, &result); err != nil {
		return CreateSessionResult{}, err
	}
	if strings.TrimSpace(result.SessionID) == "" {
		return CreateSessionResult{}, errors.New("harnessclient: session/create 未返回 sessionId")
	}
	return result, nil
}

// PageSession 取一页历史。ThroughSeq 必须来自 follow 开场 snapshot 的 cursor。
func (c *Client) PageSession(ctx context.Context, request PageRequest) (SessionPageResult, error) {
	var result SessionPageResult
	args := map[string]any{"request": request}
	if err := c.Call(ctx, MethodSessionPage, args, &result); err != nil {
		return SessionPageResult{}, err
	}
	return result, nil
}

// FollowSession 订阅一个会话的历史与直播事件。
func (c *Client) FollowSession(ctx context.Context, sessionID string, assistantStream bool) (*Stream, error) {
	return c.OpenStream(ctx, MethodSessionFollow, map[string]any{
		"request": FollowRequest{
			Address:         SessionPath(sessionID),
			AssistantStream: assistantStream,
		},
	})
}

// SubscribeEvents 订阅 $events，接收审批与追问等反向交互。
func (c *Client) SubscribeEvents(ctx context.Context) (*Stream, error) {
	return c.OpenStream(ctx, EndpointEvents, map[string]any{})
}

// Prompt 投递一次输入。requestID 由调用方持有，重试必须复用同一个值。
func (c *Client) Prompt(ctx context.Context, request PromptRequest) error {
	if strings.TrimSpace(request.RequestID) == "" {
		return errors.New("harnessclient: prompt 缺少 requestId")
	}
	if request.Mode == "" {
		request.Mode = PromptModeQueue
	}
	if request.Mode != PromptModeQueue {
		return fmt.Errorf("harnessclient: 首版只支持 %s 模式，收到 %q", PromptModeQueue, request.Mode)
	}
	if len(request.Content) == 0 {
		return errors.New("harnessclient: prompt 内容不能为空")
	}
	for _, part := range request.Content {
		if part.Type != "text" {
			return fmt.Errorf("harnessclient: 首版只支持 text 输入，收到 %q", part.Type)
		}
		if strings.TrimSpace(part.Text) == "" {
			return errors.New("harnessclient: text 输入不能为空白")
		}
	}
	args := map[string]any{"request": request}
	return c.Call(ctx, MethodSessionPrompt, args, nil)
}

// Cancel 取消会话当前共享轮次。
func (c *Client) Cancel(ctx context.Context, sessionID string) error {
	args := map[string]any{"request": CancelRequest{SessionID: sessionID}}
	return c.Call(ctx, MethodSessionCancel, args, nil)
}

// ModelCatalog 取模型目录。
func (c *Client) ModelCatalog(ctx context.Context) (ModelCatalogResult, error) {
	var result ModelCatalogResult
	// 该方法描述符里没有参数，必须传空对象而不是省略。
	if err := c.Call(ctx, MethodSessionModelCatalog, map[string]any{}, &result); err != nil {
		return ModelCatalogResult{}, err
	}
	return result, nil
}

// SelectModel 转发模型选择。provider 与 model 的合法性由 Harness 判定，
// agentd 不按模型名推断付费路线，也不替用户选择供应商。
func (c *Client) SelectModel(ctx context.Context, request SelectModelRequest) error {
	args := map[string]any{"request": request}
	return c.Call(ctx, MethodSessionSelectModel, args, nil)
}

// Ping 用模型目录探活，判断服务是否仍在。它不触发任何模型调用。
func (c *Client) Ping(ctx context.Context, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	_, err := c.ModelCatalog(ctx)
	return err
}
