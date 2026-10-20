package pushprovider

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Live Activity（#830）与审批通知一样只接受固定 Schema：状态枚举、两个计数、
// 开始时间与匿名会话短标签。会话标题由设备上的 Widget 扩展按短标签从 App Group
// 缓存查，从不经过 Provider 或 APNs。
const (
	liveActivityEventStart  = "start"
	liveActivityEventUpdate = "update"
	liveActivityEventEnd    = "end"

	liveActivityStatusRunning   = "running"
	liveActivityStatusNeedsYou  = "needsYou"
	liveActivityStatusCompleted = "completed"
	liveActivityStatusFailed    = "failed"

	// LiveActivityAttributesType 必须与 App 内 ActivityAttributes 的 Swift 类型名完全
	// 一致，否则系统不会用 push-to-start 拉起活动。
	LiveActivityAttributesType = "MimiTurnActivityAttributes"
	// Apple 要求 start 带 alert。文案只用 App 包内的本地化 key，不带参数也不带声音：
	// 有新活动出现即可，审批与失败仍由原有通知负责响铃。
	liveActivityStartTitleKey = "push.liveactivity.start.title"
	liveActivityStartBodyKey  = "push.liveactivity.start.body"

	maxLiveActivityCount = 99
	// 活动最长活跃 8 小时，结束后最多在锁屏保留 4 小时。
	liveActivityMaxExpiry    = 12 * time.Hour
	liveActivityMaxStale     = 12 * time.Hour
	liveActivityMaxDismissal = 4 * time.Hour
	liveActivityMaxAge       = 24 * time.Hour
	liveActivityClockSkew    = 5 * time.Minute
)

var allowedLiveActivityStatuses = map[string]struct{}{
	liveActivityStatusRunning:   {},
	liveActivityStatusNeedsYou:  {},
	liveActivityStatusCompleted: {},
	liveActivityStatusFailed:    {},
}

// LiveActivityNotification 是 agentd 允许发给 Provider 的全部 Live Activity 内容。
// 时间字段都是 Unix 秒；0 表示未提供。
type LiveActivityNotification struct {
	Version      int                      `json:"version"`
	Event        string                   `json:"event"`
	Ticket       string                   `json:"ticket"`
	ContentState LiveActivityContentState `json:"content_state"`
	// AttributesType 与 Attributes 只用于 start。
	AttributesType string                  `json:"attributes_type,omitempty"`
	Attributes     *LiveActivityAttributes `json:"attributes,omitempty"`
	StaleDate      int64                   `json:"stale_date,omitempty"`
	// DismissalDate 只用于 end；早于当前时间表示立即移除。
	DismissalDate int64  `json:"dismissal_date,omitempty"`
	ExpiresAt     string `json:"expires_at"`
}

// LiveActivityContentState 是多会话汇总态：Status 与 FocusSessionTag 描述最需要
// 关注的那条会话，两个计数覆盖这台 Mac 上全部会话。
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

func (n LiveActivityNotification) Validate(now time.Time) error {
	if n.Version != 1 {
		return errors.New("不支持的 version")
	}
	switch n.Event {
	case liveActivityEventStart:
		if n.AttributesType != LiveActivityAttributesType {
			return errors.New("不支持的 attributes_type")
		}
		if n.Attributes == nil {
			return errors.New("start 必须带 attributes")
		}
		if err := validateTag("attributes.host_tag", n.Attributes.HostTag); err != nil {
			return err
		}
	case liveActivityEventUpdate, liveActivityEventEnd:
		if n.AttributesType != "" || n.Attributes != nil {
			return errors.New("只有 start 可以带 attributes")
		}
	default:
		return errors.New("不支持的 event")
	}
	if err := n.ContentState.validate(now); err != nil {
		return err
	}
	if n.StaleDate != 0 {
		if n.Event == liveActivityEventEnd {
			return errors.New("end 不能带 stale_date")
		}
		stale := time.Unix(n.StaleDate, 0)
		if !stale.After(now) || stale.Sub(now) > liveActivityMaxStale {
			return errors.New("stale_date 超出范围")
		}
	}
	if n.DismissalDate != 0 {
		if n.Event != liveActivityEventEnd {
			return errors.New("只有 end 可以带 dismissal_date")
		}
		if n.DismissalDate < 0 || time.Unix(n.DismissalDate, 0).Sub(now) > liveActivityMaxDismissal {
			return errors.New("dismissal_date 超出范围")
		}
	}
	expiry, err := time.Parse(time.RFC3339, n.ExpiresAt)
	if err != nil {
		return errors.New("expires_at 必须是 RFC3339")
	}
	if !expiry.After(now) {
		return errors.New("expires_at 已过期")
	}
	if expiry.Sub(now) > liveActivityMaxExpiry {
		return fmt.Errorf("expires_at 超过上限 %s", liveActivityMaxExpiry)
	}
	return nil
}

