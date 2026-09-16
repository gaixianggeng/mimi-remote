package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件装配 DeepSeek Harness 的 app-server 网关。
//
// 与另外两条网关的区别在载体。Codex 是 SSH 上的常驻 app-server，Claude 是 stdio
// bridge，两者都能按帧透传；Harness 是 HTTP Connection RPC 加 WebSocket 事件流，
// 协议完全不同，所以这里做的是双向翻译而不是转发：
//
//	移动端方法  →  harnessclient 调用（deepseek_gateway_client.go）
//	Harness 事件 →  app-server 通知（deepseek_translate.go、deepseek_gateway_events.go）
//
// 凭据纪律：启动 token 只用于换取 Cookie，Cookie 只留在 harnessclient 内存里。
// 两者都不写日志、不进回给移动端的错误文案，也不出现在诊断输出里。

const (
	// deepSeekAuthTimeout 限制一次 token 换 Cookie 的握手时间。
	deepSeekAuthTimeout = 5 * time.Second
	// deepSeekEventReadyTimeout 等待 $events 订阅 ready 帧的时间。
	//
	// ready 帧里的 clientId 是回传审批应答的必需参数，因此必须等到；带着空 clientId
	// 继续会让所有审批应答静默失败，比直接报错更难排查。
	deepSeekEventReadyTimeout = 5 * time.Second
	// deepSeekSnapshotTimeout 等待某个会话开场快照的时间。snapshot 给出 throughSeq，
	// 是后续分页的必要参数。
	deepSeekSnapshotTimeout = 10 * time.Second
)

// 运行时错误码。移动端按 code 分流，取值必须稳定。
const (
	deepSeekCodeDisabled     = "DEEPSEEK_DISABLED"
	deepSeekCodeUnconfigured = "DEEPSEEK_UNCONFIGURED"
	deepSeekCodeCredentials  = "DEEPSEEK_CREDENTIAL_UNAVAILABLE"
	deepSeekCodeAuthFailed   = "DEEPSEEK_AUTH_FAILED"
	deepSeekCodeEvents       = "DEEPSEEK_EVENT_STREAM_UNAVAILABLE"
	deepSeekCodeSessionLimit = "DEEPSEEK_SESSION_LIMIT_EXCEEDED"
)

// appServerDeepSeekStatus 是 channel 对外声明的就绪状态。
type appServerDeepSeekStatus struct {
	Status  string
	Healthy bool
	Fix     string
}

const (
	deepSeekStatusDisabled     = "disabled"
	deepSeekStatusUnconfigured = "unconfigured"
	deepSeekStatusCredential   = "credential_unavailable"
	deepSeekStatusReady        = "ready"
)

// appServerDeepSeekStatusFor 只做本地只读检查：地址是否可用、凭据是否可读。
//
// 刻意不做网络探测。GET app-server config 在 App 启动路径上，一次 Harness 往返会把它
// 拖慢；认证与可达性由连接时和 agentd doctor 负责。这与 Codex channel 用「上游配置
// 是否存在」判定可用性是同一个取舍：channel 表达"能不能试"，不表达"现在通不通"。
func appServerDeepSeekStatusFor(cfg config.DeepSeekConfig) appServerDeepSeekStatus {
	if !cfg.Enabled {
		return appServerDeepSeekStatus{Status: deepSeekStatusDisabled}
	}
	baseURL, err := config.NormalizeDeepSeekBaseURL(cfg.BaseURL)
	if err != nil || baseURL == "" {
		return appServerDeepSeekStatus{
			Status: deepSeekStatusUnconfigured,
			Fix:    "在 config.json 的 deepseek.base_url 填写 Harness 服务地址",
		}
	}
	if _, err := harnessclient.ReadTokenFile(cfg.TokenFile); err != nil {
		// 读取失败的原因里含本机绝对路径，不能下发给移动端，只给可操作文案。
		return appServerDeepSeekStatus{
			Status: deepSeekStatusCredential,
			Fix:    "把 Harness 启动 token 写入一个 0600 文件，并把路径配到 deepseek.token_file",
		}
	}
	return appServerDeepSeekStatus{Status: deepSeekStatusReady, Healthy: true}
}

