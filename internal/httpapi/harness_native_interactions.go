package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件是原生流中继的交互侧：把 $events 上的 waterfall 认领给已授权会话，
// 并校验移动端回传的 $events/result。
//
// 它与 H02 的只读中继共享同一条安全原则——先证明归属，再谈转发；被拒的请求
// 不会产生任何一次上游访问。区别在于这里的"归属"是**宿主级**的：$events 是
// 一条广播通道，别的会话（Harness Web、子 Agent）的审批与追问同样送到这里。

// 归属依据，只用于日志与诊断。
const (
	harnessNativeEvidenceAgent = "agent"
	harnessNativeEvidenceHint  = "hint"
	harnessNativeEvidenceCall  = "callId"
)

// harnessNativeAttributeWaterfall 给出 waterfall 的会话归属。
//
// 只有三种证据，且都不依赖"恰好只有一个会话在跑"：
//
//  1. agentId —— 协议保证存在（`stream-protocol.ts` 的 RemoteEventInvocationFrame
//     把 agentId 定为必填），而 Harness 的身份设计是 agent 注册表 id 等于会话 id，
//     因此它就是会话标识，是**核事实**而不是推断。
//  2. 帧内其它候选键（threadId / sessionId / 嵌套 address）—— 不同版本形态的兼容入口。
//  3. callId → 会话 的映射 —— 只在确实查得到映射时成立。
//
// 取不到证据时返回空串，由调用方显式拒绝并记录诊断，**不猜测**。
//
// 刻意不使用"唯一活跃会话"兜底：$events 是宿主级通道，"只有一个会话在跑"并不蕴含
// "这条交互是我的"。按单例认领会把别人的卡片挂到用户的会话上，用户在那个上下文里
// 做出的授权决定会被用在另一个会话的工具调用上——那是一次真实的越权授权。
func harnessNativeAttributeWaterfall(
	request harnessclient.WaterfallRequest,
	callThreads map[string]string,
) (string, string) {
	if agentID := strings.TrimSpace(request.AgentID); agentID != "" {
		return agentID, harnessNativeEvidenceAgent
	}
	if hint := request.ThreadHint(); hint != "" {
		return hint, harnessNativeEvidenceHint
	}
	if callID := strings.TrimSpace(request.Request.CallID); callID != "" {
		if sessionID := strings.TrimSpace(callThreads[callID]); sessionID != "" {
			return sessionID, harnessNativeEvidenceCall
		}
	}
	return "", ""
}

// 交互注册表的边界。终态只需覆盖上游重投与双流乱序窗口；上限防止长连接无限增长。
const (
	harnessNativeInteractionTerminalTTL = 10 * time.Minute
	harnessNativeInteractionTerminalMax = 64
	harnessNativeInteractionPendingMax  = 64
)

// harnessNativeInteraction 是一条已认领、等待移动端应答的交互请求。
type harnessNativeInteraction struct {
	EventID   string
	SessionID string
	// Event 是 waterfall 事件名：approval/request 或 user-questions/request。
	// 应答的取值域据此校验——审批只接受四个结论，追问只接受结构化 answers。
	Event   string
	Request harnessclient.WaterfallPayload
	// Generation 是投递它时的连接代次。应答必须来自同一代次：断线重连前的旧代次
	// 应答不得被当成有效决定，否则一条已废弃的卡片能替新连接做决定。
	Generation  uint64
	DeliveredAt time.Time
	// Responding 标记已有人认领回传，避免同一条被两个连接同时决定。
	Responding bool
}

// harnessNativeInteractionRegistry 保存已投递但未终结的交互。
//
// 它**不是**消息缓存：只保存等待人机应答的那几条，终结即删。契约明令禁止新增
// 永久消息缓存，这里也不承担任何历史职责。
type harnessNativeInteractionRegistry struct {
	mu          sync.Mutex
	pending     map[string]*harnessNativeInteraction
	terminal    map[string]time.Time
	callThreads map[string]string
}

func newHarnessNativeInteractionRegistry() *harnessNativeInteractionRegistry {
	return &harnessNativeInteractionRegistry{
		pending:     map[string]*harnessNativeInteraction{},
		terminal:    map[string]time.Time{},
		callThreads: map[string]string{},
	}
}

