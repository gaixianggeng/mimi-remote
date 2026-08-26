package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

const appServerGatewayDaemonFenceWait = 2 * time.Second

var appServerGatewayDaemonMutationMethods = map[string]struct{}{
	"thread/start":         {},
	"thread/resume":        {},
	"thread/fork":          {},
	"thread/name/set":      {},
	"thread/compact/start": {},
	"thread/unsubscribe":   {},
	"thread/archive":       {},
	"thread/unarchive":     {},
	"thread/goal/set":      {},
	"thread/goal/clear":    {},
	"review/start":         {},
	"turn/start":           {},
	"turn/steer":           {},
	"turn/interrupt":       {},
}

// appServerGatewayClientRPCReservation 保证同一连接中的客户端 request id
// 在收到响应前唯一。mutation 的共享锁挂在同一个 token 上，旧请求的错误路径
// 因此不能释放后来复用相同 id 的请求。
type appServerGatewayClientRPCReservation struct {
	policy       *appServerGatewayPolicy
	key          string
	releaseOnce  sync.Once
	fenceRelease func()
}

func (r *Router) usesMimiOwnedSharedDaemon() bool {
	return r != nil && strings.EqualFold(strings.TrimSpace(r.cfg.AppServer.Transport), "unix") &&
		r.cfg.AppServer.Managed && r.cfg.AppServer.SharedFallback != nil
}

func (r *Router) acquireMimiOwnedSharedDaemonFence(ctx context.Context) (func(), error) {
	if !r.usesMimiOwnedSharedDaemon() {
		return func() {}, nil
	}
	fenceCtx, cancel := context.WithTimeout(ctx, appServerGatewayDaemonFenceWait)
	defer cancel()
	return appserver.AcquireSharedDaemonUsageFence(fenceCtx)
}

func (p *appServerGatewayPolicy) reserveClientRPC(
	payload []byte,
) (*appServerGatewayClientRPCReservation, *appServerGatewayPolicyError) {
	if p == nil {
		return nil, &appServerGatewayPolicyError{message: "app-server gateway 连接不可用"}
	}
	if !strings.EqualFold(strings.TrimSpace(p.runtimeID), "codex") ||
		p.router == nil || !p.router.usesMimiOwnedSharedDaemon() {
		return nil, nil
	}
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil || strings.TrimSpace(frame.Method) == "" || frame.ID == nil {
		return nil, nil
	}
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return nil, nil
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "app-server gateway 连接已关闭"}
	}
	if p.clientRPCReservations == nil {
		p.clientRPCReservations = map[string]*appServerGatewayClientRPCReservation{}
	}
	if _, exists := p.clientRPCReservations[key]; exists {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "请求 id 正在处理中"}
	}
	// 未响应 request 不按 TTL 清理。提前释放 mutation 的锁会重新打开重启竞态；
	// 用现有 pending 上限限制连接级内存和 lock fd，连接关闭时统一释放。
	if len(p.clientRPCReservations) >= appServerGatewayPendingClientRequestMax {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "gateway pending client request 过多"}
	}
	reservation := &appServerGatewayClientRPCReservation{policy: p, key: key}
	p.clientRPCReservations[key] = reservation
	return reservation, nil
}

// attachSharedDaemonFence 只在全部 policy 校验与安全改写成功后获取共享锁。
// 调用方随后必须直接写 upstream，或释放 reservation。
func (r *appServerGatewayClientRPCReservation) attachSharedDaemonFence(
	ctx context.Context,
	payload []byte,
) *appServerGatewayPolicyError {
	if r == nil || r.policy == nil {
		return nil
	}
	p := r.policy
	if !strings.EqualFold(strings.TrimSpace(p.runtimeID), "codex") ||
		!p.router.usesMimiOwnedSharedDaemon() {
		return nil
	}
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		return nil
	}
	method := strings.TrimSpace(frame.Method)
	if _, ok := appServerGatewayDaemonMutationMethods[method]; !ok {
		return nil
	}
	if gatewayRequestIDKey(frame.ID) != r.key {
		return &appServerGatewayPolicyError{id: frame.ID, message: "安全改写后请求 id 发生变化"}
	}

	acquire := p.acquireDaemonFence
	if acquire == nil {
		acquire = appserver.AcquireSharedDaemonUsageFence
	}
	fenceCtx, cancel := context.WithTimeout(ctx, appServerGatewayDaemonFenceWait)
	release, err := acquire(fenceCtx)
	cancel()
	if err != nil {
		reason := "shared_daemon_fence_unavailable"
		retryable := false
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			reason = "shared_daemon_restart_in_progress"
			retryable = true
		}
		return &appServerGatewayPolicyError{
			id:      frame.ID,
			message: "共享 Codex 服务正在切换，请稍后重试",
			data: map[string]any{
				"accepted":       false,
				"reason":         reason,
				"retryable":      retryable,
				"retry_after_ms": 1000,
			},
		}
	}
	if release == nil {
		release = func() {}
	}

	p.mu.Lock()
	if p.closed || p.clientRPCReservations[r.key] != r || r.fenceRelease != nil {
		p.mu.Unlock()
		release()
		return &appServerGatewayPolicyError{id: frame.ID, message: "app-server gateway 请求已结束"}
	}
	r.fenceRelease = release
	p.mu.Unlock()
	return nil
}

func (r *appServerGatewayClientRPCReservation) release() {
	if r == nil || r.policy == nil {
		return
	}
	r.releaseOnce.Do(func() {
		p := r.policy
		p.mu.Lock()
		if p.clientRPCReservations[r.key] == r {
			delete(p.clientRPCReservations, r.key)
		}
		release := r.fenceRelease
		r.fenceRelease = nil
		p.mu.Unlock()
		if release != nil {
			release()
		}
	})
}

func (p *appServerGatewayPolicy) releaseClientRPCReservationForResponsePayload(payload []byte) {
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil || !gatewayFrameIsResponse(&frame) {
		return
	}
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return
	}
	p.mu.Lock()
	reservation := p.clientRPCReservations[key]
	p.mu.Unlock()
	reservation.release()
}

func (p *appServerGatewayPolicy) takeClientRPCReservationsLocked() []*appServerGatewayClientRPCReservation {
	reservations := make([]*appServerGatewayClientRPCReservation, 0, len(p.clientRPCReservations))
	for key, reservation := range p.clientRPCReservations {
		if reservation != nil {
			reservations = append(reservations, reservation)
		}
		delete(p.clientRPCReservations, key)
	}
	return reservations
}
