package httpapi

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// #873：iOS 在长回合进行中按已完成的条目提交 last_seen，而不只在回合结束时提交。
// 这种回合中途的游标落在网关已转发的范围内、bridge 仍在同一编号序列里，网关必须
// 原样交给 bridge 续传，且不能发 cursor reset：reset 会让 App 把游标清零，下次重开
// 又整轮重放，已答复的补充信息请求随之再弹出一次。
func TestClaudeGatewayTrustsMidTurnItemCursorWithoutReset(t *testing.T) {
	dir := t.TempDir()
	attachPath := filepath.Join(dir, "attach.jsonl")
	markPath := filepath.Join(dir, "attached-once")
	bridge := writeTestBridge(t, fmt.Sprintf(`#!/bin/sh
IFS= read -r line
printf '%%s\n' "$line" >> %q
if [ ! -f %q ]; then
  : > %q
  printf '{"jsonrpc":"2.0","method":"_alleycat/attached","params":{"sessionKey":"dev-873","kind":"fresh","currentSeq":0,"floorSeq":1}}\n'
  printf '{"jsonrpc":"2.0","id":"mimi-1","method":"item/tool/requestUserInput","params":{"threadId":"thr_873","turnId":"turn_873","itemId":"ask-1","questions":[]},"_alleycat_seq":1}\n'
  printf '{"jsonrpc":"2.0","method":"serverRequest/resolved","params":{"threadId":"thr_873","requestId":"mimi-1"},"_alleycat_seq":2}\n'
  printf '{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thr_873","turnId":"turn_873","item":{"type":"agentMessage","id":"msg-1","text":"done"}},"_alleycat_seq":3}\n'
  printf '{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{"phase":"first"},"_alleycat_seq":4}\n'
else
  printf '{"jsonrpc":"2.0","method":"_alleycat/attached","params":{"sessionKey":"dev-873","kind":"resumed","currentSeq":4,"floorSeq":1}}\n'
  printf '{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{"phase":"after-cursor"},"_alleycat_seq":5}\n'
fi
while IFS= read -r line; do :; done
`, attachPath, markPath, markPath))
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, router := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = 3
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	first := dialAuthedGatewaySession(t, server.URL, "claude", "dev-873")
	for {
		if raw := readGatewayRaw(t, first); bytes.Contains(raw, []byte(`"phase":"first"`)) {
			break
		}
	}
	waitForClaudeResumeCursor(t, router, "dev-873", 4)
	_ = first.Close()

	// App 已投影到 item/completed（seq 3），回合仍在进行。
	target := wsURL(server.URL, appServerGatewayPath) + "?runtime=claude&session=dev-873&last_seen=3"
	second, _, err := websocket.DefaultDialer.Dial(target, http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	resumed := readTestFileLineEventually(t, attachPath, `"lastSeen":3`)
	if !bytes.Contains(resumed, []byte(`"lastSeen":3`)) {
		t.Fatalf("回合中途的条目游标应原样交给 bridge 续传：%s", resumed)
	}
	next := readGatewayRaw(t, second)
	if bytes.Contains(next, []byte(claudeReplayCursorResetMethod)) {
		t.Fatalf("同一编号序列内续传不应让 App 清零游标：%s", next)
	}
	if !bytes.Contains(next, []byte(`"phase":"after-cursor"`)) {
		t.Fatalf("重连后应直接收到游标之后的帧：%s", next)
	}
}

func waitForClaudeResumeCursor(t *testing.T, router *Router, sessionKey string, want uint64) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if got, ok := router.claudeBridge.resumeCursor(sessionKey); ok && got >= want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("网关转发到 seq %d 后应记下该会话的投递进度", want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
