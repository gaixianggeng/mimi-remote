package httpapi

import "context"

const appServerRuntimeActiveTurnLimit = 20

type appServerTurnListPage struct {
	Data []appServerTurn `json:"data"`
}

// readThreadMetadata 只读取会话元数据。历史由客户端通过 app-server gateway 分页读取。
func (r *CodexAppServerRuntime) readThreadMetadata(ctx context.Context, threadID string) (appServerThread, error) {
	var envelope appServerThreadEnvelope
	if err := r.call(ctx, "thread/read", map[string]any{
		"threadId": threadID, "includeTurns": false,
	}, &envelope); err != nil {
		return appServerThread{}, err
	}
	return envelope.Thread, nil
}

// readLatestTurns 仅为停止会话兜底读取最近一页，不读取 turn items。
func (r *CodexAppServerRuntime) readLatestTurns(ctx context.Context, threadID string) ([]appServerTurn, error) {
	var page appServerTurnListPage
	err := r.call(ctx, "thread/turns/list", map[string]any{
		"threadId":      threadID,
		"limit":         appServerRuntimeActiveTurnLimit,
		"sortDirection": "desc",
		"itemsView":     "notLoaded",
	}, &page)
	return page.Data, err
}
