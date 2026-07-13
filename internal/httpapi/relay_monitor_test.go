package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRelayMonitorTracksHistoryTrafficByMethod(t *testing.T) {
	monitor := newRelayMonitor()
	if !monitor.reserveHistoryInflight("list-fingerprint", "owner-1", "thread/list", time.Minute) {
		t.Fatal("首个 thread/list 指纹应登记成功")
	}
	if monitor.reserveHistoryInflight("list-fingerprint", "owner-2", "thread/list", time.Minute) {
		t.Fatal("重复 thread/list 指纹应被拒绝")
	}

	monitor.recordHistoryResponseMetrics("thread/list", 1200, true)
	monitor.recordHistoryRateLimited("thread/list")
	monitor.releaseHistoryInflight("list-fingerprint", "owner-1")

	stats := monitor.snapshot().AppServerGateway.Methods["thread/list"]
	if stats.Requested != 2 || stats.Inflight != 0 {
		t.Fatalf("requested/inflight 统计异常：%+v", stats)
	}
	if stats.DuplicateRejected != 1 || stats.Rejected != 2 {
		t.Fatalf("duplicate/rejected 统计异常：%+v", stats)
	}
	if stats.Blocked != 1 || stats.RateLimited != 1 || stats.ResponseBytes != 1200 {
		t.Fatalf("blocked/rate-limited/response bytes 统计异常：%+v", stats)
	}
}

func TestRelayMonitorHistoryInflightOwnerPreventsLateRelease(t *testing.T) {
	monitor := newRelayMonitor()
	if !monitor.reserveHistoryInflight("history-fingerprint", "new-owner", "thread/turns/list", time.Minute) {
		t.Fatal("首个指纹应登记成功")
	}
	monitor.releaseHistoryInflight("history-fingerprint", "stale-owner")

	stats := monitor.snapshot().AppServerGateway.Methods["thread/turns/list"]
	if stats.Inflight != 1 {
		t.Fatalf("旧 owner 不应释放新请求：%+v", stats)
	}
	monitor.releaseHistoryInflight("history-fingerprint", "new-owner")
	stats = monitor.snapshot().AppServerGateway.Methods["thread/turns/list"]
	if stats.Inflight != 0 {
		t.Fatalf("正确 owner 应释放请求：%+v", stats)
	}
}

func TestRelayMonitorRecordsBoundedStructuredTerminationWithoutCloseText(t *testing.T) {
	monitor := newRelayMonitor()
	connection := monitor.startGatewayConnection("100.64.0.2", "mac.tailnet.ts.net", "ws://127.0.0.1:4222/", 3*time.Millisecond)
	connection.finish(gatewayCloseReason("client_read", &websocket.CloseError{
		Code: websocket.CloseAbnormalClosure,
		Text: "token=secret prompt=private file=/Users/me/project.txt",
	}))

	snapshot := monitor.snapshot().AppServerGateway
	if snapshot.TerminationCounts["client_read.connection_lost"] != 1 {
		t.Fatalf("异常断线应按阶段和类别聚合：%+v", snapshot.TerminationCounts)
	}
	if len(snapshot.RecentTerminations) != 1 {
		t.Fatalf("应保留一条最近断线样本：%+v", snapshot.RecentTerminations)
	}
	sample := snapshot.RecentTerminations[0]
	if sample.Stage != "client_read" || sample.Kind != "connection_lost" || sample.WebSocketCode != websocket.CloseAbnormalClosure {
		t.Fatalf("断线结构化字段异常：%+v", sample)
	}
	raw, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, sensitive := range []string{"secret", "private", "/Users/me/project.txt"} {
		if strings.Contains(string(raw), sensitive) {
			t.Fatalf("诊断响应不能包含 WebSocket close text：%s", raw)
		}
	}
}

func TestRelayMonitorRecordsSanitizedDialFailureAndBoundsRecentSamples(t *testing.T) {
	monitor := newRelayMonitor()
	for index := 0; index < relayMonitorRecentLimit+5; index++ {
		monitor.recordGatewayDialFailure(
			time.Duration(index)*time.Millisecond,
			fmt.Errorf("dial token=secret prompt=private: %w", syscall.ECONNREFUSED),
		)
	}

	snapshot := monitor.snapshot().AppServerGateway
	if snapshot.FailedUpstreamDials != relayMonitorRecentLimit+5 {
		t.Fatalf("上游握手失败总数应完整累计：%+v", snapshot)
	}
	if snapshot.UpstreamDialFailureKinds["connection_refused"] != relayMonitorRecentLimit+5 {
		t.Fatalf("上游握手失败类别应聚合：%+v", snapshot.UpstreamDialFailureKinds)
	}
	if len(snapshot.RecentUpstreamDialFailures) != relayMonitorRecentLimit {
		t.Fatalf("最近握手失败样本必须限界为 %d：got=%d", relayMonitorRecentLimit, len(snapshot.RecentUpstreamDialFailures))
	}
	raw, err := json.Marshal(snapshot.RecentUpstreamDialFailures)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "secret") || strings.Contains(string(raw), "private") {
		t.Fatalf("握手失败样本不能保存原始错误：%s", raw)
	}
}

func TestRelayGatewayErrorKindKeepsOnlyStableCategory(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "timeout", err: errors.New("i/o timeout token=secret"), want: "timeout"},
		{name: "reset", err: syscall.ECONNRESET, want: "connection_reset"},
		{name: "eof", err: io.EOF, want: "eof"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			kind, _ := relayGatewayErrorKind(test.err)
			if kind != test.want {
				t.Fatalf("错误分类异常：got=%q want=%q", kind, test.want)
			}
		})
	}
}
