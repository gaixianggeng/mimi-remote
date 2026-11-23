package runtimestatus

import "time"

const (
	// 单次探测并行等待 Codex、Claude 与可选的 Antigravity；真实 agy 首次冷登录探测可达 8–10 秒
	// （单飞 auth 探针上限 15 秒），预留 18 秒覆盖冷探测与适配器握手，避免 /api/runtime/status 提前误报不可用（B11 round4）。
	ProbeGenerationTimeout = 18 * time.Second
	CachedHTTPTimeout      = 2 * time.Second

	// 点击刷新时可能要先等点击前的后台 generation，再等待一次点击后的 follow-up。
	// 额外两秒用于 HTTP 响应、JSON 解码和本机调度抖动。
	ForcedRefreshHTTPTimeout = 2*ProbeGenerationTimeout + 2*time.Second
	ManualCommandTimeout     = ForcedRefreshHTTPTimeout + 5*time.Second
)
