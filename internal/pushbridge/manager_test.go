package pushbridge

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type recordedNotification struct {
	Event    string
	DeviceID string
	ActionID string
	Runtime  string
	Kind     string
	Ticket   string
}

type fakeProvider struct {
	mu            sync.Mutex
	sent          []recordedNotification
	failFor       map[string]error
	unregisterFor map[string]bool
}

func newFakeProvider() *fakeProvider {
	return &fakeProvider{failFor: map[string]error{}, unregisterFor: map[string]bool{}}
}

func (f *fakeProvider) notify(_ context.Context, notification Notification) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.unregisterFor[notification.DeviceID] {
		return ErrDeviceUnregistered
	}
	if err := f.failFor[notification.DeviceID]; err != nil {
		return err
	}
	f.sent = append(f.sent, recordedNotification{
		Event:    notification.Event,
		DeviceID: notification.DeviceID,
		ActionID: notification.ActionID,
		Runtime:  notification.Runtime,
		Kind:     notification.ApprovalKind,
		Ticket:   notification.Ticket,
	})
	return nil
}

func (f *fakeProvider) events(event string) []recordedNotification {
	f.mu.Lock()
	defer f.mu.Unlock()
	matched := []recordedNotification{}
	for _, sent := range f.sent {
		if sent.Event == event {
			matched = append(matched, sent)
		}
	}
	return matched
}

func newTestManager(t *testing.T, enabled bool, deviceIDs ...string) (*Manager, *fakeProvider) {
	t.Helper()
	store, err := NewDeviceStore(filepath.Join(t.TempDir(), "push-devices.json"))
	if err != nil {
		t.Fatal(err)
	}
	manager := NewManager(Options{
		Enabled:        enabled,
		ProviderURL:    "https://provider.example/mimi-push",
		Environment:    "production",
		InstallationID: "install-test",
		DeviceStore:    store,
	})
	provider := newFakeProvider()
	manager.notifyer = provider.notify
	for _, id := range deviceIDs {
		if _, err := store.Register(Device{
			ID:        id,
			Ticket:    "mpt1.1.ticket-for-" + id,
			Platform:  "ios",
			ExpiresAt: time.Now().Add(30 * 24 * time.Hour),
		}); err != nil {
			t.Fatal(err)
		}
	}
	return manager, provider
}

func codexApproval() ApprovalRequest {
	return ApprovalRequest{
		Runtime:    "codex",
		SessionKey: "session-1",
		ThreadID:   "thread-1",
		RequestID:  "req-1",
		Method:     "execCommandApproval",
	}
}

func claudeApproval() ApprovalRequest {
	return ApprovalRequest{
		Runtime:    "claude",
		SessionKey: "session-claude",
		ThreadID:   "thread-claude",
		RequestID:  "req-claude",
		Method:     "item/permissions/requestApproval",
	}
}

// Codex 与 Claude Code 两条链路必须走同一套句柄与枚举。
func TestNotifyPendingCoversBothRuntimes(t *testing.T) {
	manager, provider := newTestManager(t, true, "device-a")

	codexAction, sent := manager.NotifyPending(t.Context(), codexApproval())
	if !sent || codexAction.Kind != KindCommand || codexAction.Runtime != "codex" {
		t.Fatalf("Codex 审批未正确推送：sent=%v action=%+v", sent, codexAction)
	}
	claudeAction, sent := manager.NotifyPending(t.Context(), claudeApproval())
	if !sent || claudeAction.Kind != KindPermission || claudeAction.Runtime != "claude" {
		t.Fatalf("Claude 审批未正确推送：sent=%v action=%+v", sent, claudeAction)
	}
	if got := len(provider.events(EventApprovalPending)); got != 2 {
		t.Fatalf("两条 runtime 各应推送一次，got=%d", got)
	}
	if codexAction.ID == claudeAction.ID {
		t.Fatal("不同 runtime 的审批必须拿到不同句柄")
	}
}