// rememberCallThread 记录 callId → 会话 的映射，供后续 waterfall 归属使用。
//
// 只在工具调用事件里确实带了会话身份时调用；调用方不得用它来"补一个"归属。
func (registry *harnessNativeInteractionRegistry) rememberCallThread(callID, sessionID string) {
	callID = strings.TrimSpace(callID)
	sessionID = strings.TrimSpace(sessionID)
	if callID == "" || sessionID == "" {
		return
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	registry.callThreads[callID] = sessionID
}

// callThreadSnapshot 返回 callId → 会话 映射的副本，供归属判定读取。
func (registry *harnessNativeInteractionRegistry) callThreadSnapshot() map[string]string {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	snapshot := make(map[string]string, len(registry.callThreads))
	for callID, sessionID := range registry.callThreads {
		snapshot[callID] = sessionID
	}
	return snapshot
}

// attribute 按当前已知证据给出 waterfall 的会话归属。
func (registry *harnessNativeInteractionRegistry) attribute(
	request harnessclient.WaterfallRequest,
) (string, string) {
	return harnessNativeAttributeWaterfall(request, registry.callThreadSnapshot())
}

// isTerminal 报告 eventId 是否已经取消、完成或过期。
//
// 它挡的是**重投**：上游在重连后会重投同一个 eventId，那必须更新原卡片而不是
// 新增副本；已经终结的 eventId 更不能因为另开一条流就复活成一张新卡片。
func (registry *harnessNativeInteractionRegistry) isTerminal(eventID string) bool {
	eventID = strings.TrimSpace(eventID)
	if eventID == "" {
		return false
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	return registry.isTerminalLocked(eventID)
}

func (registry *harnessNativeInteractionRegistry) isTerminalLocked(eventID string) bool {
	terminalAt, ok := registry.terminal[eventID]
	if !ok {
		return false
	}
	if time.Since(terminalAt) >= harnessNativeInteractionTerminalTTL {
		delete(registry.terminal, eventID)
		return false
	}
	return true
}

// markTerminalLocked 以时间和数量双重边界保存终态。调用方必须持有锁。
func (registry *harnessNativeInteractionRegistry) markTerminalLocked(eventID string) {
	if eventID == "" {
		return
	}
	registry.terminal[eventID] = time.Now()
	if len(registry.terminal) <= harnessNativeInteractionTerminalMax {
		return
	}
	// 超限时先清过期项，仍然超限就丢最旧的一条：终态只是防重投的窗口，
	// 不是账本，宁可少记也不能让长连接无限增长。
	cutoff := time.Now().Add(-harnessNativeInteractionTerminalTTL)
	for key, at := range registry.terminal {
		if at.Before(cutoff) {
			delete(registry.terminal, key)
		}
	}
	for len(registry.terminal) > harnessNativeInteractionTerminalMax {
		var oldestKey string
		var oldestAt time.Time
		for key, at := range registry.terminal {
			if oldestKey == "" || at.Before(oldestAt) {
				oldestKey, oldestAt = key, at
			}
		}
		delete(registry.terminal, oldestKey)
	}
}

// harnessNativeDeliveryResult 区分正常重投、终态与真正的容量错误。
type harnessNativeDeliveryResult uint8

const (
	harnessNativeDeliveryNew harnessNativeDeliveryResult = iota
	harnessNativeDeliveryDuplicate
	harnessNativeDeliveryTerminal
	harnessNativeDeliveryFull
	harnessNativeDeliveryInvalid
)

// deliver 保留既有“是否新增”调用语义；中继使用 registerDelivery 取得完整结果。
func (registry *harnessNativeInteractionRegistry) deliver(interaction harnessNativeInteraction) bool {
	return registry.registerDelivery(interaction) == harnessNativeDeliveryNew
}

func (registry *harnessNativeInteractionRegistry) registerDelivery(interaction harnessNativeInteraction) harnessNativeDeliveryResult {
	eventID := strings.TrimSpace(interaction.EventID)
	if eventID == "" || strings.TrimSpace(interaction.SessionID) == "" {
		return harnessNativeDeliveryInvalid
	}
	interaction.EventID = eventID
	interaction.DeliveredAt = time.Now()
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if registry.isTerminalLocked(eventID) {
		return harnessNativeDeliveryTerminal
	}
	if existing, exists := registry.pending[eventID]; exists {
		// 一条连接只有一个 $events 代次；同 eventId 不允许改绑到别的会话或代次。
		if existing.SessionID != interaction.SessionID || existing.Event != interaction.Event ||
			existing.Generation != interaction.Generation {
			return harnessNativeDeliveryInvalid
		}
		// 保留首次投递的请求与 Responding，不因重复帧改写正在回传的决定。
		return harnessNativeDeliveryDuplicate
	}
	if len(registry.pending) >= harnessNativeInteractionPendingMax {
		return harnessNativeDeliveryFull
	}
	registry.pending[eventID] = &interaction
	return harnessNativeDeliveryNew
}

// cancelDelivered 对未知事件仍记终态，防止 cancel 先于 waterfall 时复活；
// 只有本连接已经收到的交互才向下游发撤卡，不泄露其它会话的 eventId。
func (registry *harnessNativeInteractionRegistry) cancelDelivered(eventID string) bool {
	eventID = strings.TrimSpace(eventID)
	if eventID == "" {
		return false
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	_, delivered := registry.pending[eventID]
	delete(registry.pending, eventID)
	registry.markTerminalLocked(eventID)
	return delivered
}

// pendingCount 报告当前等待应答的交互条数，供资源上限与诊断使用。
func (registry *harnessNativeInteractionRegistry) pendingCount() int {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	return len(registry.pending)
}

// harnessNativeClaimResult 是一次应答认领的结论。
type harnessNativeClaimResult int

const (
	// harnessNativeClaimAccepted：该交互已投递给本连接且仍待应答，可以转发上游。
	harnessNativeClaimAccepted harnessNativeClaimResult = iota
	// harnessNativeClaimSettled：该交互已终结。迟到应答是空操作，不转发、不报错。
	harnessNativeClaimSettled
)

// claim 认领一次应答。
//
// 只有"已投递 + 仍 pending + 代次匹配 + 尚未有人认领"才允许转发上游。其余情况
// 分两类处理，这个区分是安全边界的一部分：
//
//   - 已终结 → 空操作。契约规定迟到应答是空操作而非错误，转发只会得到上游的
//     lookup-not-found，没有意义。
//   - 其它（从未投递、代次不符、已被他人认领）→ 拒绝。这才是伪造：跨设备、跨会话
//     或跨代次拿一个 eventId 来替别人做决定。拒绝且**不触达上游**。
func (registry *harnessNativeInteractionRegistry) claim(
	eventID string,
	generation uint64,
) (*harnessNativeInteraction, harnessNativeClaimResult, error) {
	eventID = strings.TrimSpace(eventID)
	if eventID == "" {
		return nil, 0, harnessNativeReject(http.StatusBadRequest, "eventId 不能为空")
	}

	registry.mu.Lock()
	defer registry.mu.Unlock()

	pending, ok := registry.pending[eventID]
	if !ok {
		if registry.isTerminalLocked(eventID) {
			return nil, harnessNativeClaimSettled, nil
		}
		// 从未投递给本连接的 eventId。这可能是伪造，也可能是上游重投到了另一条
		// 连接；两种都不该由本连接来应答。
		return nil, 0, harnessNativeReject(http.StatusForbidden, "该交互未投递给本连接，拒绝转发")
	}
	if pending.Generation != generation {
		// 旧代次的卡片不得替新连接做决定。
		return nil, 0, harnessNativeReject(http.StatusForbidden, "连接代次已失效，请重新订阅后再应答")
	}
	if pending.Responding {
		return nil, 0, harnessNativeReject(http.StatusConflict, "该交互正在应答中")
	}
	pending.Responding = true
	// 不把仍由注册表持有的可变记录指针交给读协程。
	snapshot := *pending
	return &snapshot, harnessNativeClaimAccepted, nil
}

// release 放弃一次已认领但未能转发的应答，让卡片回到待应答状态。
//
// 仅用于尚未发送或已收到明确失败的情况。上游传输失败、结果未知时不调用它：
// 网关结束当前连接，交由 Harness 在新连接上重投仍 pending 的交互。
func (registry *harnessNativeInteractionRegistry) release(eventID string) {
	eventID = strings.TrimSpace(eventID)
	if eventID == "" {
		return
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if pending, ok := registry.pending[eventID]; ok {
		pending.Responding = false
	}
}

// settle 终结一条交互：从待应答表移除并记入终态，阻止同一 eventId 复活。
func (registry *harnessNativeInteractionRegistry) settle(eventID string) {
	eventID = strings.TrimSpace(eventID)
	if eventID == "" {
		return
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	delete(registry.pending, eventID)
	registry.markTerminalLocked(eventID)
}

// forgetSession 仅在实际撤权时丢弃该会话的全部待应答交互，普通 follow 退订不调用。
//
// 撤权必须让旧卡片立刻失效：否则一个已经不该看见该会话的客户端，仍能对
// 撤权前收到的卡片做出决定。
//
// 这里**只删待应答记录，不记终态**——与 settle 的差别是刻意的，两者语义不同：
//
//   - settle 是「这条已被合法应答」，重复应答是良性空操作；
//   - forgetSession 是「这个绑定已失去授权」，此后再来的应答是**越权**，
//     必须被拒绝而不是被当成迟到的空操作。
//
// 不记终态还让会话重新获得授权后可以正常收到重投的卡片；重复投递本身
// 会先过授权检查，因此不需要靠终态来兜底。
func (registry *harnessNativeInteractionRegistry) forgetSession(sessionID string) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	for eventID, pending := range registry.pending {
		if pending.SessionID == sessionID {
			delete(registry.pending, eventID)
		}
	}
}

// --- 应答形状校验 ---

// harnessNativeOutcome 是 $events/result 的 outcome。
//
// 三种 kind（next / result / rejected）都来自契约 §2.8 与
// `rpc/events-result.json`。注意该夹具是**源码级**（实跑未触发审批），
// 因此这里的校验一律 fail closed：形状不符即拒绝，不静默降级。
type harnessNativeOutcome struct {
	Kind  string          `json:"kind"`
	Value json.RawMessage `json:"value,omitempty"`
	Error *struct {
		Name    string          `json:"name"`
		Message string          `json:"message"`
		Code    string          `json:"code,omitempty"`
		Details json.RawMessage `json:"details,omitempty"`
	} `json:"error,omitempty"`
}

// 审批结论取值域，逐字取自契约 §2.8。
var harnessNativeApprovalDecisions = map[string]struct{}{
	harnessclient.OutcomeAllowedOnce: {},
	harnessclient.OutcomeRejected:    {},
	harnessclient.OutcomeCancelled:   {},
	harnessclient.OutcomeUnavailable: {},
}

// harnessNativeValidateOutcome 严格校验一个 outcome，并按交互类型核对取值域。
//
// event 决定 result 的 value 该长什么样：审批是四个字符串结论之一，追问是
// 结构化 answers。把两者混用（例如对审批回一个 answers 对象）会向上游送出
// 语义错误的决定，因此在这里就挡掉。
func harnessNativeValidateOutcome(event string, raw json.RawMessage) (harnessNativeOutcome, error) {
	var outcome harnessNativeOutcome
	if err := harnessNativeDecodeStrict(raw, &outcome); err != nil {
		return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "outcome 不是合法对象")
	}
	switch outcome.Kind {
	case harnessclient.OutcomeKindNext:
		// 链式 waterfall 的中间确认，只带 kind。
		return outcome, nil

	case harnessclient.OutcomeKindRejected:
		if outcome.Error == nil || strings.TrimSpace(outcome.Error.Name) == "" {
			return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "rejected outcome 必须带 error.name")
		}
		return outcome, nil

	case harnessclient.OutcomeKindResult:
		// 下面按交互类型继续校验 value。

	default:
		return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "未知 outcome kind")
	}

	switch event {
	case harnessclient.WaterfallApprovalRequest:
		var decision string
		if err := json.Unmarshal(outcome.Value, &decision); err != nil {
			return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "审批应答必须是字符串结论")
		}
		if _, ok := harnessNativeApprovalDecisions[decision]; !ok {
			return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "审批结论不在允许取值域内")
		}
	case harnessclient.WaterfallUserQuestions:
		var answer struct {
			Answers []harnessclient.Answer `json:"answers"`
		}
		if err := harnessNativeDecodeStrict(outcome.Value, &answer); err != nil {
			return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "追问应答必须是 {answers:[…]}")
		}
		if len(answer.Answers) == 0 {
			return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "追问应答至少要有一条答案")
		}
		for _, item := range answer.Answers {
			if strings.TrimSpace(item.ID) == "" {
				return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "追问答案缺少 question id")
			}
		}
	default:
		// 认不出的交互类型：不猜它的 value 形状。
		return harnessNativeOutcome{}, harnessNativeReject(http.StatusBadRequest, "未知交互类型，拒绝转发应答")
	}
	return outcome, nil
}
