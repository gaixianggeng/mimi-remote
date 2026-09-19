package httpapi

import (
	"encoding/json"
	"errors"
	"sync/atomic"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 两个生产入口必须对同一页给出相同的进度/结束判断；异常空页不得污染共享缓存。
func TestDeepSeekHistoryReadersShareProgressRules(t *testing.T) {
	for _, test := range []struct {
		name         string
		records      []any
		hasMore      bool
		emptyInitial bool
		wantStalled  bool
	}{
		{name: "empty but more", hasMore: true, wantStalled: true},
		{name: "same seq but more", hasMore: true, wantStalled: true, records: []any{
			map[string]any{"type": "turn/end", "seq": 100, "data": map[string]any{"turn": 3}},
		}},
		{name: "empty at start"},
		{name: "complete final page", records: []any{
			map[string]any{"type": "turn/start", "seq": 10, "data": map[string]any{"turn": 3}},
		}},
		{name: "empty snapshot can fetch", emptyInitial: true, records: []any{
			map[string]any{"type": "turn/start", "seq": 10, "data": map[string]any{"turn": 3}},
		}},
	} {
		for _, reader := range []string{"turn page", "turn items"} {
			t.Run(test.name+"/"+reader, func(t *testing.T) {
				harness := newFakeDeepSeekHarness(t)
				var calls atomic.Int32
				harness.handle(harnessclient.MethodSessionPage, func(json.RawMessage) (any, *harnessclient.RemoteError) {
					calls.Add(1)
					return map[string]any{"records": test.records, "hasMore": test.hasMore}, nil
				})
				conn := newDeepSeekHistoryConn(t, harness)
				follow := &deepSeekFollow{threadID: "s-progress", throughSeq: 100, updated: make(chan struct{}, 1)}
				if !test.emptyInitial {
					follow.note([]harnessclient.SessionWireEvent{{
						Type: deepSeekEventTurnEnd, Seq: 100, Data: json.RawMessage(`{"turn":3}`),
					}})
				}
				var err error
				if reader == "turn page" {
					_, _, _, err = conn.deepSeekTurnPage(t.Context(), follow, map[string]any{})
				} else {
					_, err = conn.ensureTurnRecords(t.Context(), follow, 3)
				}
				if errors.Is(err, errDeepSeekHistoryPagingStalled) != test.wantStalled {
					t.Fatalf("两个历史入口必须拒绝相同的停滞页：err=%v", err)
				}
				if follow.atStart() == test.hasMore {
					t.Fatalf("hasMore=%v 不能得到 reachedStart=%v", test.hasMore, follow.atStart())
				}
				if calls.Load() != 1 {
					t.Fatalf("必须读取一页并按进度结束或报错，调用数=%d", calls.Load())
				}
				if len(test.records) > 0 && !test.hasMore && err != nil {
					t.Fatalf("完整页应成功返回指定轮次：%v", err)
				}
			})
		}
	}
}
