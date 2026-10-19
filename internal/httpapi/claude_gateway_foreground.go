package httpapi

import (
	"io"
	"log"
	"sync"

	"github.com/gorilla/websocket"
)

// claudeForegroundLease 是一条 Claude 前台连接持有的 bridge 槽位。
//
// 手机切网后旧 TCP 收不到 FIN/RST，网关要等读超时（最长约 150 秒）才知道它断了。
// 这段时间里旧连接一直占着槽位，同名会话的重连会累积占槽，几次切网就会被
// CLAUDE_BRIDGE_LIMIT_EXCEEDED 拒绝。常驻 bridge 以最后一次 attach 为准，新连接
// attach 之后旧连接已经收不到会话帧，留着它只剩占槽这一个作用。所以具名会话的
// 新连接到达时直接接过旧连接的槽位并断开它，就像 Codex broker 替换旧 sink。
type claudeForegroundLease struct {
	sessionKey string
	client     *websocket.Conn
	// attachMu 由同名会话的每一代连接共享。bridge 以最后一次 attach 为准：
	// 被接管的旧连接若在新连接之后才完成 attach，会把会话切回一条马上要关的连接。
	attachMu *sync.Mutex

	// 以下字段由 Router.claudeMu 保护。
	upstream   io.Closer
	holdsSlot  bool
	superseded bool
}

// claimClaudeForeground 为一条前台连接取得 bridge 槽位。具名会话已有前台连接时，
// 新连接接过它的槽位并断开它；否则按 max_concurrent_bridges 申请新槽位。
func (r *Router) claimClaudeForeground(sessionKey string, client *websocket.Conn) (*claudeForegroundLease, bool) {
	limit := r.cfg.Claude.MaxConcurrentBridges
	if limit <= 0 {
		limit = 3
	}
	lease := &claudeForegroundLease{sessionKey: sessionKey, client: client}
	r.claudeMu.Lock()
	var previous *claudeForegroundLease
	if sessionKey != "" {
		previous = r.claudeForeground[sessionKey]
	}
	var previousClient *websocket.Conn
	var previousUpstream io.Closer
	if previous != nil {
		// 槽位原样转交，计数不变；旧连接退出时不再释放它。
		previous.superseded = true
		lease.holdsSlot = previous.holdsSlot
		previous.holdsSlot = false
		lease.attachMu = previous.attachMu
		previousClient = previous.client
		previousUpstream = previous.upstream
	} else {
		lease.attachMu = &sync.Mutex{}
	}
	if !lease.holdsSlot {
		if r.activeClaudeBridge >= limit {
			r.claudeMu.Unlock()
			return nil, false
		}
		r.activeClaudeBridge++
		lease.holdsSlot = true
	}
	if sessionKey != "" {
		if r.claudeForeground == nil {
			r.claudeForeground = map[string]*claudeForegroundLease{}
		}
		r.claudeForeground[sessionKey] = lease
	}
	r.claudeMu.Unlock()

	if previous != nil {
		log.Printf("claude gateway session reconnected; closing previous connection session=%s", sanitizeGatewayDiagnostic(sessionKey))
		// 两端都关：客户端读写立即失败，卡在 attach 应答上的旧 handler 也会被唤醒，
		// 不会一直握着 attachMu 挡住新连接。
		if previousClient != nil {
			_ = previousClient.Close()
		}
		if previousUpstream != nil {
			_ = previousUpstream.Close()
		}
	}
	return lease, true
}

// setClaudeForegroundUpstream 登记这条连接的 bridge socket，接管时一并关闭。
// 返回 false 表示在拨号期间已被接管，调用方应直接退出。
func (r *Router) setClaudeForegroundUpstream(lease *claudeForegroundLease, upstream io.Closer) bool {
	r.claudeMu.Lock()
	defer r.claudeMu.Unlock()
	lease.upstream = upstream
	return !lease.superseded
}

func (r *Router) claudeForegroundSuperseded(lease *claudeForegroundLease) bool {
	r.claudeMu.Lock()
	defer r.claudeMu.Unlock()
	return lease.superseded
}

// handOffClaudeForegroundUpstream 在把 bridge 连接交给审批观察者之前调用。被接管的
// 连接返回 false：客户端并没有离开，不需要观察者。成功时 bridge 连接从租约上摘下，
// 之后的同名重连只关旧客户端，观察者由新连接按代际正常让位。
func (r *Router) handOffClaudeForegroundUpstream(lease *claudeForegroundLease) bool {
	r.claudeMu.Lock()
	defer r.claudeMu.Unlock()
	if lease.superseded {
		return false
	}
	lease.upstream = nil
	return true
}

// releaseClaudeForeground 在前台连接退出时归还槽位。已被接管的连接槽位已经转交，
// 这里不会重复释放，也不会删掉新连接的登记。
func (r *Router) releaseClaudeForeground(lease *claudeForegroundLease) {
	if lease == nil {
		return
	}
	r.claudeMu.Lock()
	defer r.claudeMu.Unlock()
	if lease.holdsSlot {
		lease.holdsSlot = false
		if r.activeClaudeBridge > 0 {
			r.activeClaudeBridge--
		}
	}
	if lease.sessionKey != "" && r.claudeForeground[lease.sessionKey] == lease {
		delete(r.claudeForeground, lease.sessionKey)
	}
}
