package pushbridge

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"time"
)

// 一次性动作句柄。锁屏上的「允许 / 拒绝」带回来的是 action_id，agentd 必须在
// 这里原子完成校验与状态迁移：过期、撤销、会话结束、重复提交、冲突决策都要在
// 触达 runtime 之前被挡住。
//
// 句柄只存在于内存。agentd 重启后全部消失，runtime 侧的待审批请求继续
// fail closed，不会因为一个陈旧的 action_id 被误批准。
const (
	// 与 Provider 的 approval_max_expiry 对齐；锁屏卡片不应比这更久还宣称可点。
	DefaultActionTTL = 5 * time.Minute
	maxActions       = 128
)

type ActionState string

const (
	StatePending   ActionState = "pending"
	StateExecuting ActionState = "executing"
	StateApproved  ActionState = "approved"
	StateRejected  ActionState = "rejected"
	StateExpired   ActionState = "expired"
	StateRevoked   ActionState = "revoked"
)

type Decision string

const (
	DecisionAllow Decision = "allow"
	DecisionDeny  Decision = "deny"
)

func (d Decision) Valid() bool { return d == DecisionAllow || d == DecisionDeny }

// Outcome 决定 HTTP 层返回什么。它刻意区分「重复提交」与「冲突决策」：
// 前者要幂等地回放既有结果，后者必须拒绝，不能让第二个决策覆盖第一个。
type Outcome string

const (
	OutcomeProceed    Outcome = "proceed"
	OutcomeIdempotent Outcome = "idempotent"
	OutcomeConflict   Outcome = "conflict"
	OutcomeGone       Outcome = "gone"
	OutcomeNotFound   Outcome = "not_found"
	OutcomeForbidden  Outcome = "forbidden"
	OutcomeBusy       Outcome = "busy"
)

// Action 绑定一次审批请求。RequestID 是 runtime 侧原始 JSON-RPC id，
// SessionKey 是 gateway 具名会话，二者共同决定这个句柄能作用在谁身上。
type Action struct {
	ID         string
	Runtime    string
	SessionKey string
	ThreadID   string
	RequestID  string
	Method     string
	Kind       string
	DeviceIDs  []string
	IssuedAt   time.Time
	ExpiresAt  time.Time
	State      ActionState
	Decision   Decision
}

func (a Action) Terminal() bool {
	switch a.State {
	case StateApproved, StateRejected, StateExpired, StateRevoked:
		return true
	}
	return false
}

var errActionStoreFull = errors.New("待审批动作过多")

type ActionStore struct {
	mu      sync.Mutex
	actions map[string]*Action
	ttl     time.Duration
	now     func() time.Time
}

func NewActionStore(ttl time.Duration) *ActionStore {
	if ttl <= 0 {
		ttl = DefaultActionTTL
	}
	return &ActionStore{actions: map[string]*Action{}, ttl: ttl, now: time.Now}
}

