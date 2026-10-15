package httpapi

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
)

// 此入口只由入站线程鉴权通过后的通知分支调用。回复和错误文本均不传给 Manager。
// 不依赖客户端连接是否断开：锁屏后的 socket 可能短暂仍在，不能因此漏掉回复提醒。
func (p *appServerGatewayPolicy) notifyMessage(frame *appServerGatewayFrame) {
	if p.router == nil || !p.router.pushEnabled() {
		return
	}
	runtime := normalizeAppServerRuntimeID(p.runtimeID)
	message, ok := terminalMessageFromFrame(frame)
	if !ok && runtime == "claude" {
		message, ok = holderWaitingMessageFromFrame(frame)
	}
	if !ok {
		return
	}
	message.Runtime = runtime
	// 推送时截下线程事实：定位记录会落盘跨重启，之后没有第二次机会读到授权表。
	route := p.threadRouteFacts(message.ThreadID)
	if route.runtime == "" {
		return
	}
	message.ProjectID = route.projectID
	message.ScopeID = route.scopeID
	message.CWD = route.cwd
	message.ReadOnly = route.readOnly
	delivery := p.router.push.PrepareMessage(message)
	if delivery == nil {
		return
	}
	p.router.push.Dispatch(delivery, pushDecideTimeout)
}

func terminalMessageFromFrame(frame *appServerGatewayFrame) (pushbridge.Message, bool) {
	if frame == nil || frame.ID != nil {
		return pushbridge.Message{}, false
	}
	method := strings.TrimSpace(frame.Method)
	if method != "turn/completed" && method != "error" {
		return pushbridge.Message{}, false
	}
	var params struct {
		ThreadID  string `json:"threadId"`
		TurnID    string `json:"turnId"`
		WillRetry bool   `json:"willRetry"`
		Turn      struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"turn"`
	}
	if json.Unmarshal(frame.Params, &params) != nil || params.WillRetry {
		return pushbridge.Message{}, false
	}
	turnID := strings.TrimSpace(params.Turn.ID)
	if turnID == "" {
		turnID = strings.TrimSpace(params.TurnID)
	}
	if strings.TrimSpace(params.ThreadID) == "" || turnID == "" {
		return pushbridge.Message{}, false
	}
	event := pushbridge.EventTurnCompleted
	if method == "error" {
		event = pushbridge.EventTurnFailed
	} else {
		switch strings.ToLower(params.Turn.Status) {
		case "failed":
			event = pushbridge.EventTurnFailed
		case "interrupted":
			event = pushbridge.EventTurnInterrupted
		case "", "completed":
		default:
			return pushbridge.Message{}, false
		}
	}
	return pushbridge.Message{ThreadID: params.ThreadID, MessageID: "turn:" + turnID, Event: event}, true
}

// holderWaitingMessageFromFrame 只读取适配器给出的枚举和时间戳，不接收 waitingFor
// 等自由文本。状态与等待类别必须相互匹配，避免异常上游把普通运行态误报成提醒。
func holderWaitingMessageFromFrame(frame *appServerGatewayFrame) (pushbridge.Message, bool) {
	if frame == nil || frame.ID != nil || strings.TrimSpace(frame.Method) != "thread/status/changed" {
		return pushbridge.Message{}, false
	}
	var params struct {
		ThreadID             string `json:"threadId"`
		CanAcceptDirectInput *bool  `json:"canAcceptDirectInput"`
		Status               struct {
			Type        string   `json:"type"`
			ActiveFlags []string `json:"activeFlags"`
		} `json:"status"`
		ClaudeOwner struct {
			PID             int64  `json:"pid"`
			Status          string `json:"status"`
			WaitingKind     string `json:"waitingKind"`
			StatusUpdatedAt int64  `json:"statusUpdatedAt"`
		} `json:"claudeOwner"`
	}
	if json.Unmarshal(frame.Params, &params) != nil || strings.TrimSpace(params.ThreadID) == "" ||
		params.CanAcceptDirectInput == nil || *params.CanAcceptDirectInput || params.Status.Type != "active" ||
		params.ClaudeOwner.PID <= 0 || params.ClaudeOwner.StatusUpdatedAt <= 0 || params.ClaudeOwner.Status != "waiting" {
		return pushbridge.Message{}, false
	}
	wantFlag := "waitingOnUserInput"
	switch params.ClaudeOwner.WaitingKind {
	case "permission":
		wantFlag = "waitingOnApproval"
	case "input", "other":
	default:
		return pushbridge.Message{}, false
	}
	if len(params.Status.ActiveFlags) != 1 || params.Status.ActiveFlags[0] != wantFlag {
		return pushbridge.Message{}, false
	}
	identity := "holder-waiting:" + strconv.FormatInt(params.ClaudeOwner.PID, 10) + ":" +
		strconv.FormatInt(params.ClaudeOwner.StatusUpdatedAt, 10)
	return pushbridge.Message{
		ThreadID:  params.ThreadID,
		MessageID: identity,
		Event:     pushbridge.EventHolderWaiting,
	}, true
}

// 自动重试不是终态。保留后台观察连接和待审批请求，才能接住重试后的结果。
func gatewayErrorWillRetry(frame *appServerGatewayFrame) bool {
	if frame == nil || strings.TrimSpace(frame.Method) != "error" {
		return false
	}
	var params struct {
		WillRetry bool `json:"willRetry"`
	}
	return json.Unmarshal(frame.Params, &params) == nil && params.WillRetry
}