func TestNotifyPendingFansOutToAllDevicesAndBindsThem(t *testing.T) {
	manager, provider := newTestManager(t, true, "device-a", "device-b")

	action, sent := manager.NotifyPending(t.Context(), codexApproval())
	if !sent {
		t.Fatal("应向已注册设备推送")
	}
	pending := provider.events(EventApprovalPending)
	if len(pending) != 2 {
		t.Fatalf("两台设备各应收到一次，got=%d", len(pending))
	}
	for _, event := range pending {
		if event.Ticket == "" || event.ActionID != action.ID {
			t.Fatalf("投递内容不完整：%+v", event)
		}
	}
	if len(action.DeviceIDs) != 2 {
		t.Fatalf("句柄应绑定两台设备，got=%v", action.DeviceIDs)
	}
}

// 同一个 runtime 请求重复触发时不能签发第二个句柄，否则锁屏会出现两张卡片。
func TestNotifyPendingIsIdempotentPerRequest(t *testing.T) {
	manager, provider := newTestManager(t, true, "device-a")

	first, _ := manager.NotifyPending(t.Context(), codexApproval())
	second, sent := manager.NotifyPending(t.Context(), codexApproval())
	if sent {
		t.Fatal("重复的同一请求不应再次推送")
	}
	if first.ID != second.ID {
		t.Fatalf("重复请求应复用同一句柄：%s vs %s", first.ID, second.ID)
	}
	if got := len(provider.events(EventApprovalPending)); got != 1 {
		t.Fatalf("重复请求只应推送一次，got=%d", got)
	}
}

// Action 状态必须在网络 goroutine 启动前落定。否则快速 resolved 可能先执行，
// 随后迟到的 pending goroutine 又签发一条已经无人能处理的旧句柄。
func TestPreparedPendingCanBeSynchronouslyRevokedBeforeDelivery(t *testing.T) {
	manager, provider := newTestManager(t, true, "device-a")

	action, pendingDelivery, created := manager.PreparePending(codexApproval())
	if !created || pendingDelivery == nil {
		t.Fatal("应同步签发待审批 Action")
	}
	resolvedDelivery := manager.PrepareResolve("codex", "session-1", "req-1")
	if resolvedDelivery == nil {
		t.Fatal("应同步撤销刚签发的 Action")
	}
	resolved, ok := manager.Actions().Get(action.ID)
	if !ok || resolved.State != StateRevoked {
		t.Fatalf("网络投递前 Action 就应为 revoked：ok=%v state=%s", ok, resolved.State)
	}
	if got := len(provider.events(EventApprovalPending)); got != 0 {
		t.Fatalf("Prepare 阶段不得执行 Provider 网络投递，got=%d", got)
	}

	pendingDelivery(t.Context())
	resolvedDelivery(t.Context())
	if got := len(provider.events(EventApprovalPending)); got != 1 {
		t.Fatalf("pending delivery 应只执行一次，got=%d", got)
	}
	if got := len(provider.events(EventApprovalResolved)); got != 1 {
		t.Fatalf("resolved delivery 应只执行一次，got=%d", got)
	}
}

func TestDecideAllowsOnceAndReplaysIdempotently(t *testing.T) {
	manager, _ := newTestManager(t, true, "device-a")
	action, _ := manager.NotifyPending(t.Context(), codexApproval())

	var resolveCalls int
	resolve := func(context.Context, Action, Decision) error {
		resolveCalls++
		return nil
	}
	settled, outcome, err := manager.Decide(t.Context(), action.ID, "device-a", DecisionAllow, resolve)
	if err != nil || outcome != OutcomeProceed || settled.State != StateApproved {
		t.Fatalf("首次允许应放行：outcome=%s state=%s err=%v", outcome, settled.State, err)
	}
	replayed, outcome, err := manager.Decide(t.Context(), action.ID, "device-a", DecisionAllow, resolve)
	if err != nil || outcome != OutcomeIdempotent {
		t.Fatalf("同设备同决策重放应幂等：outcome=%s err=%v", outcome, err)
	}
	if replayed.State != StateApproved {
		t.Fatalf("重放不应改变终态：%s", replayed.State)
	}
	if resolveCalls != 1 {
		t.Fatalf("runtime 只能被调用一次，got=%d", resolveCalls)
	}
}

