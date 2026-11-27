package httpapi

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestCodexGatewayBrokerConcurrentAdmissionDuringEviction(t *testing.T) {
	for _, secondKey := range []string{"other", "first"} {
		t.Run(secondKey, func(t *testing.T) {
			r := &Router{codexBrokers: map[string]*codexGatewayBroker{}}
			defer r.shutdownApprovalObservers()
			var upstreams []*brokerUpstream
			dial := func() *websocket.Conn {
				up := newBrokerUpstream(t)
				upstreams = append(upstreams, up)
				conn, _, err := websocket.DefaultDialer.Dial(up.url, nil)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = conn.Close() })
				return conn
			}
			register := func(key string, conn *websocket.Conn, policy *appServerGatewayPolicy, sink *codexGatewaySink) *codexGatewayBroker {
				return r.registerCodexGatewayBroker(context.Background(), key, conn, policy, sink)
			}
			entered, proceed := make(chan struct{}), make(chan struct{})
			release := sync.OnceFunc(func() { close(proceed) })
			defer release()
			victim := &codexGatewayBroker{
				router: r, key: "offline", upstream: dial(), policy: newAppServerGatewayPolicy(r, "codex"),
				detachedAt: time.Now(),
				cancel: func() {
					close(entered)
					<-proceed
				},
			}
			r.codexBrokers[victim.key] = victim
			for i := 1; i < codexGatewayBrokerMax; i++ {
				key := fmt.Sprintf("online-%d", i)
				register(key, dial(), newAppServerGatewayPolicy(r, "codex"), newCodexGatewaySink(nil, nil, nil))
			}

			firstDial, secondDial := dial(), dial()
			firstSink, secondSink := newCodexGatewaySink(nil, nil, nil), newCodexGatewaySink(nil, nil, nil)
			firstResult := make(chan *codexGatewayBroker, 1)
			go func() {
				firstResult <- register("first", firstDial, newAppServerGatewayPolicy(r, "codex"), firstSink)
			}()
			select {
			case <-entered:
			case <-time.After(3 * time.Second):
				t.Fatal("eviction did not reach cleanup")
			}
			secondPolicy := newAppServerGatewayPolicy(r, "codex")
			secondResult := make(chan *codexGatewayBroker, 1)
			go func() { secondResult <- register(secondKey, secondDial, secondPolicy, secondSink) }()
			var second *codexGatewayBroker
			select {
			case second = <-secondResult:
			case <-time.After(3 * time.Second):
				t.Fatal("unrelated transport cleanup blocked broker admission")
			}
			release()
			first := <-firstResult
			if first == nil {
				t.Fatal("first connection lost its slot")
			}
			defer first.close("test_done")
			if second != nil {
				defer second.close("test_done")
			}
			r.codexBrokerMu.Lock()
			count, winner := len(r.codexBrokers), r.codexBrokers["first"]
			r.codexBrokerMu.Unlock()
			if count != codexGatewayBrokerMax || winner != first {
				t.Fatalf("registered %d brokers, winner %p, first %p", count, winner, first)
			}
			if secondKey == "first" {
				if second != first || !first.acceptsClientFrame(secondSink) || !secondPolicy.isClosed() {
					t.Fatal("reconnect must take over the first broker and release its unused dial and policy")
				}
			} else {
				if second != nil || secondPolicy.isClosed() {
					t.Fatal("full registry must leave the new connection available for one-to-one forwarding")
				}
				if err := secondDial.WriteMessage(websocket.TextMessage, []byte("fallback")); err != nil {
					t.Fatal(err)
				}
				select {
				case <-upstreams[len(upstreams)-1].frames:
				case <-time.After(3 * time.Second):
					t.Fatal("fallback upstream did not receive the frame")
				}
				_ = secondDial.Close()
				secondPolicy.close()
			}
			r.shutdownApprovalObservers()
			for _, up := range upstreams {
				select {
				case <-up.closed:
				case <-time.After(3 * time.Second):
					t.Fatal("upstream still open after shutdown")
				}
			}
		})
	}
}

func TestCodexGatewayBrokerEvictionPreservesPendingTakeover(t *testing.T) {
	transitioning := &codexGatewayBroker{attachSeq: 1, detachedAt: time.Unix(1, 0)}
	idle := &codexGatewayBroker{detachedAt: time.Unix(2, 0)}
	if got := oldestDetachedCodexBroker(map[string]*codexGatewayBroker{"older": transitioning, "idle": idle}); got != idle {
		t.Fatalf("a reconnect waiting to install its sink must retain its slot, got %p want %p", got, idle)
	}
}
