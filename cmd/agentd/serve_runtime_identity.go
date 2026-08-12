package main

import (
	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
)

// configureServeCodexRuntimeIdentity 把 serve 层实际启动的 upstream 身份交给 HTTP Router。
// 只有真实 managed WebSocket 或 shared local daemon 启动时间可作为 runtime identity，
// 外部 upstream 不写入身份，避免把 agentd 的启动时间误报为 Codex runtime 启动时间。
func configureServeCodexRuntimeIdentity(
	apiRouter *httpapi.Router,
	appServerWSProcess *appserver.ManagedWebSocketProcess,
	sharedDaemonStatus appserver.LocalDaemonStatus,
) {
	if appServerWSProcess != nil {
		apiRouter.SetCodexRuntimeIdentity(
			httpapi.CodexRuntimeKindManagedWebSocket,
			appServerWSProcess.StartedAt(),
		)
	} else if !sharedDaemonStatus.StartedAt.IsZero() {
		apiRouter.SetCodexRuntimeIdentity(
			httpapi.CodexRuntimeKindLocalDaemon,
			sharedDaemonStatus.StartedAt,
		)
	}
}