func TestDecideRejectsConflictingAndUnauthorizedAttempts(t *testing.T) {
	manager, _ := newTestManager(t, true, "device-a", "device-b")
	action, _ := manager.NotifyPending(t.Context(), codexApproval())

	var resolveCalls int
	resolve := func(context.Context, Action, Decision) error {
		resolveCalls++
		return nil
	}
	if _, outcome, _ := manager.Decide(t.Context(), action.ID, "device-a", DecisionDeny, resolve); outcome != OutcomeProceed {
		t.Fatalf("首次拒绝应放行：%s", outcome)
	}
	// 另一台设备想把已经被拒绝的审批改成允许：必须冲突，不能覆盖。
	if _, outcome, _ := manager.Decide(t.Context(), action.ID, "device-b", DecisionAllow, resolve); outcome != OutcomeConflict {
		t.Fatalf("冲突决策应被拒绝：%s", outcome)
	}
	// 未注册设备拿着 action_id 重放：绑定校验是最后一道闸。
	if _, outcome, _ := manager.Decide(t.Context(), action.ID, "device-evil", DecisionAllow, resolve); outcome != OutcomeForbidden {
		t.Fatalf("未绑定设备应被拒绝：%s", outcome)
	}
	if _, outcome, _ := manager.Decide(t.Context(), "act-does-not-exist", "device-a", DecisionAllow, resolve); outcome != OutcomeNotFound {
		t.Fatalf("未知句柄应返回 not_found：%s", outcome)
	}
	if resolveCalls != 1 {
		t.Fatalf("只有第一次合法决策能触达 runtime，got=%d", resolveCalls)
	}
}

// 前台已经处理过的审批，锁屏上的旧通知不能再次生效。
func TestResolvedApprovalCannotBeExecutedAgain(t *testing.T) {
	manager, provider := newTestManager(t, true, "device-a")
	action, _ := manager.NotifyPending(t.Context(), codexApproval())

	manager.Resolve(t.Context(), "codex", "session-1", "req-1")
	if got := len(provider.events(EventApprovalResolved)); got != 1 {
		t.Fatalf("应向设备发送已处理状态更新，got=%d", got)
	}
	_, outcome, _ := manager.Decide(t.Context(), action.ID, "device-a", DecisionAllow,
		func(context.Context, Action, Decision) error {
			t.Fatal("已作废的句柄不能触达 runtime")
			return nil
		})
	if outcome != OutcomeGone {
		t.Fatalf("已作废句柄应返回 gone：%s", outcome)
	}
}

func TestExpiredActionIsGone(t *testing.T) {
	manager, _ := newTestManager(t, true, "device-a")
	action, _ := manager.NotifyPending(t.Context(), codexApproval())

	// 刚过期：用户点了一张略微陈旧的通知，必须明确告知已过期而不是未知句柄。
	manager.actions.now = func() time.Time { return time.Now().Add(DefaultActionTTL + time.Second) }
	_, outcome, _ := manager.Decide(t.Context(), action.ID, "device-a", DecisionAllow,
		func(context.Context, Action, Decision) error {
			t.Fatal("过期句柄不能触达 runtime")
			return nil
		})
	if outcome != OutcomeGone {
		t.Fatalf("过期句柄应返回 gone：%s", outcome)
	}

	// 早已过期的句柄会被清理掉，此后只能是未知句柄，同样不可执行。
	manager.actions.now = func() time.Time { return time.Now().Add(4 * DefaultActionTTL) }
	if _, outcome, _ := manager.Decide(t.Context(), action.ID, "device-a", DecisionAllow,
		func(context.Context, Action, Decision) error {
			t.Fatal("已清理的句柄不能触达 runtime")
			return nil
		}); outcome != OutcomeNotFound {
		t.Fatalf("已清理句柄应返回 not_found：%s", outcome)
	}
}

