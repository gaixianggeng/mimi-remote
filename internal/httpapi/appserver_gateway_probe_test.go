package httpapi

import (
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestAnonymousCodexProbesPreserveFullResidentBrokerPool(t *testing.T) {
	up := newBrokerUpstream(t)
	server, router := brokerTestServer(t, up.url, true)
	clients := make([]*websocket.Conn, codexGatewayBrokerMax)
	upstreams := make([]*websocket.Conn, codexGatewayBrokerMax)
	brokers := make([]*codexGatewayBroker, codexGatewayBrokerMax)
	for i := range clients {
		key := fmt.Sprintf("resident-%d-codex", i)
		clients[i] = brokerDial(t, server, key)
		upstreams[i] = up.accept(t)
		up.emit(t, upstreams[i], brokerTurnStartedFrame)
		readFrameWithMethod(t, clients[i], "turn/started", 3*time.Second)
		brokers[i] = waitForBroker(t, router, key, true)
	}

	// 满池中保留一个离线、仍在运行且等待审批的会话；具名探针会淘汰它。
	_ = clients[0].Close()
	deadline := time.Now().Add(3 * time.Second)
	for {
		brokers[0].mu.Lock()
		detached := brokers[0].sink == nil
		brokers[0].mu.Unlock()
		if detached {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("正式客户端没有离线")
		}
		time.Sleep(10 * time.Millisecond)
	}
	up.emit(t, upstreams[0], brokerApprovalFrame)
	waitForPendingCount(t, brokers[0], 1, "离线审批必须先进入正式 broker")

	// 两条探针同时存在，也只能占用自己的临时上游连接。
	probes := make([]*websocket.Conn, 2)
	for i := range probes {
		probes[i] = brokerDial(t, server, "")
		probeUpstream := up.accept(t)
		up.emit(t, probeUpstream, brokerTurnStartedFrame)
		readFrameWithMethod(t, probes[i], "turn/started", 3*time.Second)
	}
	router.codexBrokerMu.Lock()
	count := len(router.codexBrokers)
	unchanged := true
	for _, broker := range brokers {
		unchanged = unchanged && router.codexBrokers[broker.key] == broker
	}
	router.codexBrokerMu.Unlock()
	if count != codexGatewayBrokerMax || !unchanged {
		t.Fatalf("探针改变了正式 broker 池：count=%d unchanged=%v", count, unchanged)
	}
	up.emit(t, upstreams[1], brokerTurnDoneFrame)
	readFrameWithMethod(t, clients[1], "turn/completed", 3*time.Second)
	for _, probe := range probes {
		_ = probe.Close()
	}
	for range probes {
		select {
		case <-up.closed:
		case <-time.After(3 * time.Second):
			t.Fatal("探针断开后没有释放临时上游连接")
		}
	}

	resumed := brokerDial(t, server, brokers[0].key)
	readFrameWithMethod(t, resumed, "execCommandApproval", 3*time.Second)
	if got := up.connections.Load(); got != int64(codexGatewayBrokerMax+len(probes)) {
		t.Fatalf("正式会话重连不应新建上游：connections=%d", got)
	}
	for _, broker := range brokers {
		broker.mu.Lock()
		closed := broker.closed
		broker.mu.Unlock()
		if closed {
			t.Fatalf("探针回收影响了正式 broker %s", broker.key)
		}
	}
}
