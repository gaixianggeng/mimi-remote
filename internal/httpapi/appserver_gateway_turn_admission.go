package httpapi

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

type appServerGatewayTurnAdmission struct {
	ownerConnectionID uint64
	turnID            string
	completedTurnIDs  map[string]struct{}
	startedAt         time.Time
}

func (r *Router) nextGatewayConnectionID() uint64 {
	r.gatewayTurnMu.Lock()
	defer r.gatewayTurnMu.Unlock()
	r.gatewayTurnSequence++
	return r.gatewayTurnSequence
}

func (r *Router) reserveGatewayTurn(threadID string, owner uint64) error {
	if r == nil || !r.cfg.AppServer.RemoteGateway.Enabled {
		return nil
	}
	threadID = strings.TrimSpace(threadID)
	if threadID == "" || owner == 0 {
		return fmt.Errorf("turn work 缺少有效 thread admission identity")
	}
	r.gatewayTurnMu.Lock()
	defer r.gatewayTurnMu.Unlock()
	if _, exists := r.gatewayActiveTurns[threadID]; exists {
		return fmt.Errorf("thread 已有运行中的 turn；请等待完成后再从另一个客户端接手")
	}
	r.gatewayActiveTurns[threadID] = appServerGatewayTurnAdmission{
		ownerConnectionID: owner,
		startedAt:         time.Now(),
	}
	return nil
}

func (r *Router) confirmGatewayTurn(threadID string, owner uint64, turnID string) {
	if r == nil || !r.cfg.AppServer.RemoteGateway.Enabled {
		return
	}
	r.gatewayTurnMu.Lock()
	defer r.gatewayTurnMu.Unlock()
	current, ok := r.gatewayActiveTurns[strings.TrimSpace(threadID)]
	if !ok || current.ownerConnectionID != owner {
		return
	}
	turnID = strings.TrimSpace(turnID)
	if turnID == "" {
		return
	}
	if _, completed := current.completedTurnIDs[turnID]; completed {
		delete(r.gatewayActiveTurns, strings.TrimSpace(threadID))
		return
	}
	current.turnID = turnID
	r.gatewayActiveTurns[strings.TrimSpace(threadID)] = current
}

func (r *Router) cancelGatewayTurnReservation(threadID string, owner uint64) {
	if r == nil || !r.cfg.AppServer.RemoteGateway.Enabled {
		return
	}
	r.gatewayTurnMu.Lock()
	defer r.gatewayTurnMu.Unlock()
	current, ok := r.gatewayActiveTurns[strings.TrimSpace(threadID)]
	if ok && current.ownerConnectionID == owner && current.turnID == "" {
		delete(r.gatewayActiveTurns, strings.TrimSpace(threadID))
	}
}

func (r *Router) completeGatewayTurn(threadID string, turnID string) {
	if r == nil || !r.cfg.AppServer.RemoteGateway.Enabled {
		return
	}
	threadID = strings.TrimSpace(threadID)
	turnID = strings.TrimSpace(turnID)
	r.gatewayTurnMu.Lock()
	defer r.gatewayTurnMu.Unlock()
	current, ok := r.gatewayActiveTurns[threadID]
	if !ok {
		return
	}
	// 只有带明确 turn ID 的完成通知能释放 reservation。thread/closed 或旧版
	// 空 ID 通知无法与本次 start 可靠关联，宁可保持锁定等待人工重启，也不能误放并发 turn。
	if turnID == "" {
		return
	}
	if current.turnID == "" {
		if current.completedTurnIDs == nil {
			current.completedTurnIDs = map[string]struct{}{}
		}
		current.completedTurnIDs[turnID] = struct{}{}
		r.gatewayActiveTurns[threadID] = current
		return
	}
	if current.turnID != turnID {
		return
	}
	delete(r.gatewayActiveTurns, threadID)
}

func (p *appServerGatewayPolicy) reservePendingTurnStart(id *json.RawMessage, threadID string) error {
	if p == nil || p.router == nil || normalizeAppServerRuntimeID(p.runtimeID) != "codex" || !p.router.cfg.AppServer.RemoteGateway.Enabled {
		return nil
	}
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("turn work 请求缺少 id")
	}
	if err := p.router.reserveGatewayTurn(threadID, p.connectionID); err != nil {
		return err
	}
	p.mu.Lock()
	if p.pendingTurnStarts == nil {
		p.pendingTurnStarts = map[string]string{}
	}
	if _, exists := p.pendingTurnStarts[key]; exists {
		p.mu.Unlock()
		p.router.cancelGatewayTurnReservation(threadID, p.connectionID)
		return fmt.Errorf("turn work request id 重复")
	}
	p.pendingTurnStarts[key] = threadID
	p.mu.Unlock()
	return nil
}

func (p *appServerGatewayPolicy) observePendingTurnStartResponse(frame *appServerGatewayFrame, requestMethod string) {
	if p == nil || p.router == nil || normalizeAppServerRuntimeID(p.runtimeID) != "codex" || !p.router.cfg.AppServer.RemoteGateway.Enabled || frame == nil || !gatewayFrameIsResponse(frame) {
		return
	}
	if !gatewayMethodStartsTurnWork(requestMethod) {
		return
	}
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return
	}
	p.mu.Lock()
	threadID, ok := p.pendingTurnStarts[key]
	if ok {
		delete(p.pendingTurnStarts, key)
	}
	p.mu.Unlock()
	if !ok {
		return
	}
	if len(frame.Error) > 0 || len(frame.Result) == 0 {
		p.router.cancelGatewayTurnReservation(threadID, p.connectionID)
		return
	}
	turnID := turnIDFromGatewayResult(frame.Result)
	p.router.confirmGatewayTurn(threadID, p.connectionID, turnID)
}

func turnIDFromGatewayResult(raw json.RawMessage) string {
	var result map[string]any
	if json.Unmarshal(raw, &result) != nil {
		return ""
	}
	if turn, ok := result["turn"].(map[string]any); ok {
		turnID, _ := gatewayStringParam(turn, "id")
		return turnID
	}
	turnID, _ := gatewayStringParam(result, "turnId")
	return turnID
}

func (p *appServerGatewayPolicy) observeTurnCompletion(frame *appServerGatewayFrame) {
	if p == nil || p.router == nil || normalizeAppServerRuntimeID(p.runtimeID) != "codex" || !p.router.cfg.AppServer.RemoteGateway.Enabled || frame == nil {
		return
	}
	method := strings.TrimSpace(frame.Method)
	if method != "turn/completed" {
		return
	}
	threadID, turnID, _ := appServerGatewayServerRequestScope(frame.Params)
	if threadID != "" {
		p.router.completeGatewayTurn(threadID, turnID)
	}
}
