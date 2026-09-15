package harnessclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// DefaultCallTimeout 是单次 Connection RPC 的默认上限。会话类调用都是控制面操作，
// 真正耗时的推理走事件流，因此这里不需要很长的容忍。
const DefaultCallTimeout = 30 * time.Second

// maxResponseBytes 限制单次 RPC 响应体积，避免异常响应把 agentd 内存打满。
const maxResponseBytes = 8 << 20

// Config 描述如何连接一个已经在运行的 Harness 服务。
//
// Harness 由用户独立启动并已在自身内部完成模型配置，agentd 不负责安装、启动或配置它。
type Config struct {
	// BaseURL 是 Harness 服务的 origin，例如 http://127.0.0.1:5173。只允许 http/https。
	BaseURL string
	// AccessToken 是 Harness 启动时生成的访问 token，仅用于换取 Cookie。
	AccessToken string
	// HTTPClient 可选，用于注入测试用客户端或自定义超时。
	HTTPClient *http.Client
	// Dialer 可选，用于注入测试用 WebSocket 拨号器。
	Dialer *websocket.Dialer
}

// ErrNotAuthenticated 表示尚未完成 token 换 Cookie。
var ErrNotAuthenticated = errors.New("harnessclient: 尚未完成认证")

// ErrNoResult 表示响应缺少 result 外壳。Harness 的 gateway 在请求外壳不对时
// 会返回这种响应，必须当成失败而不是空成功。
var ErrNoResult = errors.New("harnessclient: 响应缺少 result 外壳")

// Client 是单连接客户端的并发安全封装。认证后的 Cookie 只存在本进程内存里。
type Client struct {
	config Config

	mu     sync.RWMutex
	cookie string
}

// New 校验配置并构造客户端，不发起任何网络请求。
func New(config Config) (*Client, error) {
	base := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if base == "" {
		return nil, errors.New("harnessclient: base_url 不能为空")
	}
	parsed, err := url.Parse(base)
	if err != nil {
		return nil, fmt.Errorf("harnessclient: base_url 无效：%w", err)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("harnessclient: base_url 只允许 http 或 https")
	}
	if parsed.Host == "" {
		return nil, errors.New("harnessclient: base_url 缺少主机")
	}
	config.BaseURL = base
	return &Client{config: config}, nil
}

// BaseURL 返回规范化后的服务地址。
func (c *Client) BaseURL() string { return c.config.BaseURL }

// Authenticated 报告是否已经换到 Cookie。
func (c *Client) Authenticated() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.cookie != ""
}

// ForgetCredentials 丢弃已换到的 Cookie，让下一次 Call 重新认证。
// 断线重连时 Harness 可能已经换了事件代次，必须能显式失效。
func (c *Client) ForgetCredentials() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.cookie = ""
}

func (c *Client) httpClient() *http.Client {
	if c.config.HTTPClient != nil {
		return c.config.HTTPClient
	}
	return &http.Client{Timeout: DefaultCallTimeout}
}

// Authenticate 用启动 token 换取绑定 hostname+port 的 Cookie。
//
// token 只在这里出现一次，不写日志也不返回给调用方；换到的 Cookie 留在内存。
// 拿到 Cookie 之后普通 API 才可用——Harness 不接受 Authorization 头。
func (c *Client) Authenticate(ctx context.Context) error {
	token := strings.TrimSpace(c.config.AccessToken)
	if token == "" {
		return errors.New("harnessclient: 缺少访问 token")
	}
	target, err := url.Parse(c.config.BaseURL + "/")
	if err != nil {
		return err
	}
	query := target.Query()
	query.Set("token", token)
	target.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return err
	}
	// 认证是一次性的重定向握手，必须自己接住 303 并取走 Set-Cookie。
	client := *c.httpClient()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("harnessclient: 认证请求失败：%w", err)
	}
	defer func() { _ = response.Body.Close() }()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<16))

	if response.StatusCode != http.StatusSeeOther {
		return fmt.Errorf("harnessclient: 认证未返回重定向，status=%d", response.StatusCode)
	}
	parts := make([]string, 0, len(response.Cookies()))
	for _, cookie := range response.Cookies() {
		parts = append(parts, cookie.Name+"="+cookie.Value)
	}
	if len(parts) == 0 {
		return errors.New("harnessclient: 认证响应没有下发 Cookie")
	}
	c.mu.Lock()
	c.cookie = strings.Join(parts, "; ")
	c.mu.Unlock()
	return nil
}

// Call 执行一次 Connection RPC 并把 result.value 解码到 out。
//
// out 可以为 nil，表示只关心成功与否。业务失败返回 *RemoteError，调用方可以用
// errors.As 取 code 做降级判断。
func (c *Client) Call(ctx context.Context, method string, args any, out any) error {
	if err := ValidateMethod(method); err != nil {
		return err
	}
	c.mu.RLock()
	cookie := c.cookie
	c.mu.RUnlock()
	if cookie == "" {
		return ErrNotAuthenticated
	}

	envelope := clientRequest{
		Type:   "client-request",
		RPCID:  newRequestID(),
		Method: method,
	}
	envelope.Payload.Args = args
	body, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Errorf("harnessclient: 编码请求失败：%w", err)
	}

	target := joinAPI(c.config.BaseURL, method)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Cookie", cookie)

	response, err := c.httpClient().Do(request)
	if err != nil {
		return fmt.Errorf("harnessclient: %s 请求失败：%w", method, err)
	}
	defer func() { _ = response.Body.Close() }()

	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return fmt.Errorf("harnessclient: 读取 %s 响应失败：%w", method, err)
	}
	if response.StatusCode == http.StatusUnauthorized {
		// Cookie 已失效，清掉让上层重新认证，不要把 401 当成业务错误。
		c.ForgetCredentials()
		return fmt.Errorf("harnessclient: %s 未通过认证，status=401", method)
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("harnessclient: %s 返回 status=%d", method, response.StatusCode)
	}

	var decoded serverResponse
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return fmt.Errorf("harnessclient: 解析 %s 响应失败：%w", method, err)
	}
	if decoded.Result == nil {
		// 裸 {args:...} 会被判为 gateway/bad-request，且 HTTP 仍是 200。
		return fmt.Errorf("harnessclient: %s %w", method, ErrNoResult)
	}
	if !decoded.Result.OK {
		if decoded.Result.Error != nil {
			return decoded.Result.Error
		}
		return fmt.Errorf("harnessclient: %s 返回 ok=false", method)
	}
	if out == nil || len(decoded.Result.Value) == 0 {
		return nil
	}
	if err := json.Unmarshal(decoded.Result.Value, out); err != nil {
		return fmt.Errorf("harnessclient: 解析 %s 业务结果失败：%w", method, err)
	}
	return nil
}