// 网络失败不能被当成成功，也不能永久锁死这次审批。
func TestFailedResolveReturnsActionToPending(t *testing.T) {
	manager, _ := newTestManager(t, true, "device-a")
	action, _ := manager.NotifyPending(t.Context(), codexApproval())

	_, _, err := manager.Decide(t.Context(), action.ID, "device-a", DecisionAllow,
		func(context.Context, Action, Decision) error { return errors.New("runtime 不可达") })
	if err == nil {
		t.Fatal("resolve 失败必须回传错误")
	}
	current, ok := manager.actions.Get(action.ID)
	if !ok || current.State != StatePending {
		t.Fatalf("失败后句柄应回到 pending 供重试：ok=%v state=%s", ok, current.State)
	}
	if _, outcome, err := manager.Decide(t.Context(), action.ID, "device-a", DecisionAllow,
		func(context.Context, Action, Decision) error { return nil }); err != nil || outcome != OutcomeProceed {
		t.Fatalf("重试应能成功：outcome=%s err=%v", outcome, err)
	}
}

func TestDisabledManagerNeverContactsProvider(t *testing.T) {
	manager, provider := newTestManager(t, false, "device-a")

	if _, sent := manager.NotifyPending(t.Context(), codexApproval()); sent {
		t.Fatal("未启用时不能推送")
	}
	manager.Resolve(t.Context(), "codex", "session-1", "req-1")
	if len(provider.sent) != 0 {
		t.Fatalf("未启用时不能产生任何对外请求，got=%d", len(provider.sent))
	}
	if _, _, err := manager.Decide(t.Context(), "act-x", "device-a", DecisionAllow,
		func(context.Context, Action, Decision) error { return nil }); err == nil {
		t.Fatal("未启用时决策入口应直接拒绝")
	}
}

// Provider 未配置时即使 enabled 也必须保持关闭，避免「忘了配 URL」变成静默失败。
func TestManagerStaysDisabledWithoutProviderURL(t *testing.T) {
	store, err := NewDeviceStore(filepath.Join(t.TempDir(), "push-devices.json"))
	if err != nil {
		t.Fatal(err)
	}
	manager := NewManager(Options{Enabled: true, DeviceStore: store, InstallationID: "install-test"})
	if manager.Enabled() {
		t.Fatal("没有 Provider URL 时不能视为已启用")
	}
}

func TestUnknownApprovalMethodIsNotPushed(t *testing.T) {
	manager, provider := newTestManager(t, true, "device-a")

	request := codexApproval()
	request.Method = "someRuntime/newApproval"
	if _, sent := manager.NotifyPending(t.Context(), request); sent {
		t.Fatal("未登记的审批方法不应推送")
	}
	if len(provider.sent) != 0 {
		t.Fatal("未登记方法不能产生投递")
	}
}

// APNs 报告设备失效后，本地注册必须被清掉，不能继续对死 Token 投递。
func TestUnregisteredDeviceIsRemoved(t *testing.T) {
	manager, provider := newTestManager(t, true, "device-a", "device-b")
	provider.mu.Lock()
	provider.unregisterFor["device-a"] = true
	provider.mu.Unlock()

	action, _ := manager.NotifyPending(t.Context(), codexApproval())
	if _, ok := manager.devices.Get("device-a"); ok {
		t.Fatal("失效设备应被删除")
	}
	if _, ok := manager.devices.Get("device-b"); !ok {
		t.Fatal("正常设备不应受影响")
	}
	if _, outcome, _ := manager.Decide(t.Context(), action.ID, "device-a", DecisionAllow,
		func(context.Context, Action, Decision) error {
			t.Fatal("失效设备不能再执行已签发的句柄")
			return nil
		}); outcome != OutcomeForbidden {
		t.Fatalf("失效设备的旧句柄应被拒绝：%s", outcome)
	}
	if _, outcome, err := manager.Decide(t.Context(), action.ID, "device-b", DecisionAllow,
		func(context.Context, Action, Decision) error { return nil }); err != nil || outcome != OutcomeProceed {
		t.Fatalf("正常设备仍应能处理同一审批：outcome=%s err=%v", outcome, err)
	}
}

