package tunnel

import (
	"context"
	"fmt"
	"net"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/ipn/ipnstate"
)

// 先给现有路径一个有界机会，避免等满原来的 15 秒才发现服务端已重启。
const forwarderAttemptTimeout = 3 * time.Second
const forwarderRecoveryCooldown = time.Second
const forwarderMonitorInterval = 10 * time.Second

type tunnelClient interface {
	Ping(context.Context) (tailcat.PingResult, error)
	DiscoPing(context.Context) (*ipnstate.PingResult, error)
	DialTCPPort(context.Context, uint16) (net.Conn, error)
	Close() error
}

type forwarderClient struct {
	transport tunnelClient
}

type forwarderRecovery struct {
	done       chan struct{}
	client     *forwarderClient
	err        error
	retryAfter time.Time
}

func newForwarder(listener net.Listener, client tunnelClient, factory func() tunnelClient) *Forwarder {
	ctx, cancel := context.WithCancel(context.Background())
	return &Forwarder{
		listener:    listener,
		done:        make(chan struct{}),
		ctx:         ctx,
		cancel:      cancel,
		current:     &forwarderClient{transport: client},
		newClient:   factory,
		connections: make(map[net.Conn]*forwarderClient),
	}
}

func (f *Forwarder) monitor() {
	ticker := time.NewTicker(forwarderMonitorInterval)
	defer ticker.Stop()
	for {
		select {
		case <-f.done:
			return
		case <-ticker.C:
			f.checkActiveClient()
		}
	}
}

func (f *Forwarder) checkActiveClient() {
	f.mu.Lock()
	client := f.current
	active := false
	for _, owner := range f.connections {
		if owner != nil && owner == client {
			active = true
			break
		}
	}
	f.mu.Unlock()
	if !active || f.ctx.Err() != nil {
		return
	}
	// 服务端重启可能让已建立的 WebSocket 永久等待。探测隧道本身，
	// 不把业务响应慢当成故障；没有活动连接时也不产生后台流量。
	ctx, cancel := context.WithTimeout(f.ctx, forwarderAttemptTimeout)
	_, err := client.transport.DiscoPing(ctx)
	cancel()
	if err != nil && f.ctx.Err() == nil {
		_, _ = f.recoverClient(f.ctx, client)
	}
}

func (f *Forwarder) clientForRequest(ctx context.Context) (*forwarderClient, error) {
	f.mu.Lock()
	if err := ctx.Err(); err != nil {
		f.mu.Unlock()
		return nil, err
	}
	if f.ctx.Err() != nil {
		f.mu.Unlock()
		return nil, net.ErrClosed
	}
	if f.current != nil {
		client := f.current
		f.mu.Unlock()
		return client, nil
	}
	r := f.recovery
	if r == nil || (!r.retryAfter.IsZero() && !time.Now().Before(r.retryAfter)) {
		r = f.startRecoveryLocked(nil)
	}
	f.mu.Unlock()
	return f.waitRecovery(ctx, r)
}

func (f *Forwarder) recoverClient(ctx context.Context, failed *forwarderClient) (*forwarderClient, error) {
	f.mu.Lock()
	if err := ctx.Err(); err != nil {
		f.mu.Unlock()
		return nil, err
	}
	if f.ctx.Err() != nil {
		f.mu.Unlock()
		return nil, net.ErrClosed
	}
	if f.current != nil && f.current != failed {
		// 旧请求的迟到错误不能再次销毁已经恢复的引擎。
		client := f.current
		f.mu.Unlock()
		return client, nil
	}
	r := f.recovery
	if f.current == failed {
		r = f.startRecoveryLocked(failed)
	}
	f.mu.Unlock()
	return f.waitRecovery(ctx, r)
}

func (f *Forwarder) startRecoveryLocked(old *forwarderClient) *forwarderRecovery {
	r := &forwarderRecovery{done: make(chan struct{})}
	f.current = nil
	f.recovery = r
	var connections []net.Conn
	for connection, client := range f.connections {
		if old != nil && client == old {
			connections = append(connections, connection)
		}
	}
	go f.rebuildClient(r, old, connections)
	return r
}

func (f *Forwarder) rebuildClient(r *forwarderRecovery, old *forwarderClient, connections []net.Conn) {
	for _, connection := range connections {
		connection.Close()
	}
	// 同一身份同时连接 DERP 会互相抢占下行，必须先完全关闭旧引擎。
	if old != nil {
		r.err = old.transport.Close()
	}
	ctx, cancel := context.WithTimeout(f.ctx, 15*time.Second)
	defer cancel()
	if r.err == nil {
		r.err = ctx.Err()
	}
	var client tunnelClient
	if r.err == nil {
		client = f.newClient()
		_, r.err = client.Ping(ctx)
	}
	f.mu.Lock()
	if r.err == nil && f.ctx.Err() == nil {
		r.client = &forwarderClient{transport: client}
		f.current = r.client
		close(r.done)
		f.mu.Unlock()
		return
	}
	f.mu.Unlock()
	if client != nil {
		client.Close()
	}
	f.mu.Lock()
	if r.err == nil {
		r.err = net.ErrClosed
	}
	r.err = fmt.Errorf("恢复 Tailcat 连接：%w", r.err)
	// 服务离线时，并发和连续请求共享失败结果；后续请求再尝试，不启动后台重试循环。
	r.retryAfter = time.Now().Add(forwarderRecoveryCooldown)
	close(r.done)
	f.mu.Unlock()
}

func (f *Forwarder) waitRecovery(ctx context.Context, r *forwarderRecovery) (*forwarderClient, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-f.done:
		return nil, net.ErrClosed
	case <-r.done:
		return r.client, r.err
	}
}
