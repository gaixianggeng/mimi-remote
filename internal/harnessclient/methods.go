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

// SessionAddress 定位一个会话。
type SessionAddress struct {
	Kind      string `json:"kind"`
	SessionID string `json:"sessionId"`
}

// SessionSummary 是会话列表/搜索结果里的一项。
type SessionSummary struct {
	SessionID string `json:"sessionId"`
	Title     string `json:"title,omitempty"`
	CWD       string `json:"cwd,omitempty"`
	UpdatedAt string `json:"updatedAt,omitempty"`
}

// CreateSessionRequest 新建会话。cwd 必须已经过 agentd 的工作区授权。
type CreateSessionRequest struct {
	CWD         string `json:"cwd,omitempty"`
	WorkspaceID string `json:"workspaceId,omitempty"`
	AgentPreset string `json:"agentPreset,omitempty"`
}

// CreateSessionResult 返回新会话标识。
type CreateSessionResult struct {
	SessionID string `json:"sessionId"`
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
	AssistantStream bool           `json:"assistantStream,omitempty"`
}

// PromptContent 是一条输入内容。
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

// ModelEntry 是模型目录里的一项。Mimi 只消费并转发，不判断供应商归属。
type ModelEntry struct {
	ID            string `json:"id"`
	Name          string `json:"name,omitempty"`
	ContextWindow int64  `json:"contextWindow,omitempty"`
	MaxTokens     int64  `json:"maxTokens,omitempty"`
}

// ModelCatalogGroup 是按 provider 分组的目录。
type ModelCatalogGroup struct {
	ID     string       `json:"id"`
	Title  string       `json:"title,omitempty"`
	Models []ModelEntry `json:"models"`
}

// ModelCatalogResult 是模型目录响应。
type ModelCatalogResult struct {
	Groups []ModelCatalogGroup `json:"groups"`
}

// PageRequest 取会话的一页历史。
type PageRequest struct {
	SessionID string `json:"sessionId"`
	Cursor    string `json:"cursor,omitempty"`
	Limit     int    `json:"limit,omitempty"`
}

// ListSessions 列出持久会话。列表不会因为被读取而激活全部 Agent，
// 因此这里必须由上层按授权工作区裁剪。
func (c *Client) ListSessions(ctx context.Context, query any) ([]SessionSummary, error) {
	var result struct {
		Sessions []SessionSummary `json:"sessions"`
	}
	if err := c.Call(ctx, MethodSessionList, query, &result); err != nil {
		return nil, err
	}
	return result.Sessions, nil
}

// SearchSessions 按关键词搜索会话。
func (c *Client) SearchSessions(ctx context.Context, query any) ([]SessionSummary, error) {
	var result struct {
		Sessions []SessionSummary `json:"sessions"`
	}
	if err := c.Call(ctx, MethodSessionSearch, query, &result); err != nil {
		return nil, err
	}
	return result.Sessions, nil
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

// PageSession 取一页历史。返回的游标由上层透传，不要自行解析。
func (c *Client) PageSession(ctx context.Context, request PageRequest) (json.RawMessage, error) {
	var result json.RawMessage
	args := map[string]any{"request": request}
	if err := c.Call(ctx, MethodSessionPage, args, &result); err != nil {
		return nil, err
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
