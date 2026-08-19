package pushbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Provider 客户端。它只发送固定枚举与匿名短标签：Prompt、源码、完整命令、
// 文件内容、模型输出和 agentd 访问 Token 都不会离开这台 Mac。
const (
	providerTimeout   = 8 * time.Second
	providerUserAgent = "mimi-agentd-push/1"
)

// ErrDeviceUnregistered 表示 APNs 已确认该设备 Token 失效，调用方应删除本地设备。
var ErrDeviceUnregistered = errors.New("设备 Token 已失效")

type Notification struct {
	Version      int    `json:"version"`
	Event        string `json:"event"`
	Ticket       string `json:"ticket"`
	ActionID     string `json:"action_id"`
	DeviceID     string `json:"device_id"`
	ProfileID    string `json:"profile_id"`
	Runtime      string `json:"runtime"`
	ApprovalKind string `json:"approval_kind"`
	HostTag      string `json:"host_tag"`
	SessionTag   string `json:"session_tag"`
	ExpiresAt    string `json:"expires_at"`
}

const (
	EventApprovalPending  = "approval.pending"
	EventApprovalResolved = "approval.resolved"
)

type Client struct {
	baseURL string
	http    *http.Client
}

func NewClient(baseURL string) *Client {
	return &Client{
		baseURL: strings.TrimRight(strings.TrimSpace(baseURL), "/"),
		http:    &http.Client{Timeout: providerTimeout},
	}
}

func (c *Client) Configured() bool { return c != nil && c.baseURL != "" }

// IssueTicket 用设备刚拿到的 APNs Token 换一张不透明 Ticket。agentd 只是代跑
// 这一步的传输，它不解析、也无法解析返回的 Ticket 内容。
func (c *Client) IssueTicket(ctx context.Context, environment string, deviceToken string, installation string) (string, time.Time, error) {
	if !c.Configured() {
		return "", time.Time{}, errors.New("未配置推送 Provider")
	}
	body := map[string]any{
		"version":      1,
		"environment":  environment,
		"device_token": deviceToken,
		"installation": installation,
	}
	var response struct {
		Ticket    string `json:"ticket"`
		ExpiresAt string `json:"expires_at"`
	}
	if err := c.post(ctx, "/v1/ticket", body, &response); err != nil {
		return "", time.Time{}, err
	}
	expiry, err := time.Parse(time.RFC3339, response.ExpiresAt)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("Provider 返回的到期时间无效: %w", err)
	}
	return response.Ticket, expiry, nil
}

func (c *Client) RevokeTicket(ctx context.Context, ticket string) error {
	if !c.Configured() {
		return nil
	}
	return c.post(ctx, "/v1/ticket/revoke", map[string]any{"version": 1, "ticket": ticket}, nil)
}

func (c *Client) Notify(ctx context.Context, notification Notification) error {
	if !c.Configured() {
		return errors.New("未配置推送 Provider")
	}
	notification.Version = 1
	var response struct {
		Delivered  bool   `json:"delivered"`
		Reason     string `json:"reason"`
		APNsStatus int    `json:"apns_status"`
	}
	if err := c.post(ctx, "/v1/notify", notification, &response); err != nil {
		return err
	}
	if !response.Delivered {
		// Provider 用 200 + delivered:false 回报 APNs 的协议级拒绝，避免托管 CDN
		// 替换 5xx 响应体时丢掉 reason。这里必须当成失败，不能默认成功。
		return fmt.Errorf("APNs 拒绝投递（status=%d reason=%s）", response.APNsStatus, response.Reason)
	}
	return nil
}

func (c *Client) post(ctx context.Context, path string, body any, target any) error {
	encoded, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(encoded))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", providerUserAgent)
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
	if resp.StatusCode == http.StatusGone {
		return ErrDeviceUnregistered
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// 只回状态码与 Provider 的固定错误枚举，绝不把响应体原样带进日志。
		return fmt.Errorf("push provider %s 返回 %d (%s)", path, resp.StatusCode, providerReason(raw))
	}
	if target == nil {
		return nil
	}
	return json.Unmarshal(raw, target)
}

func providerReason(raw []byte) string {
	var body struct {
		Error  string `json:"error"`
		Reason string `json:"reason"`
	}
	if json.Unmarshal(raw, &body) != nil {
		return "unknown"
	}
	if body.Error != "" {
		return body.Error
	}
	if body.Reason != "" {
		return body.Reason
	}
	return "unknown"
}