// acquireDeepSeekSession 申请一个 Harness 会话订阅名额。
//
// 只统计会话订阅（session/follow）；每个连接的 $events 订阅不计入，否则默认上限 2
// 会让「一台设备打开一个会话」正好占满，重连时因为旧连接尚未超时而拿不到名额，
// 表现为一个明明可用却连不上的运行时。
func (r *Router) acquireDeepSeekSession() bool {
	limit := r.cfg.DeepSeek.MaxConcurrentSessions
	if limit <= 0 {
		limit = config.DefaultDeepSeekMaxConcurrentSessions
	}
	r.deepSeekMu.Lock()
	defer r.deepSeekMu.Unlock()
	if r.activeDeepSeekSession >= limit {
		return false
	}
	r.activeDeepSeekSession++
	return true
}

func (r *Router) releaseDeepSeekSession() {
	r.deepSeekMu.Lock()
	if r.activeDeepSeekSession > 0 {
		r.activeDeepSeekSession--
	}
	r.deepSeekMu.Unlock()
}

// deepSeekGatewayConn 是一条移动端连接的全部运行态。
type deepSeekGatewayConn struct {
	router  *Router
	client  *websocket.Conn
	policy  *appServerGatewayPolicy
	harness *harnessclient.Client

	writeMu sync.Mutex

	mu sync.Mutex
	// clientID 是 $events ready 帧给出的应答标识，审批回传必需。
	clientID string
	follows  map[string]*deepSeekFollow
	// callThreads 把工具调用的 callId 映射到会话。Harness 的审批 waterfall 是宿主级
	// 通道，实测帧里不带会话标识；callId 是唯一能把审批归回会话的实测字段。
	callThreads map[string]string
	// activeTurns 记录每个会话是否有未结束的 turn，作为审批归属的次级判据。
	activeTurns map[string]int
	// waterfalls 记录已下发的反向请求，用于把 cancel 与客户端应答对回 Harness 的 eventId。
	waterfalls map[string]deepSeekPendingWaterfall
	closed     bool
}

// deepSeekPendingWaterfall 是一次已下发、等待应答的反向请求。
type deepSeekPendingWaterfall struct {
	// requestID 是下发给移动端的 JSON-RPC id；应答按它回来。
	requestID int64
	method    string
	threadID  string
	eventID   string
}

func (r *Router) appServerDeepSeekGatewayWS(w http.ResponseWriter, req *http.Request) {
	// 必须先确认外侧确实是 WebSocket 升级，否则普通 GET 也会触发一次对 Harness 的认证。
	if !websocket.IsWebSocketUpgrade(req) {
		writeError(w, http.StatusBadRequest, "app-server gateway 需要 WebSocket Upgrade")
		return
	}
	client, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("deepseek gateway ws upgrade failed err=%v", err)
		return
	}
	defer func() { _ = client.Close() }()

	cfg := r.cfg.DeepSeek
	if !cfg.Enabled {
		writeGatewayRuntimeError(client, deepSeekCodeDisabled, "DeepSeek Harness runtime 未启用")
		return
	}
	baseURL, err := config.NormalizeDeepSeekBaseURL(cfg.BaseURL)
	if err != nil || baseURL == "" {
		writeGatewayRuntimeError(client, deepSeekCodeUnconfigured, "deepseek.base_url 不可用，请在电脑运行 agentd doctor")
		return
	}
	token, err := harnessclient.ReadTokenFile(cfg.TokenFile)
	if err != nil {
		// 错误里含本机绝对路径：日志记原因，回给移动端的只有可操作文案。
		log.Printf("deepseek gateway 读取 token 文件失败 err=%v", err)
		writeGatewayRuntimeError(client, deepSeekCodeCredentials, "读取 Harness 凭据失败，请在电脑运行 agentd doctor")
		return
	}
	harness, err := harnessclient.New(harnessclient.Config{BaseURL: baseURL, AccessToken: token})
	if err != nil {
		writeGatewayRuntimeError(client, deepSeekCodeUnconfigured, "deepseek.base_url 不可用，请在电脑运行 agentd doctor")
		return
	}

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()

	authCtx, authCancel := context.WithTimeout(ctx, deepSeekAuthTimeout)
	authErr := harness.Authenticate(authCtx)
	authCancel()
	if authErr != nil {
		// harnessclient 已保证传输层错误里不含启动 token。
		log.Printf("deepseek gateway 认证失败 err=%v", authErr)
		writeGatewayRuntimeError(client, deepSeekCodeAuthFailed, "无法连接 Harness 服务，请在电脑运行 agentd doctor")
		return
	}

	// $events 是审批与追问的唯一入口，先建立；拿不到 clientId 就无法回传应答。
	events, clientID, err := subscribeDeepSeekEvents(ctx, harness)
	if err != nil {
		log.Printf("deepseek gateway 事件流不可用 err=%v", err)
		writeGatewayRuntimeError(client, deepSeekCodeEvents, "Harness 事件流不可用，请确认服务仍在运行")
		return
	}
	defer events.Close()

	conn := &deepSeekGatewayConn{
		router:      r,
		client:      client,
		harness:     harness,
		clientID:    clientID,
		follows:     map[string]*deepSeekFollow{},
		callThreads: map[string]string{},
		activeTurns: map[string]int{},
		waterfalls:  map[string]deepSeekPendingWaterfall{},
		policy:      newAppServerGatewayPolicy(r, appServerRuntimeDeepSeekID),
	}
	conn.serve(ctx, events)
}