// Issue 为一次待审批请求签发句柄。action_id 至少 128 bit 随机，只在本机保存；
// 它本身不足以执行审批，请求仍必须通过 agentd 的 Bearer 鉴权和设备绑定校验。
// 返回值中的 created 区分「新签发」与「命中既有句柄」：只有新签发才推送，
// 否则同一个请求会在锁屏上堆出第二张卡片。
func (s *ActionStore) Issue(action Action, deviceIDs []string) (Action, bool, error) {
	id, err := randomActionID()
	if err != nil {
		return Action{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.pruneLocked(now)
	// 命中既有句柄要先于容量判断：重复请求不应该因为表满而失败。
	if existing := s.findLocked(action.Runtime, action.SessionKey, action.RequestID); existing != nil {
		return *existing, false, nil
	}
	if len(s.actions) >= maxActions {
		return Action{}, false, errActionStoreFull
	}
	action.ID = id
	action.IssuedAt = now
	action.ExpiresAt = now.Add(s.ttl)
	action.State = StatePending
	action.DeviceIDs = append([]string(nil), deviceIDs...)
	s.actions[id] = &action
	return action, true, nil
}

// Begin 是唯一的决策入口。它在同一把锁内完成有效期、绑定、状态和幂等校验，
// 只有返回 OutcomeProceed 才允许继续调用 runtime。
func (s *ActionStore) Begin(actionID string, deviceID string, decision Decision) (Action, Outcome) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.pruneLocked(now)
	action, ok := s.actions[actionID]
	if !ok {
		return Action{}, OutcomeNotFound
	}
	if !decision.Valid() {
		return *action, OutcomeConflict
	}
	if !action.allowsDevice(deviceID) {
		// 句柄泄漏到另一台未注册设备时，绑定校验是最后一道闸。
		return *action, OutcomeForbidden
	}
	if !now.Before(action.ExpiresAt) {
		action.State = StateExpired
		return *action, OutcomeGone
	}
	switch action.State {
	case StateExpired, StateRevoked:
		return *action, OutcomeGone
	case StateExecuting:
		// 上一次决策还在跑。重复点击不应并发调用 runtime。
		return *action, OutcomeBusy
	case StateApproved, StateRejected:
		if action.Decision == decision {
			// 同设备同决策重放：回放既有结果，不再次调用 runtime。
			return *action, OutcomeIdempotent
		}
		return *action, OutcomeConflict
	}
	action.State = StateExecuting
	action.Decision = decision
	return *action, OutcomeProceed
}

// Settle 在 runtime 已经接受决策后落定终态。
func (s *ActionStore) Settle(actionID string, decision Decision) {
	s.mu.Lock()
	defer s.mu.Unlock()
	action, ok := s.actions[actionID]
	if !ok || action.State != StateExecuting {
		return
	}
	if decision == DecisionAllow {
		action.State = StateApproved
	} else {
		action.State = StateRejected
	}
}

// Fail 把执行失败的句柄放回 pending，让用户可以重试。网络超时不能被当成
// 已批准，也不能永久锁死这次审批。
func (s *ActionStore) Fail(actionID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	action, ok := s.actions[actionID]
	if !ok || action.State != StateExecuting {
		return
	}
	action.State = StatePending
	action.Decision = ""
}

// Revoke 在前台已处理、runtime 超时、turn 结束或会话关闭时作废句柄。
// 返回被作废的句柄，供调用方清理对应通知。
func (s *ActionStore) Revoke(runtime string, sessionKey string, requestID string) []Action {
	s.mu.Lock()
	defer s.mu.Unlock()
	revoked := []Action{}
	for _, action := range s.actions {
		if action.Runtime != runtime || action.SessionKey != sessionKey {
			continue
		}
		if requestID != "" && action.RequestID != requestID {
			continue
		}
		if action.Terminal() {
			continue
		}
		action.State = StateRevoked
		revoked = append(revoked, *action)
	}
	return revoked
}

// RevokeSession 作废整个会话的句柄，只用于 broker / 观察连接回收——那时候
// 确实没人能再代替用户回答任何一条了。
func (s *ActionStore) RevokeSession(runtime string, sessionKey string) []Action {
	return s.Revoke(runtime, sessionKey, "")
}

// RevokeThread 只作废某个 thread 的句柄。
//
// 一个 gateway 会话覆盖该安装下的全部 thread，所以 turn 结束、thread 关闭这类
// 事件绝不能按会话作废：A 线程跑完一个 turn，不该把 B 线程上还等着的审批一起
// 撤掉。
func (s *ActionStore) RevokeThread(runtime string, sessionKey string, threadID string) []Action {
	s.mu.Lock()
	defer s.mu.Unlock()
	revoked := []Action{}
	for _, action := range s.actions {
		if action.Runtime != runtime || action.SessionKey != sessionKey ||
			action.ThreadID != threadID || action.Terminal() {
			continue
		}
		action.State = StateRevoked
		revoked = append(revoked, *action)
	}
	return revoked
}

func (s *ActionStore) Get(actionID string) (Action, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(s.now())
	action, ok := s.actions[actionID]
	if !ok {
		return Action{}, false
	}
	return *action, true
}

func (s *ActionStore) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.actions)
}

func (a *Action) allowsDevice(deviceID string) bool {
	if deviceID == "" {
		return false
	}
	for _, allowed := range a.DeviceIDs {
		if allowed == deviceID {
			return true
		}
	}
	return false
}

func (s *ActionStore) findLocked(runtime string, sessionKey string, requestID string) *Action {
	for _, action := range s.actions {
		if action.Runtime == runtime && action.SessionKey == sessionKey &&
			action.RequestID == requestID && !action.Terminal() {
			return action
		}
	}
	return nil
}

// pruneLocked 丢掉过期与早已落定的句柄。终态句柄保留一个短窗口，让重复投递的
// 通知仍能拿到「已处理」而不是「未知句柄」。
func (s *ActionStore) pruneLocked(now time.Time) {
	for id, action := range s.actions {
		if now.Before(action.ExpiresAt) {
			continue
		}
		if action.Terminal() && now.Sub(action.ExpiresAt) < s.ttl {
			continue
		}
		if !action.Terminal() {
			action.State = StateExpired
			if now.Sub(action.ExpiresAt) < s.ttl {
				continue
			}
		}
		delete(s.actions, id)
	}
}

func randomActionID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return "act-" + hex.EncodeToString(buf), nil
}
