package httpapi

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件覆盖会话历史的分页边界。
//
// 两类边界容易在本地缓存上被抹平：分页到底了没有，以及一个 turn 的记录取全了没有。
// 两者都会让客户端拿到一个"看起来正常但少了一截"的历史——不报错，只是变短。

// newDeepSeekHistoryConn 起一个连着假 Harness 的连接，用于直接驱动历史分页。
func newDeepSeekHistoryConn(t *testing.T, harness *fakeDeepSeekHarness) *deepSeekGatewayConn {
	t.Helper()
	harnessServer := harness.serve()
	client, err := harnessclient.New(harnessclient.Config{
		BaseURL:     harnessServer.URL,
		AccessToken: harness.token,
	})
	if err != nil {
		t.Fatalf("建立 Harness 客户端失败：%v", err)
	}
	if err := client.Authenticate(context.Background()); err != nil {
		t.Fatalf("认证失败：%v", err)
	}
	return &deepSeekGatewayConn{harness: client}
}

// 回归：缓存读完了不等于宿主历史读完了。
//
// 订阅的开场快照只覆盖到 cursor 切点为止，更早的轮次还在 Harness 上；而一次请求向前
// 取历史还有页数上限。两种情况下缓存都已读完，但会话并没有读到开头。此时若因为
// "end 已经到缓存末尾"就回 nextCursor=null，客户端会把缓存边界当成会话开头，
// 更早的轮次再也翻不出来——而且不报错，只是历史看起来变短了。
func TestDeepSeekTurnPageKeepsPagingWhileHistoryRemains(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	// 上游一直说"还有更早的记录"，但页里没有任何 turn/start，因此缓存里的 turn 数
	// 不会增长——这正是"一次请求的取页上限用尽，而宿主历史仍未读完"的形态。
	harness.handle(harnessclient.MethodSessionPage, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{
			"records": []any{
				map[string]any{"type": "step/start", "seq": 0, "data": map[string]any{"turn": 1, "step": 1}},
			},
			"hasMore": true,
		}, nil
	})
	conn := newDeepSeekHistoryConn(t, harness)

	follow := &deepSeekFollow{threadID: "s-1", turnStarts: make(chan int64, 1)}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 1, Data: json.RawMessage(`{"turn":1}`)},
	})
	// 刻意不调 markReachedStart：开场快照声明 hasMore，即还有更早的记录。

	page, next, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{})
	if err != nil {
		t.Fatalf("取页失败：%v", err)
	}
	if len(page) != 1 {
		t.Fatalf("应返回缓存里的那一轮：%+v", page)
	}
	if next == 0 {
		t.Fatal("宿主历史还没读完时不得收尾：客户端会把缓存边界当成会话开头")
	}
	// 走真实的出参路径，确认这个偏移量确实变成了一个可回传的游标而不是 null。
	cursor, _ := deepSeekPageResult(nil, next)["nextCursor"].(string)
	if cursor == "" {
		t.Fatalf("下一页游标必须可被回传：%d", next)
	}
	if offset, ok := deepSeekOffsetCursor(cursor); !ok || offset != next {
		t.Fatalf("游标必须能解析回同一个偏移：%q => %d, %v", cursor, offset, ok)
	}
}

// 反过来也成立：确实读到了会话开头就应收尾，不能永远翻下去。
func TestDeepSeekTurnPageStopsAtSessionStart(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionPage, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"records": []any{}, "hasMore": false}, nil
	})
	conn := newDeepSeekHistoryConn(t, harness)

	follow := &deepSeekFollow{threadID: "s-1", turnStarts: make(chan int64, 1)}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 1, Data: json.RawMessage(`{"turn":1}`)},
	})
	follow.markReachedStart()

	page, next, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{})
	if err != nil {
		t.Fatalf("取页失败：%v", err)
	}
	if len(page) != 1 {
		t.Fatalf("应返回缓存里的那一轮：%+v", page)
	}
	if next != 0 {
		t.Fatalf("读到会话开头就应收尾，得到游标 %d", next)
	}
	if _, present := deepSeekPageResult(nil, next)["nextCursor"]; !present {
		t.Fatal("分页结果必须带 nextCursor 键（可为 null）")
	}
}

