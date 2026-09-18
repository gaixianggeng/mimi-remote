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

	// done 把读协程的退出原因交回 serve。与另外两条网关同语义：任何一条上游流断掉
	// 都结束整条连接。会话订阅断线后没人会重新订阅，留着连接只会让客户端一直看一个
	// 收不到帧的会话；断开连接才能走到"客户端重连并重新订阅"这条既有恢复路径。
	done chan<- string

	mu sync.Mutex
	// retryMu 串行化 retryPendingInteractions：关联信息补齐、客户端打开会话、轮询定时器
	// 可能同时触发重试，串行化保证同一条暂存交互不会被并发下发两次（重复卡片）。
	retryMu sync.Mutex
	// interactionMu 将有效性检查、下发登记和取消串行化，保证撤卡不会先于请求送达。
	interactionMu sync.Mutex
	// clientID 是 $events ready 帧给出的应答标识，审批回传必需。
	clientID string
	follows  map[string]*deepSeekFollow
	// callThreads 把工具调用的 callId 映射到会话。Harness 的审批 waterfall 是宿主级
	// 通道；会话标识由帧上的 agentId 给出，callId 映射是复核用的次选判据——只有本
	// 连接真的在会话事件里见过这次调用才成立。
	callThreads map[string]string
	// activeTurns 记录会话当前是否有未结束的 turn（Harness 在同一会话内串行运行）。
	// 用于判断一条订阅能不能被回收成空闲，
	// 不再参与交互归属（那件事只能靠帧上的身份字段或 callId，不能靠推断）。
	activeTurns map[string]int
	// waterfalls 记录已下发的反向请求，用于把 cancel 与客户端应答对回 Harness 的 eventId。
	waterfalls map[string]deepSeekPendingWaterfall
	// pendingInteractions 暂存尚未送达客户端的交互请求（归属未知，或归属已知但本连接
	// 还没获得该会话授权），按 eventId 索引。见 holdInteraction 与 retryPendingInteractions。
	pendingInteractions map[string]deepSeekPendingInteraction
	// terminalInteractions 由 interactionMu 保护，有界保留已取消/完成/过期事件，
	// 避免另一条流迟到的同 eventId 请求重新生成卡片。
	terminalInteractions map[string]time.Time
	// threadProviders 记住客户端在 thread/start 上声明的供应商。DeepSeek 运行时下客户端的
	// 每条 turn/start 也带 modelProvider（见 iOS 的 SessionAPIModels.turnParams），所以这份
	// 记忆不是唯一证据，而是该字段缺失时的兜底；模型目录不保证 model id 全局唯一，
	// 有依据就必须留着。见 rememberDeepSeekThreadProvider。
	threadProviders map[string]string
	closed          bool
}

// deepSeekInteractionHoldTimeout 是一条交互请求在本地等待"能送达"的上限。
//
// 取值比 Harness 侧会话订阅超时宽得多：这里等的是"客户端打开那个会话"这类人工动作，
// 窗口太短等于把可恢复的审批变成永久丢失。等待期间不替任何会话作答。
const deepSeekInteractionHoldTimeout = 2 * time.Minute

// deepSeekInteractionRetryInterval 是暂存重试的间隔。
//
// 用有界轮询而不是单一事件钩子，因为能让一条交互重新可送达的触发点不止一个：
// 会话订阅建立、callId 落表、客户端打开会话（策略层随之授权）先后顺序不定，
// 没有一个事件能把它们全部覆盖。
const deepSeekInteractionRetryInterval = 3 * time.Second

// deepSeekInteractionHoldMax 限制暂存条数，避免上游连续推送把内存撑大。
const deepSeekInteractionHoldMax = 8

// deepSeekPendingInteraction 是一条已接住、等送达的交互请求。
type deepSeekPendingInteraction struct {
	request harnessclient.WaterfallRequest
	// expiresAt 固定不变：反复重试不应该把等待窗口无限延长。
	expiresAt time.Time
}

