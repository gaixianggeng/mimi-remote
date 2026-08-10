package httpapi

import (
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestAppServerGatewayFrameWriteWindowScalesWithPayload(t *testing.T) {
	tests := []struct {
		name         string
		payloadBytes int
		want         time.Duration
	}{
		{name: "empty", payloadBytes: 0, want: 10 * time.Second},
		{name: "small frame boundary", payloadBytes: 256 << 10, want: 10 * time.Second},
		{name: "first large frame byte", payloadBytes: (256 << 10) + 1, want: 11 * time.Second},
		{name: "four MiB history page", payloadBytes: 4 << 20, want: 50 * time.Second},
		{name: "five MiB history page", payloadBytes: 5 << 20, want: 61 * time.Second},
		{name: "hard upper bound", payloadBytes: 64 << 20, want: 75 * time.Second},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := appServerGatewayFrameWriteWindow(test.payloadBytes); got != test.want {
				t.Fatalf("write window = %s, want %s", got, test.want)
			}
		})
	}
}

func TestAppServerGatewayPongWindowCoversDelayedPingDuringLargeFrameWrite(t *testing.T) {
	minimum := appServerGatewayPingPeriod +
		appServerGatewayLargeFrameMaxWriteWindow + appServerGatewayWriteWindow
	if margin := appServerGatewayPongWait - minimum; margin < appServerGatewayPongGrace {
		t.Fatalf("pong wait margin = %s, want at least %s", margin, appServerGatewayPongGrace)
	}
}

func TestAppServerGatewayControlWriteDeadlineStartsAfterLockWait(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	conn, _, err := websocket.DefaultDialer.Dial(upstreamURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	var writeMu sync.Mutex
	writeMu.Lock()
	started := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		close(started)
		result <- writeWebSocketControl(conn, &writeMu, websocket.PingMessage, nil, 10*time.Millisecond)
	}()
	<-started
	// 模拟 ping 在一个慢速大帧之后排队，等待时间故意超过自身 write window。
	time.Sleep(30 * time.Millisecond)
	writeMu.Unlock()

	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("control write failed after lock wait: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("control write remained blocked after lock release")
	}
}
