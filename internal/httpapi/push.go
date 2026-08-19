package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
	"github.com/gorilla/websocket"
)

// 锁屏审批提醒的 agentd 侧入口。
//
// 设备用自己的 APNs Token 直接向 Provider 换取 Push Ticket，再把 device_id 与
// Ticket 交给 agentd —— agentd 因此从不接触原始 Device Token，Provider 也从不
// 接触 agentd 的访问 Token。
//
// 锁屏上的「允许 / 拒绝」最终被合成为一条与 iOS 完全同形的 JSON-RPC response，
// 走 gateway 既有的 validateClientFrameContext：外部 Desktop 守卫、同 ID 一次性
// 消费、permissions 安全重写全部原样复用，不在这里复制第二套判定。
const (
	pushDeviceStoreFileName = "push-devices.json"
	pushDecideTimeout       = 10 * time.Second
)

// lockScreenActionableKinds 是允许在锁屏直接放行的审批类型。
//
// 只有 command 与 patch 的响应形状是无歧义的 {"decision": ...}。permission 的
// 允许会授予一个作用域、拒绝必须以 JSON-RPC error 表达；user_input 与
// elicitation 离开内容根本无法作答 —— 而内容正是我们刻意不放进推送的东西。
// 这三类仍然会发通知，但只提供「查看详情」。
var lockScreenActionableKinds = map[string]struct{}{
	pushbridge.KindCommand: {},
	pushbridge.KindPatch:   {},
}

func lockScreenActionable(kind string) bool {
	_, ok := lockScreenActionableKinds[kind]
	return ok
}

func (r *Router) pushEnabled() bool {
	return r != nil && r.push != nil && r.push.Enabled()
}

// notifyPendingApproval 只在客户端确实离线时推送。App 在前台且连接正常时，
// 审批卡片本来就会实时出现，再推一条只会重复打扰。
func (r *Router) notifyPendingApproval(runtime string, sessionKey string, threadID string, requestID string, method string) {
	if !r.pushEnabled() || strings.TrimSpace(sessionKey) == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), pushDecideTimeout)
	go func() {
		defer cancel()
		r.push.NotifyPending(ctx, pushbridge.ApprovalRequest{
			Runtime:    runtime,
			SessionKey: sessionKey,
			ThreadID:   threadID,
			RequestID:  requestID,
			Method:     method,
		})
	}()
}

// resolveApprovalNotificationsForThread 用于 turn 结束、thread 关闭这类只影响
// 单个 thread 的事件。一个 gateway 会话覆盖该安装下的全部 thread，按会话作废
// 会把其它线程上还等着的审批一起撤掉。
func (r *Router) resolveApprovalNotificationsForThread(runtime string, sessionKey string, threadID string) {
	if !r.pushEnabled() || strings.TrimSpace(sessionKey) == "" || strings.TrimSpace(threadID) == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), pushDecideTimeout)
	go func() {
		defer cancel()
		r.push.ResolveThread(ctx, runtime, sessionKey, threadID)
	}()
}

func (r *Router) resolveApprovalNotifications(runtime string, sessionKey string, requestID string) {
	if !r.pushEnabled() || strings.TrimSpace(sessionKey) == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), pushDecideTimeout)
	go func() {
		defer cancel()
		r.push.Resolve(ctx, runtime, sessionKey, requestID)
	}()
}

type pushDeviceRegisterRequest struct {
	DeviceID  string `json:"device_id"`
	Ticket    string `json:"ticket"`
	ExpiresAt string `json:"expires_at"`
	Platform  string `json:"platform,omitempty"`
}

func (r *Router) pushDeviceHandler(w http.ResponseWriter, req *http.Request) {
	switch req.Method {
	case http.MethodPost:
		r.pushRegisterDevice(w, req)
	case http.MethodDelete:
		r.pushUnregisterDevice(w, req)
	default:
		methodNotAllowed(w)
	}
}

