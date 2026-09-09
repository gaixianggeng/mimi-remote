package pushbridge

import (
	"context"
	"strings"
	"time"
)

const (
	EventTurnCompleted   = "turn.completed"
	EventTurnFailed      = "turn.failed"
	EventTurnInterrupted = "turn.interrupted"
	messageTTL           = 24 * time.Hour
	maxMessages          = 256
)

// TurnMessage 只保留打开任务所需的本机路由。正文和错误详情不进入推送。
type TurnMessage struct {
	Runtime   string
	ThreadID  string
	ProjectID string
	TurnID    string
	Event     string
}

type messageRoute struct {
	message   TurnMessage
	id        string
	deviceIDs []string
	createdAt time.Time
	expiresAt time.Time
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
	now := m.now()
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.messages == nil {
		m.messages = make(map[string]messageRoute)
	}
	for id, route := range m.messages {
		if !now.Before(route.expiresAt) {
			delete(m.messages, id)
			continue
		}
		old := route.message
		if old.Runtime == message.Runtime && old.ThreadID == message.ThreadID && old.TurnID == message.TurnID {
			return nil
		}
	}
	if len(m.messages) >= maxMessages {
		var oldest messageRoute
		for _, route := range m.messages {
			if oldest.id == "" || route.createdAt.Before(oldest.createdAt) {
				oldest = route
			}
		}
		delete(m.messages, oldest.id)
	}
	id, err := randomActionID()
	if err != nil {
		return nil
	}
	route := messageRoute{message: message, id: id, createdAt: now, expiresAt: now.Add(messageTTL)}
	for _, device := range devices {
		route.deviceIDs = append(route.deviceIDs, device.ID)
	}
	m.messages[id] = route
	// 仅复用投递数据形状，不把消息放进 ActionStore，因而不能用它执行允许/拒绝。
	delivery := Action{ID: id, Runtime: message.Runtime, ThreadID: message.ThreadID, ExpiresAt: route.expiresAt}
	return func(ctx context.Context) { m.fanout(ctx, delivery, message.Event, devices) }
}

func (m *Manager) MessageRoute(id, deviceID string) (TurnMessage, bool) {
	if !m.Enabled() {
		return TurnMessage{}, false
	}
	active := false
	for _, device := range m.devices.Active() {
		if device.ID == deviceID {
			active = true
			break
		}
	}
	if !active {
		return TurnMessage{}, false
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	route, ok := m.messages[id]
	if !ok || !m.now().Before(route.expiresAt) {
		return TurnMessage{}, false
	}
	for _, allowed := range route.deviceIDs {
		if allowed == deviceID {
			return route.message, true
		}
	}
	return TurnMessage{}, false
}
