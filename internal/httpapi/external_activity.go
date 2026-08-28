package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
	"github.com/gaixianggeng/mimi-remote/internal/desktopipc"
)

type externalActivitySource interface {
	Snapshot() ([]codexhistory.ExternalActivity, error)
}

type gatewayTurnStartRegistrar interface {
	RegisterGatewayTurnStart(threadID string, clientUserMessageID string)
}

type gatewayTurnOwnershipSource interface {
	GatewayOwnsTurn(threadID string, turnID string) (bool, error)
}

type externalActivityResponse struct {
	Activities []externalActivityItem `json:"activities"`
	ScannedAt  time.Time              `json:"scanned_at"`
}

type externalActivityItem struct {
	codexhistory.ExternalActivity
	Controllable bool `json:"controllable"`
}

// registerGatewayTurnStart 只接收已经完成 gateway 校验和安全改写的最终帧。
// 这里再次限定 Codex + turn/start，并要求两个关联 ID 都存在；任何证据缺失都不登记，
// 让外部活动检测继续按 Desktop turn 处理，避免错误放宽控制权限。
func (r *Router) registerGatewayTurnStart(runtimeID string, method string, payload []byte) {
	if r == nil ||
		normalizeAppServerRuntimeID(runtimeID) != "codex" ||
		strings.TrimSpace(method) != "turn/start" {
		return
	}
	registrar, ok := r.externalActivity.(gatewayTurnStartRegistrar)
	if !ok {
		return
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil || strings.TrimSpace(frame.Method) != "turn/start" {
		return
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return
	}
	threadID, threadOK := gatewayStringParam(params, "threadId")
	clientUserMessageID, clientOK := gatewayStringParam(params, "clientUserMessageId")
	if !threadOK || !clientOK {
		return
	}
	registrar.RegisterGatewayTurnStart(threadID, clientUserMessageID)
}

// codexDesktopThreadActive 只在 external activity 已给出同一线程的明确运行证据时
// 返回 true。Snapshot 读取失败由调用方按可用性策略处理；这里不能把“无法观测”
// 猜成“Desktop 正在运行”，否则一次 SQLite 短暂锁定会重新锁死空闲会话。
func (r *Router) codexDesktopThreadActive(threadID string) (bool, error) {
	if r == nil || r.externalActivity == nil {
		return false, nil
	}
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return false, nil
	}
	activities, err := r.externalActivity.Snapshot()
	if err != nil {
		return false, err
	}
	for _, activity := range activities {
		if strings.TrimSpace(activity.ThreadID) == threadID &&
			strings.EqualFold(strings.TrimSpace(activity.Source), "codex_desktop") &&
			strings.EqualFold(strings.TrimSpace(activity.State), "running") {
			return true, nil
		}
	}
	return false, nil
}

// codexGatewayOwnsTurn 只接受 tracker 给出的精确 Thread+Turn 证据。
// 其他 external activity 实现没有这项能力时按未归属处理，不能由“当前没有
// Desktop activity”反推为 gateway 所有。
func (r *Router) codexGatewayOwnsTurn(threadID string, turnID string) (bool, error) {
	if r == nil || r.externalActivity == nil {
		return false, nil
	}
	source, ok := r.externalActivity.(gatewayTurnOwnershipSource)
	if !ok {
		return false, nil
	}
	return source.GatewayOwnsTurn(threadID, turnID)
}

func (r *Router) externalActivityHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if r.externalActivity == nil {
		writeJSON(w, http.StatusOK, externalActivityResponse{
			Activities: []externalActivityItem{},
			ScannedAt:  time.Now().UTC(),
		})
		return
	}
	activities, err := r.externalActivity.Snapshot()
	if err != nil {
		// 错误响应不包含 SQLite/rollout 路径；详细路径只留在本机 agentd 日志。
		log.Printf("external activity snapshot failed: %v", err)
		http.Error(w, "external activity unavailable", http.StatusServiceUnavailable)
		return
	}
	items := make([]externalActivityItem, 0, len(activities))
	desktopReady := r.desktopSyncStatus().State == desktopipc.StateReady
	for _, activity := range activities {
		items = append(items, externalActivityItem{
			ExternalActivity: activity,
			// 只有已经通过 build gate 并建立 IPC 的 Desktop Turn 才允许移动端
			// 建立 follower 控制连接。其余外部活动继续保持只读。
			Controllable: desktopReady &&
				strings.EqualFold(strings.TrimSpace(activity.Source), "codex_desktop") &&
				strings.EqualFold(strings.TrimSpace(activity.State), "running"),
		})
	}
	writeJSON(w, http.StatusOK, externalActivityResponse{
		Activities: items,
		ScannedAt:  time.Now().UTC(),
	})
}