// 回归：被分页切掉开头的 turn 不得标 itemsView=full。
//
// 分页只能向前取，缓存最老的一端可能落在一轮中间，于是这一轮在缓存里只剩一条
// turn/end。原先无论桶是否完整都标 full，而 iOS 见到 full 就不会再请求 items/list，
// 这一轮便以"已完成、没有正文"的样子定稿：不报错，只是内容消失了。
func TestDeepSeekTurnWireDoesNotClaimFullForTruncatedTurn(t *testing.T) {
	records := []harnessclient.SessionWireEvent{
		// 被切掉开头的一轮：只剩 turn/end。
		{Type: deepSeekEventTurnEnd, Seq: 100, Data: json.RawMessage(`{"turn":3,"reason":{"kind":"completed"}}`)},
		// 完整的一轮。
		{Type: deepSeekEventTurnStart, Seq: 110, Data: json.RawMessage(`{"turn":4}`)},
		{Type: deepSeekEventUserMessage, Seq: 111, Data: json.RawMessage(
			`{"id":"m1","role":"user","content":[{"type":"text","text":"你好"}],"source":{"kind":"user","rpcId":"msg-1"}}`)},
		{Type: deepSeekEventAssistantMessage, Seq: 112, Data: json.RawMessage(
			`{"message":{"id":"a1","role":"assistant","content":[{"type":"text","text":"收到"}]},"turn":4,"step":1}`)},
		{Type: deepSeekEventTurnEnd, Seq: 120, Data: json.RawMessage(`{"turn":4,"reason":{"kind":"completed"}}`)},
	}
	buckets := deepSeekSplitTurns(records)
	if len(buckets) != 2 {
		t.Fatalf("应切出两轮：%+v", buckets)
	}

	truncated := deepSeekTurnWire(buckets[0], true)
	if truncated["itemsView"] == "full" {
		t.Fatalf("被切掉开头的 turn 不得标 full，否则 iOS 不会再补历史：%+v", truncated)
	}
	if items, _ := truncated["items"].([]any); len(items) != 0 {
		t.Fatalf("残缺 turn 不该凭空带出内容：%+v", truncated)
	}

	complete := deepSeekTurnWire(buckets[1], true)
	if complete["itemsView"] != "full" {
		t.Fatalf("完整的一轮应标 full，避免多余往返：%+v", complete)
	}
	if items, _ := complete["items"].([]any); len(items) != 2 {
		t.Fatalf("完整的一轮应带出两条 item：%+v", items)
	}
}

// 与上一条配套：客户端按 summary 回头请求 items 时，必须真的把缺的历史补回来，
// 而不是把缓存里那个残缺的桶原样返回——那等于换个路径再撒一次同样的谎。
func TestDeepSeekEnsureTurnRecordsPagesBackForTruncatedTurn(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionPage, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{
			"records": []any{
				map[string]any{"type": "turn/start", "seq": 10, "data": map[string]any{"turn": 3}},
				map[string]any{"type": "user/message", "seq": 11, "data": map[string]any{
					"id": "m1", "role": "user",
					"content": []any{map[string]any{"type": "text", "text": "第一轮的问题"}},
				}},
			},
			"hasMore": false,
		}, nil
	})
	conn := newDeepSeekHistoryConn(t, harness)

	follow := &deepSeekFollow{threadID: "s-1", turnStarts: make(chan int64, 1)}
	follow.note([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnEnd, Seq: 100, Data: json.RawMessage(`{"turn":3,"reason":{"kind":"completed"}}`)},
	})

	bucket, err := conn.ensureTurnRecords(context.Background(), follow, 3)
	if err != nil {
		t.Fatalf("残缺的 turn 应能靠向前分页补齐：%v", err)
	}
	if !bucket.Started {
		t.Fatalf("必须补出这一轮的 turn/start 才算完整：%+v", bucket)
	}
	if items := deepSeekTurnItems(bucket); len(items) != 1 {
		t.Fatalf("补齐后应能看到这一轮的用户消息：%+v", items)
	}
}
