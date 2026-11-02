// Package tailcatevents 把 Tailcat 辅助程序的连接事件写进本机的 tailcat-events.log。
//
// 设备连不上时请求到不了 agentd，这份时间线是 Mac 侧唯一的记录，所以它常开，不依赖
// 15 分钟的「详细记录」窗口。代价是内容收得很窄：只有固定事件名和白名单字段，自由文本
// 一律先去掉真实地址、公钥和地址串。文件只留在本机，不进入「导出安全日志」。
package tailcatevents

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"regexp"
	"strings"
	"sync/atomic"

	"github.com/gaixianggeng/mimi-remote/internal/debuglog"
)

const (
	// LinePrefix 标记辅助程序 stderr 上的结构化事件，改动时同步 mimi-tailcat-experiment。
	LinePrefix = "mimi-tailcat-event "
	component  = "tailcat"

	EventSidecarStarted     = "sidecar_started"
	EventSidecarStartFailed = "sidecar_start_failed"
	EventSidecarExited      = "sidecar_exited"
	EventSidecarStopped     = "sidecar_stopped"
	eventSidecarLog         = "sidecar_log"
)

// 辅助程序事件白名单，与 experiments/tailcat/internal/tunnel/host_events.go 保持一致。
var sidecarEvents = map[string]bool{
	"peer_contact":        true,
	"peer_rejected":       true,
	"path_direct":         true,
	"derp_connected":      true,
	"derp_lost":           true,
	"derp_closed":         true,
	"derp_home":           true,
	"network_changed":     true,
	"network_down":        true,
	"conn_opened":         true,
	"conn_closed":         true,
	"backend_dial_failed": true,
}

var (
	peerPattern   = regexp.MustCompile(`^\[[A-Za-z0-9+/]{5}\]$`)
	reasonPattern = regexp.MustCompile(`^[a-z][a-z_-]{0,39}$`)

	keyPattern  = regexp.MustCompile(`(?i)\b(?:nodekey|privkey|discokey|mkey):[0-9a-f]+`)
	ipv4Pattern = regexp.MustCompile(`\b\d{1,3}(?:\.\d{1,3}){3}\b`)
	ipv6Pattern = regexp.MustCompile(`[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(?:%[0-9A-Za-z]+)?`)
	blobPattern = regexp.MustCompile(`[A-Za-z0-9_-]{40,}`)
)

var current atomic.Pointer[debuglog.Sink]

// Install 设为进程内当前的事件日志，返回撤销函数。没有安装时（命令行直接运行）事件被丢弃。
func Install(sink *debuglog.Sink) func() {
	previous := current.Swap(sink)
	return func() { current.CompareAndSwap(sink, previous) }
}

// Record 记录 agentd 自己观察到的辅助程序生命周期。detail 是自由文本，会先脱敏。
func Record(event, detail string) {
	sink := current.Load()
	if sink == nil {
		return
	}
	if detail = Redact(detail); detail != "" {
		sink.Printf(component, "event=%s detail=%q", event, detail)
		return
	}
	sink.Printf(component, "event=%s", event)
}

// RecordSidecarLine 处理辅助程序 stderr 的一行，返回它是否为结构化事件。结构化事件不再
// 转发给标准日志，避免前台运行 agentd 时刷屏。非法事件直接丢弃，不当作自由文本落盘。
func RecordSidecarLine(line string) bool {
	payload, ok := strings.CutPrefix(line, LinePrefix)
	if !ok {
		Record(eventSidecarLog, line)
		return false
	}
	sink := current.Load()
	if sink == nil {
		return true
	}
	if rendered, ok := renderSidecarEvent(payload); ok {
		sink.Printf(component, "%s", rendered)
	}
	return true
}

func renderSidecarEvent(payload string) (string, bool) {
	var event struct {
		Name   string `json:"event"`
		Peer   string `json:"peer"`
		Region int    `json:"region"`
		Reason string `json:"reason"`
		Millis int64  `json:"ms"`
	}
	if json.Unmarshal([]byte(payload), &event) != nil || !sidecarEvents[event.Name] {
		return "", false
	}
	rendered := "event=" + event.Name
	if peerPattern.MatchString(event.Peer) {
		rendered += " peer=" + event.Peer
	}
	if event.Region > 0 && event.Region <= 65535 {
		rendered += fmt.Sprintf(" region=%d", event.Region)
	}
	if reasonPattern.MatchString(event.Reason) {
		rendered += " reason=" + event.Reason
	}
	if event.Millis > 0 {
		rendered += fmt.Sprintf(" ms=%d", event.Millis)
	}
	return rendered, true
}

// Redact 去掉公钥、IP 与地址串。令牌和主目录由 debuglog 的写入路径再处理一次。
func Redact(message string) string {
	message = strings.TrimSpace(message)
	message = keyPattern.ReplaceAllString(message, "<key>")
	message = ipv4Pattern.ReplaceAllString(message, "<ip>")
	// 候选里还会混进 12:30:45 这样的时间，只替换确实能解析成 IPv6 的片段。
	message = ipv6Pattern.ReplaceAllStringFunc(message, func(candidate string) string {
		if address, err := netip.ParseAddr(candidate); err == nil && address.Is6() {
			return "<ip>"
		}
		return candidate
	})
	message = blobPattern.ReplaceAllString(message, "<redacted>")
	return message
}