// deepSeekPendingWaterfall 是一次已下发、等待应答的反向请求。
type deepSeekPendingWaterfall struct {
	// requestID 是下发给移动端的 JSON-RPC id；应答按它回来。
	requestID int64
	method    string
	threadID  string
	eventID   string
	// responding 只阻止重复回传；收到客户端应答不等于 Harness 已接受。
	responding bool
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
		router:               r,
		client:               client,
		harness:              harness,
		clientID:             clientID,
		follows:              map[string]*deepSeekFollow{},
		callThreads:          map[string]string{},
		activeTurns:          map[string]int{},
		terminalInteractions: map[string]time.Time{},
		waterfalls:           map[string]deepSeekPendingWaterfall{},
		pendingInteractions:  map[string]deepSeekPendingInteraction{},
		threadProviders:      map[string]string{},
		policy:               newAppServerGatewayPolicy(r, appServerRuntimeDeepSeekID),
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

	done := make(chan string, 8)
	// 会话订阅的读协程也要能报告退出原因，因此先把 done 挂到连接上；必须在启动
	// 任何一条会建立订阅的协程之前完成。
	c.done = done
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
	c.pendingInteractions = map[string]deepSeekPendingInteraction{}
	c.mu.Unlock()

	for _, follow := range follows {
		follow.markReleased()
		follow.stream.Close()
		c.router.releaseDeepSeekSession()
	}

	// 与 Codex / Claude 两条网关同语义：连接收尾必须关闭 policy。
	//
	// policy 持有两类只有它自己能还的东西：托管 worktree 的 pending use（客户端断连时
	// 一个仍在等待响应的 thread/start 已经把它加上去了，见 validateGatewayClientFrame 的
	// gatewayMethodNeedsManagedPendingUse 分支）与 mimi task 动态声明。上面按订阅归还的是
	// deepSeekSession 名额，与这两者无关——没有任何 follow 的连接同样会持有它们，
	// 只靠订阅路径覆盖不到。
	// 漏掉这一步会让计数在 agent 进程存活期间不归零，那个托管 worktree 因此一直删不掉。
	// policy.close() 自身幂等（p.closed 保护），并发收尾不会重复释放。
	if c.policy != nil {
		c.policy.close()
	}
}

func (c *deepSeekGatewayConn) isClosed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closed
}

// followFor 返回已经建立的会话订阅，并记录一次使用。
func (c *deepSeekGatewayConn) followFor(threadID string) (*deepSeekFollow, bool) {
	c.mu.Lock()
	follow, ok := c.follows[threadID]
	c.mu.Unlock()
	if ok {
		// 正在被访问的会话不能是"最久未使用"的那条，否则下一个会话一打开就会把它
		// 回收掉。使用时间在这里刷新，回收判据才有意义。
		follow.touch()
	}
	return follow, ok
}

// markFollowObserved 在连接锁内把已成功首读的 follow 变成观察租约。
// 返回 false 表示该 follow 已被并发摘除，调用方不能向移动端确认观察成功。
func (c *deepSeekGatewayConn) markFollowObserved(follow *deepSeekFollow) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	current, ok := c.follows[follow.threadID]
	if !ok || current != follow {
		return false
	}
	follow.observed = true
	return true
}

// unobserveFollow 幂等解除观察租约。follow 本身保留在缓存里；运行中 turn、待处理
// 交互和普通 LRU 规则继续决定何时能回收，避免 detach 触发无谓的上游重订阅。
func (c *deepSeekGatewayConn) unobserveFollow(threadID string) {
	c.mu.Lock()
	if follow := c.follows[threadID]; follow != nil {
		follow.observed = false
	}
	c.mu.Unlock()
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
	if !c.acquireSessionSlot() {
		return nil, errDeepSeekSessionLimit
	}
	stream, err := c.harness.FollowSession(ctx, threadID, true)
	if err != nil {
		c.router.releaseDeepSeekSession()
		return nil, err
	}
	follow := &deepSeekFollow{threadID: threadID, stream: stream, updated: make(chan struct{}, 1)}
	if err := follow.awaitSnapshot(ctx); err != nil {
		stream.Close()
		c.router.releaseDeepSeekSession()
		return nil, err
	}
	follow.touch()

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
	// 快照与实时流共享切点：先恢复运行态再公开订阅，读协程随后只消费切点后的事件。
	// 否则另一个请求会在实时 turn/start 尚未到达时把正在运行的会话误当成空闲。
	active, known := follow.snapshotActivity()
	follow.activityKnown = known
	c.activeTurns[threadID] = active
	c.mu.Unlock()

	// 这个会话现在可用了：暂存的交互里可能正好有属于它的。重连后的顺序必然如此
	// ——$events 上的挂起交互先到，会话订阅随后才由客户端请求建立——不主动重试一次，
	// 那条审批就要一直等到下一次轮询。
	c.retryPendingInteractions()

	go c.readFollow(ctx, follow)
	return follow, nil
}

