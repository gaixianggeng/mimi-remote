package pushprovider

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Provider 只接受固定枚举，不接受调用方传入的标题、正文或 aps 字典。通知文案
// 全部用 App 包内的本地化 key 渲染，因此 Provider 既不知道也不能泄漏命令、
// 文件路径、Prompt 或模型输出。
const (
	// 只有 command 与 patch 可以在锁屏直接处理；其余类型只能打开 App 查看详情。
	ApprovalCategory        = "MIMI_APPROVAL"
	ApprovalDetailsCategory = "MIMI_APPROVAL_DETAILS"
	approvalTitleKey        = "push.approval.title"
	approvalBodyKey         = "push.approval.body"
	approvalPushEvent       = "approval.pending"
	resolvedPushEvent       = "approval.resolved"
	completedPushEvent      = "turn.completed"
	failedPushEvent         = "turn.failed"
	interruptedPushEvent    = "turn.interrupted"
)

// Runtime 与 ApprovalKind 是 Codex 与 Claude Code 两条链路共用的枚举。任何一端
// 新增审批类型都必须先在这里登记，未知值一律拒绝，避免上游把自由文本推到通知上。
var (
	allowedRuntimes = map[string]struct{}{
		"codex":  {},
		"claude": {},
	}
	allowedApprovalKinds = map[string]struct{}{
		"command":     {},
		"patch":       {},
		"permission":  {},
		"user_input":  {},
		"elicitation": {},
	}
	allowedEvents = map[string]struct{}{
		approvalPushEvent:    {},
		resolvedPushEvent:    {},
		completedPushEvent:   {},
		failedPushEvent:      {},
		interruptedPushEvent: {},
	}
)

// ApprovalNotification 是 agentd 允许发送给 Provider 的全部内容。
type ApprovalNotification struct {
	Version      int    `json:"version"`
	Event        string `json:"event"`
	Ticket       string `json:"ticket"`
	ActionID     string `json:"action_id"`
	DeviceID     string `json:"device_id"`
	ProfileID    string `json:"profile_id"`
	Runtime      string `json:"runtime"`
	ApprovalKind string `json:"approval_kind"`
	// HostTag / SessionTag 是匿名短标签，用于让用户区分是哪台 Mac、哪个会话，
	// 不是主机名或会话标题。
	HostTag    string `json:"host_tag"`
	SessionTag string `json:"session_tag"`
	ExpiresAt  string `json:"expires_at"`
}

const (
	maxTagLength      = 16
	maxIdentifierLen  = 64
	approvalMaxExpiry = 30 * time.Minute
)

func (n ApprovalNotification) Validate(now time.Time) error {
	if n.isTurnMessage() && n.ApprovalKind != "" {
		return errors.New("消息通知不能包含审批类型")
	}
	if n.Version != 1 {
		return errors.New("不支持的 version")
	}
	if _, ok := allowedEvents[n.Event]; !ok {
		return errors.New("不支持的 event")
	}
	if _, ok := allowedRuntimes[n.Runtime]; !ok {
		return errors.New("不支持的 runtime")
	}
	if !n.isTurnMessage() {
		if _, ok := allowedApprovalKinds[n.ApprovalKind]; !ok {
			return errors.New("不支持的 approval_kind")
		}
	}
	if err := validateOpaque("action_id", n.ActionID, maxIdentifierLen); err != nil {
		return err
	}
	if err := validateOpaque("device_id", n.DeviceID, maxIdentifierLen); err != nil {
		return err
	}
	if err := validateOpaque("profile_id", n.ProfileID, maxIdentifierLen); err != nil {
		return err
	}
	if err := validateTag("host_tag", n.HostTag); err != nil {
		return err
	}
	if err := validateTag("session_tag", n.SessionTag); err != nil {
		return err
	}
	expiry, err := time.Parse(time.RFC3339, n.ExpiresAt)
	if err != nil {
		return errors.New("expires_at 必须是 RFC3339")
	}
	if !expiry.After(now) {
		return errors.New("expires_at 已过期")
	}
	maxExpiry := approvalMaxExpiry
	if n.isTurnMessage() {
		maxExpiry = 24 * time.Hour
	}
	if expiry.Sub(now) > maxExpiry {
		return fmt.Errorf("expires_at 超过上限 %s", maxExpiry)
	}
	return nil
}

func (n ApprovalNotification) Expiry() time.Time {
	expiry, err := time.Parse(time.RFC3339, n.ExpiresAt)
	if err != nil {
		return time.Time{}
	}
	return expiry
}

