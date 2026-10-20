package pushbridge

import (
	"context"
	"errors"
	"fmt"
)

// Live Activity（#830）发给 Provider 的固定 Schema，字段与 internal/pushprovider 的
// LiveActivityNotification 一一对应：状态枚举、两个计数、开始时间与匿名短标签。
// 会话标题从不离开设备，Widget 扩展按短标签从 App Group 缓存在本机查。
const (
	LiveActivityEventStart  = "start"
	LiveActivityEventUpdate = "update"
	LiveActivityEventEnd    = "end"

	LiveActivityStatusRunning   = "running"
	LiveActivityStatusNeedsYou  = "needsYou"
	LiveActivityStatusCompleted = "completed"
	LiveActivityStatusFailed    = "failed"

	// LiveActivityAttributesType 必须与 App 内 ActivityAttributes 的 Swift 类型名一致。
	LiveActivityAttributesType = "MimiTurnActivityAttributes"
	// Provider 拒绝 0–99 以外的计数，发送前在这里截断。
	maxLiveActivityCount = 99
)

type LiveActivityContentState struct {
	Status          string `json:"status"`
	RunningCount    int    `json:"running_count"`
	NeedsYouCount   int    `json:"needs_you_count"`
	StartedAt       int64  `json:"started_at"`
	FocusSessionTag string `json:"focus_session_tag"`
}

type LiveActivityAttributes struct {
	HostTag string `json:"host_tag"`
}

type LiveActivityNotification struct {
	Version        int                      `json:"version"`
	Event          string                   `json:"event"`
	Ticket         string                   `json:"ticket"`
	ContentState   LiveActivityContentState `json:"content_state"`
	AttributesType string                   `json:"attributes_type,omitempty"`
	Attributes     *LiveActivityAttributes  `json:"attributes,omitempty"`
	StaleDate      int64                    `json:"stale_date,omitempty"`
	DismissalDate  int64                    `json:"dismissal_date,omitempty"`
	ExpiresAt      string                   `json:"expires_at"`
}

// NotifyLiveActivity 只把 Provider 明确接受的结果当成功：200 delivered:true 或 202
// 合并待发。410 与 ticket_revoked 映射为 ErrDeviceUnregistered，调用方据此删掉这张
// 活动 Ticket；它不影响同一设备的通知 Ticket。
func (c *Client) NotifyLiveActivity(ctx context.Context, notification LiveActivityNotification) error {
	if !c.Configured() {
		return errors.New("未配置推送 Provider")
	}
	notification.Version = 1
	var response struct {
		Delivered  bool   `json:"delivered"`
		Accepted   bool   `json:"accepted"`
		Reason     string `json:"reason"`
		APNsStatus int    `json:"apns_status"`
	}
	if err := c.post(ctx, "/v1/notify/liveactivity", notification, &response); err != nil {
		return err
	}
	if response.Delivered || response.Accepted {
		return nil
	}
	return fmt.Errorf("APNs 拒绝 Live Activity（status=%d reason=%s）", response.APNsStatus, response.Reason)
}
