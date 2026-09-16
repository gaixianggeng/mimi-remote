package httpapi

import (
	"context"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// 本文件覆盖会话订阅的生命周期边界：上游断流之后，连接不能继续装成还活着。

// 回归：会话订阅断流必须显式结束连接，并归还它占用的名额。
//
// 原先 readFollow 在流关闭时静默 return，三件事都没有做：死订阅留在 follows 里被
// 后续请求当成活的复用（历史读不完、turn/start 等不到编号，而调用方看到的是
// "没有错误、也没有结果"），名额永不归还（每断一次少一个并发数，最后表现为一个
// 明明可用却连不上的运行时），连接本身也继续挂着。
func TestDeepSeekFollowStreamClosureTearsDownAndReleasesSlot(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	conn := newDeepSeekHistoryConn(t, harness)

	// 上限设成 1：名额有没有真的归还，一次 acquire 就能验出来。
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = "http://127.0.0.1:5173"
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, "startup-token")
		cfg.DeepSeek.MaxConcurrentSessions = 1
	})
	conn.router = server.router
	if !conn.router.acquireDeepSeekSession() {
		t.Fatal("应能获取一个会话名额")
	}

	stream, err := conn.harness.FollowSession(context.Background(), "s-closed", true)
	if err != nil {
		t.Fatalf("订阅会话失败：%v", err)
	}
	follow := &deepSeekFollow{
		threadID: "s-closed",
		stream:   stream,
		updated:  make(chan struct{}, 1),
	}
	conn.follows = map[string]*deepSeekFollow{"s-closed": follow}
	done := make(chan string, 8)
	conn.done = done

	go conn.readFollow(context.Background(), follow)

	// Harness 侧断开这条订阅。
	stream.Close()

	select {
	case reason := <-done:
		if reason != "follow_stream_closed" {
			t.Fatalf("断流应报告明确原因，得到 %q", reason)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("上游断流后连接必须显式失败，不能静默留着")
	}
	if _, ok := conn.follows["s-closed"]; ok {
		t.Fatal("断掉的订阅必须从 follows 摘掉，否则会被后续请求当成活的复用")
	}
	if !conn.router.acquireDeepSeekSession() {
		t.Fatal("断流必须归还名额，否则上限会被逐次耗尽")
	}
}
