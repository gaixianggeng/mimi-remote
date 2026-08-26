package runtimestatus

import "time"

const (
	// 单次探测同时等待 Codex 与 Claude，服务端会在这个窗口后结束该 generation。
	ProbeGenerationTimeout = 9 * time.Second
	CachedHTTPTimeout      = 2 * time.Second

	// 点击刷新时可能要先等点击前的后台 generation，再等待一次点击后的 follow-up。
	// 额外两秒用于 HTTP 响应、JSON 解码和本机调度抖动。
	ForcedRefreshHTTPTimeout = 2*ProbeGenerationTimeout + 2*time.Second
	ManualCommandTimeout     = ForcedRefreshHTTPTimeout + 5*time.Second
)