func (r *Router) pushRegisterDevice(w http.ResponseWriter, req *http.Request) {
	if r.push == nil {
		writeError(w, http.StatusServiceUnavailable, "锁屏审批提醒未启用")
		return
	}
	var body pushDeviceRegisterRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 8<<10)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "请求体无效")
		return
	}
	expiry, err := time.Parse(time.RFC3339, strings.TrimSpace(body.ExpiresAt))
	if err != nil {
		writeError(w, http.StatusBadRequest, "expires_at 必须是 RFC3339")
		return
	}
	device, err := r.push.Devices().Register(pushbridge.Device{
		ID:        strings.TrimSpace(body.DeviceID),
		Ticket:    strings.TrimSpace(body.Ticket),
		Platform:  strings.TrimSpace(body.Platform),
		ExpiresAt: expiry,
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"device_id":     device.ID,
		"expires_at":    device.ExpiresAt.UTC().Format(time.RFC3339),
		"needs_refresh": device.NeedsRefresh(time.Now()),
	})
}

func (r *Router) pushUnregisterDevice(w http.ResponseWriter, req *http.Request) {
	if r.push == nil {
		writeError(w, http.StatusServiceUnavailable, "锁屏审批提醒未启用")
		return
	}
	deviceID := strings.TrimSpace(req.URL.Query().Get("device_id"))
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "device_id 必填")
		return
	}
	if _, _, err := r.push.Devices().Remove(deviceID); err != nil {
		writeError(w, http.StatusInternalServerError, "删除设备失败")
		return
	}
	// 句柄绑定的设备已经消失，剩余待审批动作对它不再有效。
	writeJSON(w, http.StatusOK, map[string]any{"removed": true})
}

func (r *Router) pushStatusHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if r.push == nil {
		writeJSON(w, http.StatusOK, map[string]any{"enabled": false, "provider_configured": false})
		return
	}
	devices := []map[string]any{}
	for _, device := range r.push.Devices().Active() {
		devices = append(devices, map[string]any{
			"device_id":     device.ID,
			"platform":      device.Platform,
			"expires_at":    device.ExpiresAt.UTC().Format(time.RFC3339),
			"needs_refresh": device.NeedsRefresh(time.Now()),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"enabled":             r.push.Enabled(),
		"provider_configured": r.push.Client().Configured(),
		"provider_url":        r.cfg.Push.ProviderURL,
		"environment":         r.push.Environment(),
		"profile_id":          r.push.ProfileID(),
		"actionable_kinds":    []string{pushbridge.KindCommand, pushbridge.KindPatch},
		"devices":             devices,
	})
}

type pushDecideRequest struct {
	ActionID string `json:"action_id"`
	DeviceID string `json:"device_id"`
	Decision string `json:"decision"`
}

func (r *Router) pushDecideHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if !r.pushEnabled() {
		writeError(w, http.StatusServiceUnavailable, "锁屏审批提醒未启用")
		return
	}
	var body pushDecideRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 4<<10)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "请求体无效")
		return
	}
	decision := pushbridge.Decision(strings.TrimSpace(strings.ToLower(body.Decision)))
	if !decision.Valid() {
		writeError(w, http.StatusBadRequest, "decision 只能是 allow 或 deny")
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), pushDecideTimeout)
	defer cancel()

	action, outcome, err := r.push.Decide(ctx,
		strings.TrimSpace(body.ActionID),
		strings.TrimSpace(body.DeviceID),
		decision,
		r.submitApprovalDecision,
	)
	if err != nil {
		// 结果未知就必须如实说未知：不能把超时当成已允许或已拒绝。
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"state":  string(action.State),
			"reason": "runtime_unreachable",
			"detail": sanitizeGatewayDiagnostic(err.Error()),
		})
		return
	}
	status := http.StatusOK
	switch outcome {
	case pushbridge.OutcomeNotFound:
		status = http.StatusNotFound
	case pushbridge.OutcomeGone:
		status = http.StatusGone
	case pushbridge.OutcomeConflict:
		status = http.StatusConflict
	case pushbridge.OutcomeForbidden:
		status = http.StatusForbidden
	case pushbridge.OutcomeBusy:
		status = http.StatusAccepted
	}
	writeJSON(w, status, map[string]any{
		"outcome":  string(outcome),
		"state":    string(action.State),
		"decision": string(action.Decision),
		"runtime":  action.Runtime,
	})
}