// subscribeDeepSeekEvents 订阅 $events 并等到 ready。返回的 clientId 只用于回传应答，
// 属于宿主内部事实，不下发移动端。
func subscribeDeepSeekEvents(ctx context.Context, harness *harnessclient.Client) (*harnessclient.Stream, string, error) {
	stream, err := harness.SubscribeEvents(ctx)
	if err != nil {
		return nil, "", err
	}
	clientID, err := stream.Ready(ctx, deepSeekEventReadyTimeout)
	if err != nil {
		stream.Close()
		return nil, "", err
	}
	return stream, clientID, nil
}

// serve 运行到任一侧结束。三条协程各自把退出原因写进 done，先到者决定关闭。
func (c *deepSeekGatewayConn) serve(ctx context.Context, events *harnessclient.Stream) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	done := make(chan string, 4)
	configureGatewayReadConn(c.client)

	go func() { done <- c.readEvents(ctx, events) }()
	go func() { done <- c.readClientFrames(ctx) }()
	go func() {
		pingClientGateway(ctx, c.client, &c.writeMu)
		done <- "ping_failed_or_context_done"
	}()

	reason := <-done
	cancel()
	_ = c.client.Close()
	c.close()
	log.Printf("deepseek gateway closed reason=%s", sanitizeGatewayDiagnostic(reason))
}

// close 幂等地释放全部运行态：关闭会话订阅，并归还占用的会话名额。
func (c *deepSeekGatewayConn) close() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	follows := make([]*deepSeekFollow, 0, len(c.follows))
	for _, follow := range c.follows {
		follows = append(follows, follow)
	}
	c.follows = map[string]*deepSeekFollow{}
	c.mu.Unlock()

	for _, follow := range follows {
		follow.stream.Close()
		c.router.releaseDeepSeekSession()
	}
}

func (c *deepSeekGatewayConn) isClosed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closed
}

// followFor 返回已经建立的会话订阅。
func (c *deepSeekGatewayConn) followFor(threadID string) (*deepSeekFollow, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	follow, ok := c.follows[threadID]
	return follow, ok
}

