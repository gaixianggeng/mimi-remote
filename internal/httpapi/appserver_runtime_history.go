package httpapi

import (
	"context"
	"fmt"
)

type appServerTurnListPage struct {
	Data       []appServerTurn `json:"data"`
	NextCursor string          `json:"nextCursor"`
}

type appServerThreadItemEntry struct {
	TurnID string              `json:"turnId"`
	Item   appServerThreadItem `json:"item"`
}

type appServerItemListPage struct {
	Data       []appServerThreadItemEntry `json:"data"`
	NextCursor string                     `json:"nextCursor"`
}

// readThreadPaginated 先读取不含历史的 thread 元数据，再分页读取 turns
// 与 items。它是 Go 内部 runtime 唯一的完整历史路径，禁止回退到
// thread/read(includeTurns:true)，避免分页会话触发弃用警告。
func (r *CodexAppServerRuntime) readThreadPaginated(ctx context.Context, threadID string) (appServerThread, error) {
	var envelope appServerThreadEnvelope
	if err := r.call(ctx, "thread/read", map[string]any{
		"threadId": threadID, "includeTurns": false,
	}, &envelope); err != nil {
		return appServerThread{}, err
	}

	turns := make([]appServerTurn, 0, 32)
	turnCursor := ""
	for {
		params := map[string]any{
			"threadId": threadID, "limit": 50, "sortDirection": "asc", "itemsView": "notLoaded",
		}
		if turnCursor != "" {
			params["cursor"] = turnCursor
		}
		var page appServerTurnListPage
		if err := r.call(ctx, "thread/turns/list", params, &page); err != nil {
			return appServerThread{}, fmt.Errorf("分页读取 thread turns 失败：%w", err)
		}
		turns = append(turns, page.Data...)
		if page.NextCursor == "" || page.NextCursor == turnCursor {
			break
		}
		turnCursor = page.NextCursor
	}

	itemsByTurn := make(map[string][]appServerThreadItem, len(turns))
	itemCursor := ""
	for {
		params := map[string]any{
			"threadId": threadID, "limit": 250, "sortDirection": "asc",
		}
		if itemCursor != "" {
			params["cursor"] = itemCursor
		}
		var page appServerItemListPage
		if err := r.call(ctx, "thread/items/list", params, &page); err != nil {
			return appServerThread{}, fmt.Errorf("分页读取 thread items 失败：%w", err)
		}
		for _, entry := range page.Data {
			itemsByTurn[entry.TurnID] = append(itemsByTurn[entry.TurnID], entry.Item)
		}
		if page.NextCursor == "" || page.NextCursor == itemCursor {
			break
		}
		itemCursor = page.NextCursor
	}
	for index := range turns {
		turns[index].Items = itemsByTurn[turns[index].ID]
	}
	envelope.Thread.Turns = turns
	return envelope.Thread, nil
}
