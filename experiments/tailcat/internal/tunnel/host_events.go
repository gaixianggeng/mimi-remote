package tunnel

import (
	"reflect"
	"regexp"
	"strings"
	"sync"
	"time"

	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// hostEventDedupeWindow 合并同一事件的连续重复。客户端握手包会在几秒内重发，
// 逐条记录只会把有限的日志容量挤掉。
const hostEventDedupeWindow = 5 * time.Second

var derpCloseReasonPattern = regexp.MustCompile(`^[a-z][a-z-]{0,39}$`)

// HostEvent 是服务端连接事件。这里只有固定事件名和白名单字段，不携带 Tailscale
// 日志原文：原文里有真实 IP、端点和完整公钥。
type HostEvent struct {
	Name           string `json:"event"`
	Peer           string `json:"peer,omitempty"`
	Region         int    `json:"region,omitempty"`
	Reason         string `json:"reason,omitempty"`
	DurationMillis int64  `json:"ms,omitempty"`
}

// 事件名由 agentd 再按白名单校验一次，两边必须一起改。
const (
	HostEventPeerContact   = "peer_contact"
	HostEventPeerRejected  = "peer_rejected"
	HostEventPathDirect    = "path_direct"
	HostEventDERPConnected = "derp_connected"
	HostEventDERPLost      = "derp_lost"
	HostEventDERPClosed    = "derp_closed"
	HostEventDERPHome      = "derp_home"
	HostEventNetworkChange = "network_changed"
	HostEventNetworkDown   = "network_down"
	HostEventConnOpened    = "conn_opened"
	HostEventConnClosed    = "conn_closed"
	HostEventBackendFailed = "backend_dial_failed"
)

// hostEventLogf 把 Tailcat 日志按格式串翻译成事件，未命中的一律丢弃。匹配格式串而不是
// 渲染后的文本，取哪个参数都是显式选择，新增的上游日志也不会把地址带进来。
// 上游升级时格式串可能变化，tunnel 的集成测试会在关键事件消失时失败。
func hostEventLogf(emit func(HostEvent)) logger.Logf {
	if emit == nil {
		return logger.Discard
	}
	return newHostEventFilter(emit, time.Now).logf
}

type hostEventFilter struct {
	emit func(HostEvent)
	now  func() time.Time

	mu   sync.Mutex
	last map[HostEvent]time.Time
}

func newHostEventFilter(emit func(HostEvent), now func() time.Time) *hostEventFilter {
	return &hostEventFilter{emit: emit, now: now, last: make(map[HostEvent]time.Time)}
}

func (f *hostEventFilter) logf(format string, args ...any) {
	event, ok := classifyHostLog(format, args)
	if !ok {
		return
	}
	now := f.now()
	f.mu.Lock()
	previous, seen := f.last[event]
	duplicate := seen && now.Sub(previous) < hostEventDedupeWindow
	if !duplicate {
		f.last[event] = now
	}
	// 事件种类有限，但 peer 不受限；超过上限时清空，最多多记几条重复。
	if len(f.last) > 256 {
		clear(f.last)
	}
	f.mu.Unlock()
	if !duplicate {
		f.emit(event)
	}
}

func classifyHostLog(format string, args []any) (HostEvent, bool) {
	switch {
	case format == "got meow from %v":
		return HostEvent{Name: HostEventPeerContact, Peer: shortPeerArg(args, 0)}, true
	case format == "ignoring meow from %v: not in allowedClients":
		return HostEvent{Name: HostEventPeerRejected, Peer: shortPeerArg(args, 0)}, true
	case strings.HasPrefix(format, "magicsock: disco: node %v %v now using %v mtu=%v"):
		return HostEvent{Name: HostEventPathDirect, Peer: shortPeerArg(args, 0)}, true
	case format == "magicsock: derp-%d connected; connGen=%v":
		return HostEvent{Name: HostEventDERPConnected, Region: intArg(args, 0)}, true
	case format == "magicsock: [%p] derp.Recv(derp-%d): %v":
		return HostEvent{Name: HostEventDERPLost, Region: intArg(args, 1), Reason: networkErrorReason(args, 2)}, true
	case format == "magicsock: closing connection to derp-%v (%v), age %v":
		return HostEvent{Name: HostEventDERPClosed, Region: intArg(args, 0), Reason: derpCloseReason(args, 1)}, true
	case format == "magicsock: home is now derp-%v (%v)":
		return HostEvent{Name: HostEventDERPHome, Region: intArg(args, 0)}, true
	case format == "LinkChange: major, rebinding: %v":
		return HostEvent{Name: HostEventNetworkChange}, true
	case format == "LinkChange: all links down; pausing: %v":
		return HostEvent{Name: HostEventNetworkDown}, true
	}
	return HostEvent{}, false
}

// shortPeerArg 只保留公钥的短前缀，与中继日志的 [xxxxx] 同一写法，便于两边对照。
func shortPeerArg(args []any, index int) string {
	if index >= len(args) {
		return ""
	}
	switch value := args[index].(type) {
	case string:
		if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
			return value
		}
		var public key.NodePublic
		if public.UnmarshalText([]byte(value)) == nil {
			return public.ShortString()
		}
	case key.NodePublic:
		return value.ShortString()
	}
	return ""
}

// intArg 按种类取整数：上游的区域号有 int 和 tailcfg.DERPRegionID 两种写法。
func intArg(args []any, index int) int {
	if index >= len(args) {
		return 0
	}
	value := reflect.ValueOf(args[index])
	if value.CanInt() {
		return int(value.Int())
	}
	if value.CanUint() {
		return int(value.Uint())
	}
	return 0
}

// networkErrorReason 把网络错误归成固定类别，错误原文里可能带对端地址。
func networkErrorReason(args []any, index int) string {
	if index >= len(args) {
		return "unknown"
	}
	err, ok := args[index].(error)
	if !ok || err == nil {
		return "unknown"
	}
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "timeout"), strings.Contains(message, "timed out"),
		strings.Contains(message, "deadline exceeded"):
		return "timeout"
	case strings.Contains(message, "reset by peer"):
		return "reset"
	case strings.Contains(message, "no route to host"), strings.Contains(message, "network is unreachable"),
		strings.Contains(message, "network is down"):
		return "no_route"
	case strings.Contains(message, "eof"):
		return "eof"
	case strings.Contains(message, "closed"):
		return "closed"
	}
	return "other"
}

// derpCloseReason 只放行上游写死的原因短语（idle、rebind-ping-fail 这类），其余归为 other。
func derpCloseReason(args []any, index int) string {
	if index >= len(args) {
		return "unknown"
	}
	reason, ok := args[index].(string)
	if !ok {
		return "unknown"
	}
	if !derpCloseReasonPattern.MatchString(reason) {
		return "other"
	}
	return reason
}
