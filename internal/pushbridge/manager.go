package pushbridge

import (
	"context"
	"errors"
	"log"
	"strings"
	"sync"
	"time"
)

// Manager 把设备注册表、动作句柄与 Provider 客户端连成一条闭环，并对 Codex 与
// Claude Code 两条 runtime 提供同一个入口。
//
// 默认关闭。未启用或 Provider 未配置时，所有入口都是空操作 —— 升级后的行为与
// 今天逐字一致，不会产生任何对外请求。
type Manager struct {
	mu       sync.RWMutex
	enabled  bool
	client   *Client
	devices  *DeviceStore
	actions  *ActionStore
	hostTag  string
	profile  string
	install  string
	environ  string
	notifyer func(ctx context.Context, notification Notification) error
	now      func() time.Time
}

type Options struct {
	Enabled        bool
	ProviderURL    string
	Environment    string
	InstallationID string
	DeviceStore    *DeviceStore
	ActionTTL      time.Duration
}

func NewManager(options Options) *Manager {
	client := NewClient(options.ProviderURL)
	environment := strings.TrimSpace(options.Environment)
	if environment == "" {
		environment = "production"
	}
	manager := &Manager{
		// Provider 没配置就等于没开：这样「忘了配 URL」不会变成静默失败的推送。
		enabled: options.Enabled && client.Configured(),
		client:  client,
		devices: options.DeviceStore,
		actions: NewActionStore(options.ActionTTL),
		hostTag: HostTag(options.InstallationID),
		profile: ProfileTag(options.InstallationID),
		install: options.InstallationID,
		environ: environment,
		now:     time.Now,
	}
	manager.notifyer = client.Notify
	return manager
}

func (m *Manager) Enabled() bool {
	if m == nil {
		return false
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.enabled && m.devices != nil
}

func (m *Manager) Environment() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.environ
}

func (m *Manager) Actions() *ActionStore  { return m.actions }
func (m *Manager) Devices() *DeviceStore  { return m.devices }
func (m *Manager) Client() *Client        { return m.client }
func (m *Manager) ProfileID() string      { return m.profile }
func (m *Manager) InstallationID() string { return m.install }

// ApprovalRequest 是 runtime 侧待审批请求的脱敏投影。它刻意不含命令、路径、
// diff 或任何模型输出 —— 那些内容不参与推送链路。
type ApprovalRequest struct {
	Runtime    string
	SessionKey string
	ThreadID   string
	RequestID  string
	Method     string
}

// NotifyPending 在待审批请求出现时签发一次性句柄并向已注册设备推送提醒。
// 它必须永不阻塞 runtime：Provider 或 APNs 不可用时只记录有界错误。
func (m *Manager) NotifyPending(ctx context.Context, request ApprovalRequest) (Action, bool) {
	if !m.Enabled() {
		return Action{}, false
	}
	kind, ok := ApprovalKindForMethod(request.Method)
	if !ok {
		// 未登记的审批方法不推送：宁可少一条提醒，也不把未知语义推上锁屏。
		return Action{}, false
	}
	devices := m.devices.Active()
	if len(devices) == 0 {
		return Action{}, false
	}
	deviceIDs := make([]string, 0, len(devices))
	for _, device := range devices {
		deviceIDs = append(deviceIDs, device.ID)
	}
	action, created, err := m.actions.Issue(Action{
		Runtime:    request.Runtime,
		SessionKey: request.SessionKey,
		ThreadID:   request.ThreadID,
		RequestID:  request.RequestID,
		Method:     request.Method,
		Kind:       kind,
	}, deviceIDs)
	if err != nil {
		log.Printf("push bridge 无法签发审批动作 runtime=%s err=%v", request.Runtime, err)
		return Action{}, false
	}
	if !created {
		// 已经推送过的同一请求不再重复打扰。
		return action, false
	}
	m.fanout(ctx, action, EventApprovalPending, devices)
	return action, true
}

