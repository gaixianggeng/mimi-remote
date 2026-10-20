package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
)

// 锁屏 / 灵动岛 Live Activity（#830）的 agentd 侧入口。
//
// App 用 push-to-start Token 与单个活动的更新 Token 直接向 Provider 换 Ticket，再把
// Ticket 登记到这里；agentd 只按会话生命周期事件算出状态枚举与计数，经 Provider 投递。
// 标题、提示词与输出都不离开这台 Mac。
const pushLiveActivityStoreFileName = "push-live-activities.json"

// liveActivityRuntimes：DeepSeek 不发推送（见 #830 实现边界），这里也不跟踪。
func liveActivityRuntime(runtimeID string) (string, bool) {
	runtime := normalizeAppServerRuntimeID(runtimeID)
	return runtime, runtime == appServerRuntimeCodexID || runtime == appServerRuntimeClaudeID
}

func (p *appServerGatewayPolicy) liveActivityEngine() *pushbridge.LiveActivityEngine {
	if p == nil || p.router == nil || p.router.push == nil {
		return nil
	}
	return p.router.push.LiveActivities()
}

// observeLiveActivityNotification 只读取生命周期方法、线程 ID 与状态枚举。它只对本连接
// 已授权的线程生效，与回复提醒的范围一致；任何失败都只是少一次状态变化。
func (p *appServerGatewayPolicy) observeLiveActivityNotification(frame *appServerGatewayFrame) {
	engine := p.liveActivityEngine()
	if engine == nil || frame == nil || frame.ID != nil {
		return
	}
	runtime, ok := liveActivityRuntime(p.runtimeID)
	if !ok {
		return
	}
	method := strings.TrimSpace(frame.Method)
	switch method {
	case "turn/started", "turn/completed", "error", "thread/status/changed", "thread/closed", "item/started":
	case "serverRequest/resolved":
		threadID, _, _ := appServerGatewayServerRequestScope(frame.Params)
		for _, requestID := range resolvedServerRequestIDs(frame.Params) {
			engine.ApprovalResolved(runtime, threadID, requestID)
		}
		return
	default:
		return
	}
	var params struct {
		ThreadID  string `json:"threadId"`
		WillRetry bool   `json:"willRetry"`
		Turn      struct {
			Status string `json:"status"`
		} `json:"turn"`
		Status json.RawMessage `json:"status"`
	}
	if json.Unmarshal(frame.Params, &params) != nil {
		return
	}
	threadID := strings.TrimSpace(params.ThreadID)
	if threadID == "" {
		return
	}
	if method == "item/started" {
		engine.Touch(runtime, threadID)
		return
	}
	if _, allowed := p.allowedThread(threadID); !allowed {
		return
	}
	switch method {
	case "turn/started":
		engine.TurnStarted(runtime, threadID)
	case "turn/completed":
		status := pushbridge.LiveActivityStatusCompleted
		if strings.EqualFold(params.Turn.Status, "failed") {
			status = pushbridge.LiveActivityStatusFailed
		}
		// 用户中断也算结束而不是失败：锁屏上不该把主动停止显示成出错。
		engine.TurnEnded(runtime, threadID, status)
	case "error":
		if !params.WillRetry {
			engine.TurnEnded(runtime, threadID, pushbridge.LiveActivityStatusFailed)
		}
	case "thread/closed":
		engine.ThreadClosed(runtime, threadID)
	case "thread/status/changed":
		statusType, waiting := liveActivityThreadStatus(params.Status)
		engine.ThreadStatus(runtime, threadID, statusType, waiting)
	}
}

// liveActivityThreadStatus 只认 type 与两个等待标记；其它标记与字段都不读。
func liveActivityThreadStatus(raw json.RawMessage) (string, bool) {
	var status struct {
		Type        string   `json:"type"`
		ActiveFlags []string `json:"activeFlags"`
	}
	if json.Unmarshal(raw, &status) != nil {
		return "", false
	}
	waiting := false
	for _, flag := range status.ActiveFlags {
		if flag == "waitingOnApproval" || flag == "waitingOnUserInput" {
			waiting = true
		}
	}
	return status.Type, waiting
}

