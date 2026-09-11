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
	mu      sync.RWMutex
	routes  *RouteStore
	enabled bool
	// 在途投递计数：定位记录在投递 goroutine 里落盘，关闭时必须等它们结束再做最后一次
	// Flush，否则测试临时目录和真实关机都可能在写盘中途被拆掉。
	deliveries sync.WaitGroup
	closeMu    sync.Mutex
	closed     bool
	client     *Client
	devices    *DeviceStore
	actions    *ActionStore
	hostTag    string
	profile    string
	install    string
	environ    string
	notifyer   func(ctx context.Context, notification Notification) error
	now        func() time.Time
}

type Options struct {
	Enabled        bool
	ProviderURL    string
	Environment    string
	InstallationID string
	DeviceStore    *DeviceStore
	// RouteStore 为空时定位记录只留在内存：行为与落盘版本完全一致，只是不跨重启。
	RouteStore *RouteStore
	ActionTTL  time.Duration
}

func NewManager(options Options) *Manager {
	client := NewClient(options.ProviderURL)
	environment := strings.TrimSpace(options.Environment)
	if environment == "" {
		environment = "production"
	}
	routes := options.RouteStore
	if routes == nil {
		routes = NewRouteStore("")
	}
	manager := &Manager{
		// Provider 没配置就等于没开：这样「忘了配 URL」不会变成静默失败的推送。
		enabled: options.Enabled && client.Configured(),
		client:  client,
		devices: options.DeviceStore,
		routes:  routes,
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
func (m *Manager) Routes() *RouteStore    { return m.routes }
func (m *Manager) Client() *Client        { return m.client }
func (m *Manager) ProfileID() string      { return m.profile }
func (m *Manager) InstallationID() string { return m.install }

// ApprovalRequest 是 runtime 侧待审批请求的脱敏投影。它刻意不含命令、diff 或
// 任何模型输出 —— 那些内容不参与推送链路。CWD 只是线程工作目录，用于重启后
// 按当前作用域配置恢复线程授权，它不出 Mac。
type ApprovalRequest struct {
	Runtime    string
	SessionKey string
	ThreadID   string
	ProjectID  string
	ScopeID    string
	CWD        string
	ReadOnly   bool
	RequestID  string
	Method     string
}

// PreparedDelivery 只包含 Provider 网络投递。ActionStore 的签发或撤销已经在
// Prepare* 返回前同步完成，调用方因此可以先建立确定的状态顺序，再异步执行网络。
type PreparedDelivery func(context.Context)

// NotifyPending 在待审批请求出现时签发一次性句柄并向已注册设备推送提醒。
// 它必须永不阻塞 runtime：Provider 或 APNs 不可用时只记录有界错误。
func (m *Manager) NotifyPending(ctx context.Context, request ApprovalRequest) (Action, bool) {
	action, delivery, created := m.PreparePending(request)
	if delivery != nil {
		delivery(ctx)
	}
	return action, created
}

// PreparePending 同步签发 Action，只把可能阻塞的 Provider 投递留给返回的闭包。
func (m *Manager) PreparePending(request ApprovalRequest) (Action, PreparedDelivery, bool) {
	if !m.Enabled() {
		return Action{}, nil, false
	}
	kind, ok := ApprovalKindForMethod(request.Method)
	if !ok {
		// 未登记的审批方法不推送：宁可少一条提醒，也不把未知语义推上锁屏。
		return Action{}, nil, false
	}
	devices := m.devices.Active()
	if len(devices) == 0 {
		return Action{}, nil, false
	}
	deviceIDs := make([]string, 0, len(devices))
	for _, device := range devices {
		deviceIDs = append(deviceIDs, device.ID)
	}
	action, created, err := m.actions.Issue(Action{
		Runtime:    request.Runtime,
		SessionKey: request.SessionKey,
		ThreadID:   request.ThreadID,
		ProjectID:  request.ProjectID,
		ScopeID:    request.ScopeID,
		CWD:        request.CWD,
		ReadOnly:   request.ReadOnly,
		RequestID:  request.RequestID,
		Method:     request.Method,
		Kind:       kind,
	}, deviceIDs)
	if err != nil {
		log.Printf("push bridge 无法签发审批动作 runtime=%s err=%v", request.Runtime, err)
		return Action{}, nil, false
	}
	if !created {
		// 已经推送过的同一请求不再重复打扰。
		return action, nil, false
	}
	// 定位记录与句柄同 id、同设备集，但寿命更长：审批窗口只有几分钟，而用户
	// 可能几小时后才点开通知——那时仍应能打开会话看结果，只是不再能批准。
	m.routes.Insert(m.now(), LocateRecord{
		ID:           action.ID,
		Kind:         RouteKindApproval,
		Runtime:      action.Runtime,
		ThreadID:     action.ThreadID,
		ProjectID:    action.ProjectID,
		ScopeID:      action.ScopeID,
		CWD:          action.CWD,
		ReadOnly:     action.ReadOnly,
		ApprovalKind: action.Kind,
		DeviceIDs:    deviceIDs,
		CreatedAt:    action.IssuedAt,
		ExpiresAt:    action.IssuedAt.Add(routeTTL),
	})
	return action, func(ctx context.Context) {
		// 与消息一致：定位记录在投递 goroutine 中落盘，审批 broker 的锁内不做磁盘写入。
		m.routes.Flush()
		m.fanout(ctx, action, EventApprovalPending, devices)
	}, true
}

// Resolve 在审批被处理（无论来自前台、另一台设备还是 runtime 超时）后作废句柄，
// 并尽力向其余设备发送静默状态更新，让它们清理已经不可操作的通知。
func (m *Manager) Resolve(ctx context.Context, runtime string, sessionKey string, requestID string) {
	if delivery := m.PrepareResolve(runtime, sessionKey, requestID); delivery != nil {
		delivery(ctx)
	}
}

// PrepareResolve 同步撤销句柄，只把静默清理通知留给返回的闭包。
func (m *Manager) PrepareResolve(runtime string, sessionKey string, requestID string) PreparedDelivery {
	if !m.Enabled() {
		return nil
	}
	revoked := m.actions.Revoke(runtime, sessionKey, requestID)
	if len(revoked) == 0 {
		return nil
	}
	devices := m.devices.Active()
	return func(ctx context.Context) {
		for _, action := range revoked {
			m.fanout(ctx, action, EventApprovalResolved, devices)
		}
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
	if delivery := m.PrepareResolveThread(runtime, sessionKey, threadID); delivery != nil {
		delivery(ctx)
	}
}

// PrepareResolveThread 是 ResolveThread 的同步状态阶段。
func (m *Manager) PrepareResolveThread(runtime string, sessionKey string, threadID string) PreparedDelivery {
	if !m.Enabled() || strings.TrimSpace(threadID) == "" {
		return nil
	}
	revoked := m.actions.RevokeThread(runtime, sessionKey, threadID)
	if len(revoked) == 0 {
		return nil
	}
	devices := m.devices.Active()
	return func(ctx context.Context) {
		for _, action := range revoked {
			m.fanout(ctx, action, EventApprovalResolved, devices)
		}
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

// fanout 并行投递最多 8 台已注册设备。每台设备从同一时刻取得独立超时预算，
// 单台慢请求不会耗尽后续设备的时间；Provider 报告设备失效时删除本地注册。
func (m *Manager) fanout(ctx context.Context, action Action, event string, devices []Device) {
	if len(devices) == 0 {
		return
	}
	expiresAt := action.ExpiresAt.UTC().Format(time.RFC3339)
	var deliveries sync.WaitGroup
	for _, device := range devices {
		device := device
		deliveries.Add(1)
		go func() {
			defer deliveries.Done()
			deviceCtx, cancel := context.WithTimeout(ctx, providerTimeout)
			defer cancel()
			notification := Notification{
				Event:        event,
				Ticket:       device.Ticket,
				ActionID:     action.ID,
				DeviceID:     device.ID,
				ProfileID:    m.profile,
				Runtime:      action.Runtime,
				ApprovalKind: action.Kind,
				HostTag:      m.hostTag,
				SessionTag:   notificationSessionTag(event, action.ThreadID),
				ExpiresAt:    expiresAt,
			}
			if err := m.notifyer(deviceCtx, notification); err != nil {
				if errors.Is(err, ErrDeviceUnregistered) {
					if _, removed, removeErr := m.devices.RemoveIfTicket(device.ID, device.Ticket); removeErr != nil {
						log.Printf("push bridge 删除失效设备失败 err=%v", removeErr)
					} else if removed {
						m.actions.RevokeDevice(device.ID)
					}
					return
				}
				// 推送失败绝不阻塞 runtime，也不重试：前台链路仍然可用。
				log.Printf("push bridge 投递失败 event=%s err=%v", event, err)
			}
		}()
	}
	deliveries.Wait()
}

// PushDispatchTimeout 是单次投递（含落盘与 Provider 调用）的总时限。
const PushDispatchTimeout = 15 * time.Second

// Dispatch 在独立 goroutine 中执行一次投递并计入在途计数；Close 之后的投递直接丢弃，
// 前台链路不受影响。调用方不再自行 go func，避免关闭后仍有 goroutine 往磁盘写记录。
func (m *Manager) Dispatch(delivery PreparedDelivery, timeout time.Duration) {
	if m == nil || delivery == nil {
		return
	}
	m.closeMu.Lock()
	if m.closed {
		m.closeMu.Unlock()
		return
	}
	m.deliveries.Add(1)
	m.closeMu.Unlock()
	go func() {
		defer m.deliveries.Done()
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		delivery(ctx)
	}()
}

// Close 拒绝新的投递、等待在途投递结束，并把最新的定位记录快照写盘。幂等。
func (m *Manager) Close() {
	if m == nil {
		return
	}
	m.closeMu.Lock()
	if m.closed {
		m.closeMu.Unlock()
		return
	}
	m.closed = true
	m.closeMu.Unlock()
	m.deliveries.Wait()
	if m.routes != nil {
		m.routes.Flush()
	}
}