// Resolve 在审批被处理（无论来自前台、另一台设备还是 runtime 超时）后作废句柄，
// 并尽力向其余设备发送静默状态更新，让它们清理已经不可操作的通知。
func (m *Manager) Resolve(ctx context.Context, runtime string, sessionKey string, requestID string) {
	if !m.Enabled() {
		return
	}
	revoked := m.actions.Revoke(runtime, sessionKey, requestID)
	if len(revoked) == 0 {
		return
	}
	devices := m.devices.Active()
	for _, action := range revoked {
		m.fanout(ctx, action, EventApprovalResolved, devices)
	}
}

// ResolveSession 只在 gateway 会话整体回收时使用：那时候确实没人能再代替
// 用户回答任何一条。
func (m *Manager) ResolveSession(ctx context.Context, runtime string, sessionKey string) {
	m.Resolve(ctx, runtime, sessionKey, "")
}

// ResolveThread 用于 turn 结束、thread 关闭这类只影响单个 thread 的事件。
// 一个 gateway 会话覆盖多个 thread，按会话作废会误伤其它线程上的待审批。
func (m *Manager) ResolveThread(ctx context.Context, runtime string, sessionKey string, threadID string) {
	if !m.Enabled() || strings.TrimSpace(threadID) == "" {
		return
	}
	revoked := m.actions.RevokeThread(runtime, sessionKey, threadID)
	if len(revoked) == 0 {
		return
	}
	devices := m.devices.Active()
	for _, action := range revoked {
		m.fanout(ctx, action, EventApprovalResolved, devices)
	}
}

// Decide 是锁屏动作的落点。resolve 只有在状态机放行后才会被调用一次；它负责把
// 决策真正交给 runtime，失败时句柄回到 pending 让用户可以重试。
func (m *Manager) Decide(
	ctx context.Context,
	actionID string,
	deviceID string,
	decision Decision,
	resolve func(context.Context, Action, Decision) error,
) (Action, Outcome, error) {
	if !m.Enabled() {
		return Action{}, OutcomeNotFound, errors.New("锁屏审批提醒未启用")
	}
	action, outcome := m.actions.Begin(actionID, deviceID, decision)
	if outcome != OutcomeProceed {
		return action, outcome, nil
	}
	if err := resolve(ctx, action, decision); err != nil {
		m.actions.Fail(actionID)
		return action, OutcomeProceed, err
	}
	m.actions.Settle(actionID, decision)
	settled, _ := m.actions.Get(actionID)
	// 其余设备上的旧通知必须被撤下：审批已经不可再操作。
	go m.fanoutResolved(context.WithoutCancel(ctx), settled, deviceID)
	return settled, OutcomeProceed, nil
}

func (m *Manager) fanoutResolved(ctx context.Context, action Action, excludeDeviceID string) {
	devices := m.devices.Active()
	filtered := make([]Device, 0, len(devices))
	for _, device := range devices {
		if device.ID == excludeDeviceID {
			continue
		}
		filtered = append(filtered, device)
	}
	m.fanout(ctx, action, EventApprovalResolved, filtered)
}

// fanout 逐台设备投递。单台失败不影响其它设备；Provider 报告设备失效时直接
// 删除本地注册，避免继续对死 Token 投递。
func (m *Manager) fanout(ctx context.Context, action Action, event string, devices []Device) {
	if len(devices) == 0 {
		return
	}
	expiresAt := action.ExpiresAt.UTC().Format(time.RFC3339)
	for _, device := range devices {
		notification := Notification{
			Event:        event,
			Ticket:       device.Ticket,
			ActionID:     action.ID,
			DeviceID:     device.ID,
			ProfileID:    m.profile,
			Runtime:      action.Runtime,
			ApprovalKind: action.Kind,
			HostTag:      m.hostTag,
			SessionTag:   SessionTag(action.ThreadID),
			ExpiresAt:    expiresAt,
		}
		if err := m.notifyer(ctx, notification); err != nil {
			if errors.Is(err, ErrDeviceUnregistered) {
				if _, _, removeErr := m.devices.Remove(device.ID); removeErr != nil {
					log.Printf("push bridge 删除失效设备失败 err=%v", removeErr)
				}
				continue
			}
			// 推送失败绝不阻塞 runtime，也不重试：前台链路仍然可用。
			log.Printf("push bridge 投递失败 event=%s err=%v", event, err)
		}
	}
}
