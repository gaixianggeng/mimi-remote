package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

func TestDeepSeekTurnCursorKeepsPositionWhenLiveTurnArrives(t *testing.T) {
	follow := &deepSeekFollow{
		threadID: "s-1", throughSeq: 77, updated: make(chan struct{}, 1),
	}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 10, Data: json.RawMessage(`{"turn":1}`)},
		{Type: deepSeekEventTurnStart, Seq: 20, Data: json.RawMessage(`{"turn":2}`)},
	})

	conn := &deepSeekGatewayConn{}
	first, cursor, hasMore, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{"limit": 1})
	if err != nil || len(first) != 1 || first[0].Turn != 2 || !hasMore || cursor == "" {
		t.Fatalf("第一页不符：page=%+v cursor=%q hasMore=%v err=%v", first, cursor, hasMore, err)
	}

	// 直播在列表头插入 turn 3。纯 offset=1 会再次返回 turn 2；锚点应把下一页重新
	// 定位到 turn 2 之后，因此仍返回更早的 turn 1。
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 30, Data: json.RawMessage(`{"turn":3}`)},
	})
	second, _, _, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{
		"limit": 1, "cursor": cursor,
	})
	if err != nil || len(second) != 1 || second[0].Turn != 1 {
		t.Fatalf("直播更新后下一页不得重复或跳页：page=%+v err=%v", second, err)
	}
}

func TestDeepSeekTurnPageSupportsAscendingAfterReadingSessionStart(t *testing.T) {
	follow := &deepSeekFollow{
		threadID: "s-1", throughSeq: 77, updated: make(chan struct{}, 1),
	}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 10, Data: json.RawMessage(`{"turn":1}`)},
		{Type: deepSeekEventTurnStart, Seq: 20, Data: json.RawMessage(`{"turn":2}`)},
	})
	follow.markReachedStart()

	conn := &deepSeekGatewayConn{}
	first, cursor, hasMore, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{
		"limit": 1, "sortDirection": "asc",
	})
	if err != nil || len(first) != 1 || first[0].Turn != 1 || !hasMore || cursor == "" {
		t.Fatalf("asc 第一页不符：page=%+v cursor=%q hasMore=%v err=%v", first, cursor, hasMore, err)
	}
	second, next, secondHasMore, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{
		"limit": 1, "sortDirection": "asc", "cursor": cursor,
	})
	if err != nil || len(second) != 1 || second[0].Turn != 2 || secondHasMore || next != "" {
		t.Fatalf("asc 第二页不符：page=%+v cursor=%q hasMore=%v err=%v", second, next, secondHasMore, err)
	}
}

func TestDeepSeekTurnPageAscendingUsesProgressCursorBeforeSessionStart(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	seq := int64(99)
	harness.handle(harnessclient.MethodSessionPage, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		current := seq
		seq--
		return map[string]any{
			// 已确认存在但不能独立投影成 turn 的历史片段，只推进上游读取位置。
			"records": []any{
				map[string]any{"type": "step/start", "seq": current, "data": map[string]any{"turn": 1, "step": 1}},
			},
			"hasMore": true,
		}, nil
	})
	conn := newDeepSeekHistoryConn(t, harness)
	follow := &deepSeekFollow{threadID: "s-1", throughSeq: 100, updated: make(chan struct{}, 1)}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 100, Data: json.RawMessage(`{"turn":1}`)},
	})

	page, cursor, hasMore, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{
		"limit": 1, "sortDirection": "asc",
	})
	if err != nil || len(page) != 0 || !hasMore || cursor == "" {
		t.Fatalf("asc 未读到开头前只能返回进度游标：page=%+v cursor=%q hasMore=%v err=%v", page, cursor, hasMore, err)
	}
	parsed, err := parseDeepSeekTurnPageCursor(cursor, "asc", follow)
	if err != nil || parsed.Offset != 0 || parsed.OldestSeq >= 100 {
		t.Fatalf("asc 进度游标不符：cursor=%q parsed=%+v err=%v", cursor, parsed, err)
	}
}