// ensureFollow 取得会话订阅，必要时新建并等到开场快照。
//
// 历史与实时事件都必须先有订阅：snapshot 给出的 cursor 是 session/page 的必填参数，
// 而没有订阅就收不到后续的 turn 与 assistant-stream 帧。
func (c *deepSeekGatewayConn) ensureFollow(ctx context.Context, threadID string) (*deepSeekFollow, error) {
	if strings.TrimSpace(threadID) == "" {
		return nil, errors.New("deepseek gateway: 缺少 threadId")
	}
	if follow, ok := c.followFor(threadID); ok {
		return follow, nil
	}
	if !c.router.acquireDeepSeekSession() {
		return nil, errDeepSeekSessionLimit
	}
	stream, err := c.harness.FollowSession(ctx, threadID, true)
	if err != nil {
		c.router.releaseDeepSeekSession()
		return nil, err
	}
	follow := &deepSeekFollow{threadID: threadID, stream: stream, turnStarts: make(chan int64, 8)}
	if err := follow.awaitSnapshot(ctx); err != nil {
		stream.Close()
		c.router.releaseDeepSeekSession()
		return nil, err
	}

	// 注册与启动读协程必须在同一临界区里完成：先注册再启动，读协程才能看到自己
	// 所属的 follow；反过来会让先到的帧落到一个未注册的 follow 上。
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		stream.Close()
		c.router.releaseDeepSeekSession()
		return nil, errors.New("deepseek gateway: 连接已关闭")
	}
	if existing, ok := c.follows[threadID]; ok {
		c.mu.Unlock()
		stream.Close()
		c.router.releaseDeepSeekSession()
		return existing, nil
	}
	c.follows[threadID] = follow
	c.mu.Unlock()

	go c.readFollow(ctx, follow)
	return follow, nil
}

var errDeepSeekSessionLimit = errors.New("deepseek gateway: Harness 会话并发数已达上限")

// writeDeepSeekNotification 下发一条通知（无 id）。
func (c *deepSeekGatewayConn) writeDeepSeekNotification(method string, params map[string]any) error {
	return c.writeDeepSeekPayload(map[string]any{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
	})
}

// writeDeepSeekResult 回应一条移动端请求。
func (c *deepSeekGatewayConn) writeDeepSeekResult(id any, result any) error {
	return c.writeDeepSeekPayload(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  result,
	})
}

// writeDeepSeekError 用固定文案回绝一条移动端请求，不把上游错误原文带出去。
func (c *deepSeekGatewayConn) writeDeepSeekError(id any, code int, message string) error {
	return c.writeDeepSeekPayload(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error": map[string]any{
			"code":    code,
			"message": message,
		},
	})
}

func (c *deepSeekGatewayConn) writeDeepSeekPayload(payload map[string]any) error {
	_, err := c.forwardDeepSeekPayload(payload)
	return err
}

// forwardDeepSeekPayload 与 writeDeepSeekPayload 同路，只是把"是否真的到了客户端"也报出来。
// 反向请求需要这个区分：被 policy 丢弃的请求不能留在本地待应答表里，
// 否则客户端应答时会去解一条从未送达的请求。
func (c *deepSeekGatewayConn) forwardDeepSeekPayload(payload map[string]any) (bool, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return false, err
	}
	return c.forwardDeepSeekFrame(raw)
}

// forwardDeepSeekFrame 把一条出站帧先交给 appServerGatewayPolicy，再按它的结论下发。
//
// 出站方向必须过 policy，否则适配层会绕开三件只有这里能完成的事：
//
//   - thread/start、thread/list、thread/read 的成功响应要把 thread 登记进授权表。
//     本地翻译不会替它登记，于是「新建会话成功」之后紧接着的 turn/start 会被判成
//     未授权 thread，用户看到的正是"会话建好了却发不出消息"。
//   - thread/search 的响应要按 projects/browse_roots 裁剪。Harness 的检索结果不带
//     cwd，请求侧也没有 cwd 可比，结果授权只能在响应侧完成。
//   - 反向请求要登记 pending，通知要过下行门禁与内联图改写。
//
// 与 Codex / Claude 两条网关同语义：policy 说 drop 就不下发，说 error 就回错误帧。
func (c *deepSeekGatewayConn) forwardDeepSeekFrame(raw []byte) (bool, error) {
	forwarded, forward, policyErr := c.policy.observeUpstreamFrame(websocket.TextMessage, raw)
	if policyErr != nil {
		if !writeGatewayPolicyError(c.client, &c.writeMu, policyErr) {
			return false, errors.New("deepseek gateway: 策略错误帧下发失败")
		}
		return false, nil
	}
	if !forward {
		return false, nil
	}
	if err := writeWebSocketFrame(c.client, &c.writeMu, websocket.TextMessage, forwarded); err != nil {
		return false, err
	}
	return true, nil
}
