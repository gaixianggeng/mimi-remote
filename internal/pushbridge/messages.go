package pushbridge

import (
	"context"
	"strings"
)

const (
	EventTurnCompleted   = "turn.completed"
	EventTurnFailed      = "turn.failed"
	EventTurnInterrupted = "turn.interrupted"
	messageTTL           = routeTTL
	maxMessages          = maxRoutes
)

// TurnMessage 只保留打开任务所需的本机路由。正文和错误详情不进入推送。
// ScopeID/CWD/ReadOnly 是推送时从线程授权记录截下的快照：agentd 重启后授权缓存
// 为空，定位时要靠它们按当前作用域配置重新推导线程授权。
type TurnMessage struct {
	Runtime   string
	ThreadID  string
	ProjectID string
	ScopeID   string
	CWD       string
	ReadOnly  bool
	TurnID    string
	Event     string
}

// PrepareTurnMessage 按 runtime/thread/turn 去重。错误事件和随后的失败终态
// 属于同一轮，不能弹两次；路由有数量和时间上限，也不赋予任何审批权限。
func (m *Manager) PrepareTurnMessage(message TurnMessage) PreparedDelivery {
	if !m.Enabled() || strings.TrimSpace(message.ThreadID) == "" || strings.TrimSpace(message.TurnID) == "" {
		return nil
	}
	if message.Runtime != "codex" && message.Runtime != "claude" {
		return nil
	}
	switch message.Event {
	case EventTurnCompleted, EventTurnFailed, EventTurnInterrupted:
	default:
		return nil
	}
	devices := m.devices.Active()
	if len(devices) == 0 {
		return nil
	}
	id, err := randomActionID()
	if err != nil {
		return nil
	}
	now := m.now()
	record := LocateRecord{
		ID:        id,
		Kind:      RouteKindMessage,
		Runtime:   message.Runtime,
		ThreadID:  message.ThreadID,
		ProjectID: message.ProjectID,
		ScopeID:   message.ScopeID,
		CWD:       message.CWD,
		ReadOnly:  message.ReadOnly,
		TurnID:    message.TurnID,
		Event:     message.Event,
		CreatedAt: now,
		ExpiresAt: now.Add(messageTTL),
	}
	for _, device := range devices {
		record.DeviceIDs = append(record.DeviceIDs, device.ID)
	}
	// 去重覆盖重启前落盘的记录：同一 turn 在 agentd 重启后不会再推第二次。
	if !m.routes.Insert(now, record) {
		return nil
	}
	// 仅复用投递数据形状，不把消息放进 ActionStore，因而不能用它执行允许/拒绝。
	delivery := Action{ID: id, Runtime: message.Runtime, ThreadID: message.ThreadID, ExpiresAt: record.ExpiresAt}
	return func(ctx context.Context) {
		// 落盘放在投递 goroutine 里：入站网关帧只承担内存插入，不等磁盘。
		m.routes.Flush()
		m.fanout(ctx, delivery, message.Event, devices)
	}
}

func (m *Manager) MessageRoute(id, deviceID string) (TurnMessage, bool) {
	record, outcome := m.LocateRoute(id, deviceID)
	if outcome != OutcomeProceed || record.Kind != RouteKindMessage {
		return TurnMessage{}, false
	}
	return TurnMessage{
		Runtime:   record.Runtime,
		ThreadID:  record.ThreadID,
		ProjectID: record.ProjectID,
		ScopeID:   record.ScopeID,
		CWD:       record.CWD,
		ReadOnly:  record.ReadOnly,
		TurnID:    record.TurnID,
		Event:     record.Event,
	}, true
}

// LocateRoute 同时服务回复提醒与审批提醒的「打开任务」。它只做定位：审批是否
// 还能操作由 ActionStore 单独回答，已落定的审批照样能定位到它的会话。
// 设备既要在记录的签发快照里，也要仍处于注册状态 —— 推送后注销的设备不再
// 被服务，推送后才注册的设备也拿不到别人的通知。
func (m *Manager) LocateRoute(id, deviceID string) (LocateRecord, Outcome) {
	if !m.Enabled() {
		return LocateRecord{}, OutcomeNotFound
	}
	record, ok := m.routes.Get(id)
	if !ok {
		return LocateRecord{}, OutcomeNotFound
	}
	if !m.now().Before(record.ExpiresAt) {
		return LocateRecord{}, OutcomeGone
	}
	if !record.allowsDevice(deviceID) || !m.deviceActive(deviceID) {
		return LocateRecord{}, OutcomeForbidden
	}
	return record, OutcomeProceed
}

func (m *Manager) deviceActive(deviceID string) bool {
	if deviceID == "" {
		return false
	}
	for _, device := range m.devices.Active() {
		if device.ID == deviceID {
			return true
		}
	}
	return false
}
