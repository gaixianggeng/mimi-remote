package harnessclient

import (
	"context"
	"crypto/rand"
	"encoding/hex"
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
	// 父会话身份必须跨 agentd 中继保留；iPad 侧据此从顶层列表排除子会话。
	ParentSessionID string `json:"parentSessionId,omitempty"`
	Origin          string `json:"origin,omitempty"`
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

// ModelCatalog 取模型目录。
func (c *Client) ModelCatalog(ctx context.Context) (ModelCatalogResult, error) {
	var result ModelCatalogResult
	// 该方法描述符里没有参数，必须传空对象而不是省略。
	if err := c.Call(ctx, MethodSessionModelCatalog, map[string]any{}, &result); err != nil {
		return ModelCatalogResult{}, err
	}
	return result, nil
}

// Ping 用模型目录探活，判断服务是否仍在。它不触发任何模型调用。
func (c *Client) Ping(ctx context.Context, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	_, err := c.ModelCatalog(ctx)
	return err
}