// validateOpaque 只允许短的不透明标识。Provider 不解释它们，但必须保证它们不会
// 变成注入 APNs Payload 的载体。
func validateOpaque(field string, value string, max int) error {
	if value == "" || len(value) > max {
		return fmt.Errorf("%s 长度非法", field)
	}
	for _, c := range value {
		safe := c == '-' || c == '_' ||
			(c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if !safe {
			return fmt.Errorf("%s 含非法字符", field)
		}
	}
	return nil
}

func validateTag(field string, value string) error {
	if value == "" || len(value) > maxTagLength {
		return fmt.Errorf("%s 长度非法", field)
	}
	for _, c := range value {
		if !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')) {
			// 标签是 agentd 生成的大写十六进制短摘要；限制字符集同时挡住了
			// 把主机名或会话标题塞进来的可能。
			return fmt.Errorf("%s 只允许大写十六进制短标签", field)
		}
	}
	return nil
}

// BuildAPNsPayload 由 Provider 单方面组装。调用方给不了任何自由文本。
//
// 审批与 turn.* 消息都带 mutable-content=1：这只是允许设备上的 Notification
// Service Extension 在展示前改写文案。会话标题、项目名等一律来自 App 写在
// App Group 里的本地缓存（键是会话匿名标签），从不经过 Provider 或 APNs；
// Payload 里依旧只有本地化 key 和匿名标签，Provider 对会话内容一无所知。
func BuildAPNsPayload(n ApprovalNotification) ([]byte, error) {
	aps := map[string]any{}
	switch n.Event {
	case approvalPushEvent:
		aps["sound"] = "default"
		aps["thread-id"] = n.SessionTag
		aps["interruption-level"] = "time-sensitive"
		aps["category"] = approvalCategoryForKind(n.ApprovalKind)
		aps["alert"] = map[string]any{
			"title-loc-key":  approvalTitleKey + "." + n.Runtime,
			"title-loc-args": []string{n.HostTag},
			"loc-key":        approvalBodyKey + "." + n.ApprovalKind,
			"loc-args":       []string{n.SessionTag},
		}
		aps["mutable-content"] = 1
	case completedPushEvent, failedPushEvent, interruptedPushEvent:
		aps["thread-id"] = n.SessionTag
		aps["category"] = ApprovalDetailsCategory
		aps["sound"] = "default"
		aps["alert"] = map[string]any{
			"title-loc-key": "push.message.title." + n.Runtime,
			"loc-key":       "push.message.body." + strings.TrimPrefix(n.Event, "turn."),
		}
		// 允许设备上的通知扩展按 thread-id 查本机缓存改写成会话标题。这里不多带
		// 任何字段：标题不在 Payload 里，缓存未命中或旧版 App 没有扩展时仍显示通用文案。
		aps["mutable-content"] = 1
	case resolvedPushEvent:
		// 其它设备已经处理完毕：只唤醒 App 清理旧通知，不再打扰用户。
		aps["content-available"] = 1
	}
	payload := map[string]any{
		"aps": aps,
		"mimi": map[string]any{
			"version":       1,
			"event":         n.Event,
			"action_id":     n.ActionID,
			"device_id":     n.DeviceID,
			"profile_id":    n.ProfileID,
			"runtime":       n.Runtime,
			"approval_kind": n.ApprovalKind,
			"host_tag":      n.HostTag,
			"session_tag":   n.SessionTag,
			"expires_at":    n.ExpiresAt,
		},
	}
	return json.Marshal(payload)
}

// permission、user_input 和 elicitation 必须打开 App 处理。独立 category
// 可以避免异常或未来版本的客户端为这些类型错误暴露允许/拒绝动作。
func approvalCategoryForKind(kind string) string {
	switch kind {
	case "command", "patch":
		return ApprovalCategory
	default:
		return ApprovalDetailsCategory
	}
}

// CollapseID 让同一个审批的重复投递只产生一张卡片。它是 action_id 的摘要，
// 不把 action_id 本身写进可被中间环节看到的 header。
func CollapseID(actionID string) string {
	digest := sha256.Sum256([]byte("mimi-approval:" + actionID))
	return hex.EncodeToString(digest[:])[:32]
}

func normalizeEnvironmentHost(environment string) string {
	if strings.EqualFold(strings.TrimSpace(environment), "sandbox") {
		return APNsSandboxHost
	}
	return APNsProductionHost
}

func (n ApprovalNotification) isTurnMessage() bool {
	return n.Event == completedPushEvent || n.Event == failedPushEvent || n.Event == interruptedPushEvent
}
