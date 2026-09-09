package httpapi

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
)

// 此入口只由入站线程鉴权通过后的通知分支调用。回复和错误文本均不传给 Manager。
// 不依赖客户端连接是否断开：锁屏后的 socket 可能短暂仍在，不能因此漏掉回复提醒。
func (p *appServerGatewayPolicy) notifyTurnMessage(frame *appServerGatewayFrame) {
	if p.router == nil || !p.router.pushEnabled() {
		return
	}
	message, ok := turnMessageFromFrame(frame)
	if !ok {
		return
	}
	message.Runtime = normalizeAppServerRuntimeID(p.runtimeID)
	message.ProjectID = p.projectIDForThread(message.ThreadID)
	delivery := p.router.push.PrepareTurnMessage(message)
	if delivery == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), pushDecideTimeout)
		defer cancel()
		delivery(ctx)
	}()
}

func turnMessageFromFrame(frame *appServerGatewayFrame) (pushbridge.TurnMessage, bool) {
	if frame == nil || frame.ID != nil {
		return pushbridge.TurnMessage{}, false
	}
	method := strings.TrimSpace(frame.Method)
	if method != "turn/completed" && method != "error" {
		return pushbridge.TurnMessage{}, false
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
		return pushbridge.TurnMessage{}, false
	}
	turnID := strings.TrimSpace(params.Turn.ID)
	if turnID == "" {
		turnID = strings.TrimSpace(params.TurnID)
	}
	if strings.TrimSpace(params.ThreadID) == "" || turnID == "" {
		return pushbridge.TurnMessage{}, false
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
			return pushbridge.TurnMessage{}, false
		}
	}
	return pushbridge.TurnMessage{ThreadID: params.ThreadID, TurnID: turnID, Event: event}, true
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