// observeLiveActivityServerRequest：已登记的审批与输入请求让该会话进入「待你处理」。
// 未登记的反向请求（例如动态工具调用）不改变状态。
func (p *appServerGatewayPolicy) observeLiveActivityServerRequest(frame *appServerGatewayFrame) {
	engine := p.liveActivityEngine()
	if engine == nil || frame == nil || frame.ID == nil {
		return
	}
	runtime, ok := liveActivityRuntime(p.runtimeID)
	if !ok {
		return
	}
	if _, approval := pushbridge.ApprovalKindForMethod(frame.Method); !approval {
		return
	}
	threadID, _, _ := appServerGatewayServerRequestScope(frame.Params)
	requestID := gatewayRequestIDKey(frame.ID)
	if threadID == "" || requestID == "" {
		return
	}
	if _, allowed := p.allowedThread(threadID); !allowed {
		return
	}
	engine.ApprovalPending(runtime, threadID, requestID)
}

type pushLiveActivityRegisterRequest struct {
	DeviceID   string `json:"device_id"`
	Kind       string `json:"kind"`
	Ticket     string `json:"ticket"`
	ExpiresAt  string `json:"expires_at"`
	ActivityID string `json:"activity_id,omitempty"`
}

func (r *Router) pushLiveActivityHandler(w http.ResponseWriter, req *http.Request) {
	switch req.Method {
	case http.MethodPost:
		r.pushRegisterLiveActivity(w, req)
	case http.MethodDelete:
		r.pushUnregisterLiveActivity(w, req)
	default:
		methodNotAllowed(w)
	}
}

func (r *Router) pushRegisterLiveActivity(w http.ResponseWriter, req *http.Request) {
	if !r.pushEnabled() {
		writeError(w, http.StatusServiceUnavailable, "锁屏审批提醒未启用")
		return
	}
	var body pushLiveActivityRegisterRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 8<<10)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "请求体无效")
		return
	}
	kind := strings.TrimSpace(body.Kind)
	if !pushbridge.ValidActivityTicketKind(kind) {
		writeError(w, http.StatusBadRequest, "kind 只能是 start 或 update")
		return
	}
	expiry, err := time.Parse(time.RFC3339, strings.TrimSpace(body.ExpiresAt))
	if err != nil {
		writeError(w, http.StatusBadRequest, "expires_at 必须是 RFC3339")
		return
	}
	deviceID := strings.TrimSpace(body.DeviceID)
	ticket, err := r.push.LiveActivities().Register(deviceID, kind, pushbridge.ActivityTicket{
		Ticket:     body.Ticket,
		ExpiresAt:  expiry,
		ActivityID: body.ActivityID,
	})
	if err != nil {
		if errors.Is(err, pushbridge.ErrLiveActivityDeviceUnknown) {
			// 活动票据只能挂在已登记消息提醒的设备上；App 应先完成提醒注册。
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"device_id":  deviceID,
		"kind":       kind,
		"expires_at": ticket.ExpiresAt.UTC().Format(time.RFC3339),
	})
}

// pushUnregisterLiveActivity 的 kind 省略或为 all 时两类都注销；activity_id 只用于
// update，与登记时不一致就不删，避免旧活动的迟到注销删掉新活动的票据。
func (r *Router) pushUnregisterLiveActivity(w http.ResponseWriter, req *http.Request) {
	if r.push == nil {
		writeError(w, http.StatusServiceUnavailable, "锁屏审批提醒未启用")
		return
	}
	query := req.URL.Query()
	deviceID := strings.TrimSpace(query.Get("device_id"))
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "device_id 必填")
		return
	}
	kind := strings.TrimSpace(query.Get("kind"))
	if kind == "all" {
		kind = ""
	}
	if kind != "" && !pushbridge.ValidActivityTicketKind(kind) {
		writeError(w, http.StatusBadRequest, "kind 只能是 start、update 或 all")
		return
	}
	removed, err := r.push.LiveActivities().Unregister(deviceID, kind, strings.TrimSpace(query.Get("activity_id")))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "注销 Live Activity 失败")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"removed": removed})
}

// pushLiveActivityStorePath 与设备注册表同目录、同样 0600。
func pushLiveActivityStorePath(configPath string) string {
	trimmed := strings.TrimSpace(configPath)
	if trimmed == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(trimmed), pushLiveActivityStoreFileName)
}
