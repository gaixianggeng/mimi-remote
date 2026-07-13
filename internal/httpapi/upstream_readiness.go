package httpapi

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/doctor"
)

const (
	appServerReadinessProbeTimeout = 750 * time.Millisecond
	appServerReadinessSuccessTTL   = 2 * time.Second
	appServerReadinessFailureTTL   = 250 * time.Millisecond
)

type appServerReadinessProbe struct {
	mu sync.Mutex

	probe      func(context.Context) error
	now        func() time.Time
	timeout    time.Duration
	successTTL time.Duration
	failureTTL time.Duration

	hasResult bool
	checkedAt time.Time
	lastErr   error
	inFlight  chan struct{}
}

func newAppServerReadinessProbe(probe func(context.Context) error) *appServerReadinessProbe {
	return &appServerReadinessProbe{
		probe:      probe,
		now:        time.Now,
		timeout:    appServerReadinessProbeTimeout,
		successTTL: appServerReadinessSuccessTTL,
		failureTTL: appServerReadinessFailureTTL,
	}
}

func (p *appServerReadinessProbe) Check(ctx context.Context) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		p.mu.Lock()
		// 必须在拿到锁之后读取时间。若等待者先取时间、再被正在完成的探测阻塞，
		// checkedAt 可能反而晚于等待者手里的旧 now，负 age 会误触发第二次握手。
		now := p.now()
		if p.hasResult {
			ttl := p.successTTL
			if p.lastErr != nil {
				ttl = p.failureTTL
			}
			age := now.Sub(p.checkedAt)
			if age >= 0 && age < ttl {
				err := p.lastErr
				p.mu.Unlock()
				return err
			}
		}
		if p.inFlight != nil {
			inFlight := p.inFlight
			p.mu.Unlock()
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-inFlight:
				continue
			}
		}
		inFlight := make(chan struct{})
		p.inFlight = inFlight
		p.mu.Unlock()

		// 探测属于所有并发 readyz 的共享 single-flight，不绑定首个 HTTP 请求的取消；
		// 即使首个轮询断开，其他等待者仍能在固定短超时内拿到同一结果。
		probeCtx, cancel := context.WithTimeout(context.Background(), p.timeout)
		err := p.probe(probeCtx)
		cancel()

		p.mu.Lock()
		p.hasResult = true
		p.checkedAt = p.now()
		p.lastErr = err
		p.inFlight = nil
		close(inFlight)
		p.mu.Unlock()
		return err
	}
}

func (r *Router) probeAppServerUpstream(ctx context.Context) error {
	upstreamURL, err := r.appServerUpstreamWebSocketURL()
	if err != nil {
		return err
	}
	headers, err := r.appServerUpstreamHeaders()
	if err != nil {
		return err
	}
	if headers == nil || headers.Get("Authorization") == "" {
		return errors.New("app-server upstream 未配置独立 capability token")
	}
	dialer := websocket.Dialer{HandshakeTimeout: appServerReadinessProbeTimeout}
	conn, response, err := dialer.DialContext(ctx, upstreamURL, headers)
	if response != nil && response.Body != nil {
		// 鉴权失败等响应正文不进入 readyz 或日志。
		_ = response.Body.Close()
	}
	if err != nil {
		return err
	}
	_ = conn.Close()
	return nil
}

func (r *Router) appServerUpstreamReadinessCheck(ctx context.Context) doctor.Check {
	if r.upstreamReadiness == nil {
		// 正常 Router 由构造函数初始化；包内最小 fixture 使用一次性本地探针即可，避免惰性赋值产生竞态。
		return appServerReadinessCheckFromError(newAppServerReadinessProbe(r.probeAppServerUpstream).Check(ctx))
	}
	return appServerReadinessCheckFromError(r.upstreamReadiness.Check(ctx))
}

func appServerReadinessCheckFromError(err error) doctor.Check {
	if err != nil {
		// 不返回底层 dial error：其中可能包含 token file 路径、完整 upstream URL 或服务端鉴权文案。
		return doctor.Check{
			Name:    "app-server-upstream",
			OK:      false,
			Level:   "error",
			Message: "Codex app-server upstream 暂不可用或鉴权失败",
			Fix:     "检查 agentd logs、Codex app-server 状态和独立 capability token file",
		}
	}
	return doctor.Check{
		Name:    "app-server-upstream",
		OK:      true,
		Level:   "ok",
		Message: "Codex app-server upstream WebSocket 握手和独立鉴权可用",
	}
}

func appendReadinessCheck(results doctor.Results, check doctor.Check) doctor.Results {
	results.Checks = append(results.Checks, check)
	if !check.OK {
		results.OK = false
	}
	return results
}