func TestDeepSeekTurnPageAcceptsLegacyOffsetCursorForDescending(t *testing.T) {
	follow := &deepSeekFollow{
		threadID: "s-1", throughSeq: 77, updated: make(chan struct{}, 1),
	}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 10, Data: json.RawMessage(`{"turn":1}`)},
		{Type: deepSeekEventTurnStart, Seq: 20, Data: json.RawMessage(`{"turn":2}`)},
		{Type: deepSeekEventTurnStart, Seq: 30, Data: json.RawMessage(`{"turn":3}`)},
	})
	follow.markReachedStart()

	page, cursor, hasMore, err := (&deepSeekGatewayConn{}).deepSeekTurnPage(
		context.Background(), follow, map[string]any{"limit": 1, "cursor": "ds-offset:1"},
	)
	if err != nil || len(page) != 1 || page[0].Turn != 2 || !hasMore || cursor == "" {
		t.Fatalf("旧 offset 游标必须继续可用并升级为新游标：page=%+v cursor=%q hasMore=%v err=%v", page, cursor, hasMore, err)
	}
}

func TestDeepSeekTurnCursorRejectsInvalidOrRecycledSnapshot(t *testing.T) {
	follow := &deepSeekFollow{
		threadID: "s-1", throughSeq: 77, updated: make(chan struct{}, 1),
	}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 10, Data: json.RawMessage(`{"turn":1}`)},
	})
	cursor := deepSeekTurnPageCursor{
		Direction: "desc", Offset: 1, ThroughSeq: 77, OldestSeq: 10,
		AnchorTurn: 1, AnchorSet: true,
	}.encode()

	if _, err := parseDeepSeekTurnPageCursor("not-a-cursor", "desc", follow); !errors.Is(err, errDeepSeekTurnPageCursor) {
		t.Fatalf("非法游标必须明确失败：%v", err)
	}
	if _, err := parseDeepSeekTurnPageCursor(cursor, "asc", follow); !errors.Is(err, errDeepSeekTurnPageCursor) {
		t.Fatalf("游标不得跨 sortDirection 使用：%v", err)
	}

	recycled := &deepSeekFollow{
		threadID: "s-1", throughSeq: 88, updated: make(chan struct{}, 1),
	}
	recycled.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 10, Data: json.RawMessage(`{"turn":1}`)},
	})
	if _, err := parseDeepSeekTurnPageCursor(cursor, "desc", recycled); !errors.Is(err, errDeepSeekTurnPageCursor) {
		t.Fatalf("follow 重建后的旧游标必须失效：%v", err)
	}

	shorter := &deepSeekFollow{
		threadID: "s-1", throughSeq: 77, updated: make(chan struct{}, 1),
	}
	shorter.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 20, Data: json.RawMessage(`{"turn":2}`)},
	})
	if _, err := parseDeepSeekTurnPageCursor(cursor, "desc", shorter); !errors.Is(err, errDeepSeekTurnPageCursor) {
		t.Fatalf("缓存比游标快照更短时必须失效：%v", err)
	}
}

func TestDeepSeekTurnPageFailsWhenHarnessDoesNotAdvanceBeforeSeq(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionPage, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{
			"records": []any{
				map[string]any{"type": "step/start", "seq": 99, "data": map[string]any{"turn": 1, "step": 1}},
			},
			"hasMore": true,
		}, nil
	})
	conn := newDeepSeekHistoryConn(t, harness)
	follow := &deepSeekFollow{threadID: "s-1", throughSeq: 100, updated: make(chan struct{}, 1)}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 100, Data: json.RawMessage(`{"turn":1}`)},
	})

	_, _, _, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{})
	if !errors.Is(err, errDeepSeekHistoryPagingStalled) {
		t.Fatalf("上游重复同一 beforeSeq 页时必须失败，不能制造重复游标：%v", err)
	}
}

func TestDeepSeekTurnPageCanStartFromEmptySnapshot(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionPage, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{
			"records": []any{
				map[string]any{"type": "turn/start", "seq": 10, "data": map[string]any{"turn": 1}},
			},
			"hasMore": false,
		}, nil
	})
	conn := newDeepSeekHistoryConn(t, harness)
	follow := &deepSeekFollow{threadID: "s-1", throughSeq: 20, updated: make(chan struct{}, 1)}

	page, cursor, hasMore, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{})
	if err != nil || len(page) != 1 || page[0].Turn != 1 || hasMore || cursor != "" {
		t.Fatalf("空快照应从无 beforeSeq 的第一页开始：page=%+v cursor=%q hasMore=%v err=%v", page, cursor, hasMore, err)
	}
}