func (c LiveActivityContentState) validate(now time.Time) error {
	if _, ok := allowedLiveActivityStatuses[c.Status]; !ok {
		return errors.New("不支持的 content_state.status")
	}
	if c.RunningCount < 0 || c.RunningCount > maxLiveActivityCount ||
		c.NeedsYouCount < 0 || c.NeedsYouCount > maxLiveActivityCount {
		return fmt.Errorf("content_state 计数必须在 0–%d", maxLiveActivityCount)
	}
	started := time.Unix(c.StartedAt, 0)
	if c.StartedAt <= 0 || started.After(now.Add(liveActivityClockSkew)) || now.Sub(started) > liveActivityMaxAge {
		return errors.New("content_state.started_at 超出范围")
	}
	return validateTag("content_state.focus_session_tag", c.FocusSessionTag)
}

func (n LiveActivityNotification) Expiry() time.Time {
	expiry, err := time.Parse(time.RFC3339, n.ExpiresAt)
	if err != nil {
		return time.Time{}
	}
	return expiry
}

// requiredTicketKind：start 只能投给 push-to-start Token，update 与 end 只能投给
// 某个活动自己的更新 Token。
func (n LiveActivityNotification) requiredTicketKind() string {
	if n.Event == liveActivityEventStart {
		return ticketKindActivityStart
	}
	return ticketKindActivityUpdate
}

// priority：普通 update 用 5，不占系统的高优先级预算；start、end 与「待你处理」用 10。
func (n LiveActivityNotification) priority() int {
	if n.Event == liveActivityEventUpdate && n.ContentState.Status != liveActivityStatusNeedsYou {
		return 5
	}
	return 10
}

// liveActivityContentStatePayload 的 JSON 键必须与 App 内 ContentState 的属性名一致：
// 系统只用默认 Codable 策略解码。startedAt 是 Unix 秒整数，App 端应声明为整数再转
// Date；声明成 Date 时默认策略会按 2001 年参考时间解释，时间会差 31 年。
type liveActivityContentStatePayload struct {
	Status          string `json:"status"`
	RunningCount    int    `json:"runningCount"`
	NeedsYouCount   int    `json:"needsYouCount"`
	StartedAt       int64  `json:"startedAt"`
	FocusSessionTag string `json:"focusSessionTag"`
}

type liveActivityAttributesPayload struct {
	HostTag string `json:"hostTag"`
}

// BuildLiveActivityPayload 由 Provider 单方面组装，字段按 Apple 的 ActivityKit 推送
// 格式。timestamp 取 Provider 收到请求的时间：合并后延迟发出的更新仍保留它原本的
// 先后顺序，系统会丢弃时间戳更旧的更新。
func BuildLiveActivityPayload(n LiveActivityNotification, timestamp time.Time) ([]byte, error) {
	aps := map[string]any{
		"timestamp": timestamp.Unix(),
		"event":     n.Event,
		"content-state": liveActivityContentStatePayload{
			Status:          n.ContentState.Status,
			RunningCount:    n.ContentState.RunningCount,
			NeedsYouCount:   n.ContentState.NeedsYouCount,
			StartedAt:       n.ContentState.StartedAt,
			FocusSessionTag: n.ContentState.FocusSessionTag,
		},
	}
	if n.StaleDate != 0 {
		aps["stale-date"] = n.StaleDate
	}
	switch n.Event {
	case liveActivityEventStart:
		if n.Attributes == nil {
			return nil, errors.New("start 缺少 attributes")
		}
		aps["attributes-type"] = n.AttributesType
		aps["attributes"] = liveActivityAttributesPayload{HostTag: n.Attributes.HostTag}
		aps["alert"] = map[string]any{
			"title": map[string]any{"loc-key": liveActivityStartTitleKey},
			"body":  map[string]any{"loc-key": liveActivityStartBodyKey},
		}
		// iOS 18+ 识别该键：远程启动的同时为新活动下发更新 Token。
		aps["input-push-token"] = 1
	case liveActivityEventEnd:
		if n.DismissalDate != 0 {
			aps["dismissal-date"] = n.DismissalDate
		}
	}
	return json.Marshal(map[string]any{"aps": aps})
}