// acquireSessionSlot 申请一个会话订阅名额，必要时先回收一条空闲订阅。
func (c *deepSeekGatewayConn) acquireSessionSlot() bool {
	if c.router.acquireDeepSeekSession() {
		return true
	}
	if !c.reclaimIdleFollow() {
		return false
	}
	// 回收与申请之间有窗口，别的连接可能把刚归还的名额拿走；再试一次，失败就如实
	// 报上限，不循环等待。
	return c.router.acquireDeepSeekSession()
}

// reclaimIdleFollow 摘掉一条空闲订阅并归还它的名额。
//
// 只在上游断流或整条连接关闭时释放名额的话，"先后浏览三个会话"就会在第三个上失败：
// 前两条订阅既没有运行中的 turn、也没有等用户决定的交互，却一直占着名额。错误文案里的
// "稍后重试"在这里没有帮助——等待本身不会释放任何资源。
//
// 回收对象限定为"空闲"订阅：没有运行中的 turn、也没有已下发或暂存中的交互。运行中或
// 正在等用户决定的会话绝不能被回收，否则用户会丢掉进行中的状态。空闲订阅之间淘汰最近
// 使用时间最久的一条。被回收的会话若再次被访问，ensureFollow 会重新订阅一次，代价是
// 一次开场快照往返。
//
// 单纯把 deepseek.max_concurrent_sessions 调大只会把问题往后推，这里要的是生命周期。
func (c *deepSeekGatewayConn) reclaimIdleFollow() bool {
	c.mu.Lock()
	var victim *deepSeekFollow
	var victimUsed time.Time
	for threadID, follow := range c.follows {
		if follow.observed || !follow.activityKnown || c.activeTurns[threadID] > 0 || c.followHasPendingInteractionLocked(threadID) {
			continue
		}
		used := follow.lastUsedAt()
		if victim == nil || used.Before(victimUsed) {
			victim = follow
			victimUsed = used
		}
	}
	if victim == nil {
		c.mu.Unlock()
		return false
	}
	delete(c.follows, victim.threadID)
	delete(c.activeTurns, victim.threadID)
	c.mu.Unlock()

	// 标记为本地主动释放：读协程据此区分"上游断流"与"被回收"，前者要结束整条连接，
	// 后者不能——回收一条空闲订阅不该掐掉客户端正在用的连接。
	victim.markReleased()
	victim.stream.Close()
	c.router.releaseDeepSeekSession()
	// 订阅名额和客户端的连接级 binding 必须一起失效。此通知不是 turn 结束，
	// 不复用 thread/closed，以免清理仍由 Harness 持有的会话事实。
	if err := c.writeDeepSeekNotification("_mimi/deepseekFollow/invalidated", map[string]any{
		"threadId": victim.threadID,
		"reason":   "idle",
	}); err != nil {
		select {
		case c.done <- "follow_invalidation_failed":
		default:
		}
	}
	log.Printf("deepseek gateway 会话订阅已达上限，回收最久未使用的空闲订阅 thread=%s",
		sanitizeGatewayDiagnostic(victim.threadID))
	return true
}

// followHasPendingInteractionLocked 报告某个会话是否还有等用户决定的交互。
//
// 调用方必须已持有 c.mu。尚未归属的暂存交互按帧里的身份字段判断会落在哪个会话上，
// 判不出时一律视为"可能属于它"——宁可少回收一条，也不能让一张待答卡片消失。
func (c *deepSeekGatewayConn) followHasPendingInteractionLocked(threadID string) bool {
	for _, pending := range c.waterfalls {
		if pending.threadID == threadID {
			return true
		}
	}
	for _, held := range c.pendingInteractions {
		if hint := held.request.ThreadHint(); hint == "" || hint == threadID {
			return true
		}
	}
	return false
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
