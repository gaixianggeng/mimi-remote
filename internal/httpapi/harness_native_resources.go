package httpapi

import (
	"sync"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// harnessNativeResources 只拥有原生桥接连接和订阅名额，不拥有 Harness 进程或任务。
// HTTP RPC 由请求上下文管理；升级后的 WebSocket 脱离 net/http，必须单独登记和关闭。
type harnessNativeResources struct {
	mu             sync.Mutex
	closing        bool
	connections    map[*harnessNativeStreamConn]struct{}
	activeSessions int
	wg             sync.WaitGroup
}

func (resources *harnessNativeResources) register(conn *harnessNativeStreamConn) bool {
	resources.mu.Lock()
	defer resources.mu.Unlock()
	if resources.closing {
		return false
	}
	if resources.connections == nil {
		resources.connections = make(map[*harnessNativeStreamConn]struct{})
	}
	resources.connections[conn] = struct{}{}
	// 关闭门与 Add 共用锁，确保 shutdown 开始等待后不会登记新 handler。
	resources.wg.Add(1)
	return true
}

func (resources *harnessNativeResources) release(conn *harnessNativeStreamConn) {
	resources.mu.Lock()
	defer resources.mu.Unlock()
	if _, exists := resources.connections[conn]; exists {
		delete(resources.connections, conn)
		resources.wg.Done()
	}
}

func (resources *harnessNativeResources) shutdown() {
	resources.mu.Lock()
	resources.closing = true
	connections := make([]*harnessNativeStreamConn, 0, len(resources.connections))
	for conn := range resources.connections {
		connections = append(connections, conn)
	}
	resources.mu.Unlock()

	// 先取消所有连接的请求并解除 socket 阻塞，再等 handler 归还上游订阅和名额。
	// 不在 owner 锁内调用连接方法，避免与订阅释放的反向锁顺序相撞。
	for _, conn := range connections {
		conn.stop()
	}
	resources.wg.Wait()
}

// acquireSession 只统计 session/follow 的物理订阅，跨移动连接执行同一上限。
// $events 和 session/control 属于宿主观察，不挤占会话订阅名额。
func (resources *harnessNativeResources) acquireSession(limit int) bool {
	if limit <= 0 {
		limit = config.DefaultDeepSeekMaxConcurrentSessions
	}
	resources.mu.Lock()
	defer resources.mu.Unlock()
	if resources.closing || resources.activeSessions >= limit {
		return false
	}
	resources.activeSessions++
	return true
}

func (resources *harnessNativeResources) releaseSession() {
	resources.mu.Lock()
	defer resources.mu.Unlock()
	if resources.activeSessions > 0 {
		resources.activeSessions--
	}
}