func TestDeviceStorePersistsAndRotatesTicket(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push-devices.json")
	store, err := NewDeviceStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Register(Device{
		ID: "device-a", Ticket: "ticket-old", ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Register(Device{
		ID: "device-a", Ticket: "ticket-new", ExpiresAt: time.Now().Add(30 * 24 * time.Hour),
	}); err != nil {
		t.Fatal(err)
	}

	// agentd 重启：注册表必须还在，且是刷新后的 Ticket。
	reloaded, err := NewDeviceStore(path)
	if err != nil {
		t.Fatal(err)
	}
	device, ok := reloaded.Get("device-a")
	if !ok || device.Ticket != "ticket-new" {
		t.Fatalf("重启后应保留最新 Ticket：ok=%v ticket=%s", ok, device.Ticket)
	}
	if len(reloaded.Active()) != 1 {
		t.Fatalf("同一 device_id 重复注册应是刷新而不是新增，got=%d", len(reloaded.Active()))
	}
}

func TestDeviceStoreRollsBackMemoryWhenPersistenceFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push-devices.json")
	store, err := NewDeviceStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Register(Device{
		ID: "device-a", Ticket: "ticket-old", ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}

	// 把状态文件本身当成目录，稳定制造 MkdirAll/saveLocked 失败。
	store.path = filepath.Join(path, "child.json")
	if _, err := store.Register(Device{
		ID: "device-b", Ticket: "ticket-b", ExpiresAt: time.Now().Add(time.Hour),
	}); err == nil {
		t.Fatal("持久化失败时注册必须失败")
	}
	if _, ok := store.Get("device-b"); ok {
		t.Fatal("新增设备不能只留在内存中")
	}
	if _, err := store.Register(Device{
		ID: "device-a", Ticket: "ticket-new", ExpiresAt: time.Now().Add(time.Hour),
	}); err == nil {
		t.Fatal("持久化失败时刷新必须失败")
	}
	if device, ok := store.Get("device-a"); !ok || device.Ticket != "ticket-old" {
		t.Fatalf("刷新失败后应恢复旧 Ticket：ok=%v device=%+v", ok, device)
	}
	if _, removed, err := store.Remove("device-a"); err == nil || removed {
		t.Fatalf("持久化失败时删除不能报告成功：removed=%v err=%v", removed, err)
	}
	if _, ok := store.Get("device-a"); !ok {
		t.Fatal("删除失败后设备必须仍在内存中")
	}
}

func TestDeviceStoreDropsExpiredAndCapsCount(t *testing.T) {
	store, err := NewDeviceStore(filepath.Join(t.TempDir(), "push-devices.json"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Register(Device{
		ID: "expired", Ticket: "t", ExpiresAt: time.Now().Add(-time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	if len(store.Active()) != 0 {
		t.Fatal("过期 Ticket 不应参与投递")
	}
	for i := 0; i < MaxDevices; i++ {
		if _, err := store.Register(Device{
			ID: "device-" + string(rune('a'+i)), Ticket: "t", ExpiresAt: time.Now().Add(time.Hour),
		}); err != nil {
			t.Fatalf("注册第 %d 台设备失败: %v", i, err)
		}
	}
	if _, err := store.Register(Device{
		ID: "device-overflow", Ticket: "t", ExpiresAt: time.Now().Add(time.Hour),
	}); err == nil {
		t.Fatal("超出设备上限应被拒绝")
	}
}

// action_id 必须足够随机：它会出现在 APNs Payload 里，可被中间环节看到。
func TestActionIDsAreUnpredictable(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 256; i++ {
		id, err := randomActionID()
		if err != nil {
			t.Fatal(err)
		}
		if len(id) < 32 {
			t.Fatalf("action_id 太短：%s", id)
		}
		if seen[id] {
			t.Fatal("action_id 出现重复")
		}
		seen[id] = true
	}
}

// 一个 gateway 会话覆盖该安装下的全部 thread。turn 结束、thread 关闭只能撤掉
// 该 thread 的审批，否则 A 线程跑完一个 turn，会把 B 线程上还等着的审批一起
// 作废，用户在锁屏点下去只会得到「已过期」。
func TestThreadTerminalDoesNotRevokeOtherThreads(t *testing.T) {
	manager, provider := newTestManager(t, true, "device-a")

	threadA := ApprovalRequest{
		Runtime:    "codex",
		SessionKey: "session-1",
		ThreadID:   "thread-a",
		RequestID:  "req-a",
		Method:     "execCommandApproval",
	}
	threadB := ApprovalRequest{
		Runtime:    "codex",
		SessionKey: "session-1",
		ThreadID:   "thread-b",
		RequestID:  "req-b",
		Method:     "execCommandApproval",
	}
	actionA, _ := manager.NotifyPending(t.Context(), threadA)
	actionB, _ := manager.NotifyPending(t.Context(), threadB)

	manager.ResolveThread(t.Context(), "codex", "session-1", "thread-a")

	if current, _ := manager.actions.Get(actionA.ID); current.State != StateRevoked {
		t.Fatalf("本 thread 的句柄应被作废，got=%s", current.State)
	}
	current, ok := manager.actions.Get(actionB.ID)
	if !ok || current.State != StatePending {
		t.Fatalf("其它 thread 的句柄不能被牵连：ok=%v state=%s", ok, current.State)
	}
	// 仍然可以正常放行 B。
	if _, outcome, err := manager.Decide(t.Context(), actionB.ID, "device-a", DecisionAllow,
		func(context.Context, Action, Decision) error { return nil }); err != nil || outcome != OutcomeProceed {
		t.Fatalf("其它 thread 的审批应仍可放行：outcome=%s err=%v", outcome, err)
	}
	resolved := provider.events(EventApprovalResolved)
	if len(resolved) == 0 {
		t.Fatal("被作废的审批应通知设备清理旧卡片")
	}
	for _, event := range resolved {
		if event.ActionID == actionB.ID {
			t.Fatal("不该给其它 thread 的审批发已处理状态更新")
		}
	}
}

// 会话整体回收时（broker/观察连接结束）确实没人能再代替用户回答，这时才按
// 会话作废。
func TestSessionResolveRevokesEveryThread(t *testing.T) {
	manager, _ := newTestManager(t, true, "device-a")
	first, _ := manager.NotifyPending(t.Context(), ApprovalRequest{
		Runtime: "codex", SessionKey: "session-1", ThreadID: "thread-a",
		RequestID: "req-a", Method: "execCommandApproval",
	})
	second, _ := manager.NotifyPending(t.Context(), ApprovalRequest{
		Runtime: "codex", SessionKey: "session-1", ThreadID: "thread-b",
		RequestID: "req-b", Method: "execCommandApproval",
	})
	manager.ResolveSession(t.Context(), "codex", "session-1")
	for _, id := range []string{first.ID, second.ID} {
		if current, _ := manager.actions.Get(id); current.State != StateRevoked {
			t.Fatalf("会话回收应作废全部句柄，%s state=%s", id, current.State)
		}
	}
}

func TestResolveThreadIgnoresEmptyThreadID(t *testing.T) {
	manager, _ := newTestManager(t, true, "device-a")
	action, _ := manager.NotifyPending(t.Context(), codexApproval())
	// 空 threadID 不能被当成「匹配所有」，那等于悄悄退化成按会话作废。
	manager.ResolveThread(t.Context(), "codex", "session-1", "")
	if current, _ := manager.actions.Get(action.ID); current.State != StatePending {
		t.Fatalf("空 threadID 不应作废任何句柄，got=%s", current.State)
	}
}