// submitApprovalDecision 把决策合成为一条与 iOS 同形的 JSON-RPC response，
// 并交给 gateway 既有的客户端帧校验链路。这样锁屏路径和前台路径共享同一套
// 安全判定，不会出现「前台被守卫拦住、锁屏却放行」的分叉。
func (r *Router) submitApprovalDecision(ctx context.Context, action pushbridge.Action, decision pushbridge.Decision) error {
	if !lockScreenActionable(action.Kind) {
		return fmt.Errorf("该审批类型只能在 App 内处理")
	}
	payload, err := buildApprovalResponseFrame(action.RequestID, decision)
	if err != nil {
		return err
	}
	switch action.Runtime {
	case "codex":
		return r.submitCodexApprovalDecision(ctx, action, payload)
	case "claude":
		return r.submitClaudeApprovalDecision(ctx, action, payload)
	default:
		return fmt.Errorf("未知 runtime")
	}
}

// buildApprovalResponseFrame 与 iOS 的 approvalResponse 保持同形：
// accept / decline 直接落在 result.decision 上。
func buildApprovalResponseFrame(requestID string, decision pushbridge.Decision) ([]byte, error) {
	if strings.TrimSpace(requestID) == "" {
		return nil, fmt.Errorf("审批请求 id 缺失")
	}
	verdict := "decline"
	if decision == pushbridge.DecisionAllow {
		verdict = "accept"
	}
	// RequestID 是原始 JSON-RPC id 的字面量（可能是字符串或数字），原样回填。
	frame := map[string]any{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(requestID),
		"result":  map[string]any{"decision": verdict},
	}
	return json.Marshal(frame)
}

func (r *Router) submitCodexApprovalDecision(ctx context.Context, action pushbridge.Action, payload []byte) error {
	r.codexBrokerMu.Lock()
	broker := r.codexBrokers[action.SessionKey]
	r.codexBrokerMu.Unlock()
	if broker == nil {
		// 会话已经回收：runtime 侧的请求要么已被处理，要么已随 turn 结束作废。
		return fmt.Errorf("会话已结束，请打开 App 查看最新状态")
	}
	forwarded, policyErr := broker.policy.validateClientFrameContext(ctx, websocket.TextMessage, payload)
	if policyErr != nil {
		return fmt.Errorf("%s", policyErr.message)
	}
	return writeWebSocketFrame(broker.upstream, &broker.upstreamWriteMu, websocket.TextMessage, forwarded)
}

func (r *Router) submitClaudeApprovalDecision(ctx context.Context, action pushbridge.Action, payload []byte) error {
	observer := r.claudeApprovalObserverFor(action.SessionKey)
	if observer == nil {
		return fmt.Errorf("会话已结束，请打开 App 查看最新状态")
	}
	return observer.submit(ctx, payload)
}

// pushDeviceStorePath 把设备注册表放在 agentd 自己的配置目录下，权限 0600。
// 按目录取而不是裁剪文件名：配置文件不一定叫 config.json，裁剪会拼出
// `.../whatever.jsonpush-devices.json` 这种既不报错也不正确的路径。
func pushDeviceStorePath(configPath string) string {
	trimmed := strings.TrimSpace(configPath)
	if trimmed == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(trimmed), pushDeviceStoreFileName)
}

func newPushManager(cfg pushManagerConfig) *pushbridge.Manager {
	if strings.TrimSpace(cfg.DeviceStorePath) == "" {
		// 没有稳定状态路径时（例如单元测试的纯内存 Router）不启用推送。
		return nil
	}
	store, err := pushbridge.NewDeviceStore(cfg.DeviceStorePath)
	if err != nil {
		log.Printf("push device store 不可用，锁屏审批提醒保持关闭 err=%v", err)
		return nil
	}
	return pushbridge.NewManager(pushbridge.Options{
		Enabled:        cfg.Enabled,
		ProviderURL:    cfg.ProviderURL,
		Environment:    cfg.Environment,
		InstallationID: cfg.InstallationID,
		DeviceStore:    store,
	})
}

type pushManagerConfig struct {
	Enabled         bool
	ProviderURL     string
	Environment     string
	InstallationID  string
	DeviceStorePath string
}
