package httpapi

import (
	"crypto/sha256"
	"log"
	"time"
)

// 只追踪 thread/list 的时间边界；请求 ID 取摘要，不输出参数、目录或会话内容。
// upstream_received 包含写入、SSH/Codex 往返及此前帧处理的等待，不能等同于 Codex 计算时间。
func (c *relayGatewayConnMonitor) logSessionListStage(payload []byte, stage string, duration time.Duration) {
	if c == nil || c.parent == nil {
		return
	}
	meta := relayFrameMetaFromPayload(payload)
	method := meta.Method
	if meta.IsResponse && meta.ID != "" {
		c.parent.mu.Lock()
		var pending relayPendingRPC
		if conn := c.parent.active[c.id]; conn != nil {
			pending = conn.pendingRPC[meta.ID]
		}
		c.parent.mu.Unlock()
		method = pending.Method
		if stage == "upstream_received" && !pending.SentAt.IsZero() {
			duration = time.Since(pending.SentAt)
		}
	}
	if method != "thread/list" || meta.ID == "" {
		return
	}
	digest := sha256.Sum256([]byte(meta.ID))
	log.Printf("session_list_trace connection=%s rpc=%x stage=%s duration_ms=%.3f at_unix_ms=%d bytes=%d",
		c.id, digest[:8], stage, float64(duration)/float64(time.Millisecond), time.Now().UnixMilli(), len(payload))
}
