package tunnel

import (
	"errors"
	"strings"
	"testing"
	"time"

	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

func TestClassifyHostLogKeepsOnlyWhitelistedFields(t *testing.T) {
	public := key.NewNode().Public()
	secretAddress := "203.0.113.9:41641"
	cases := []struct {
		name   string
		format string
		args   []any
		want   HostEvent
	}{
		{"meow", "got meow from %v", []any{public.String()}, HostEvent{Name: HostEventPeerContact, Peer: public.ShortString()}},
		{"rejected", "ignoring meow from %v: not in allowedClients", []any{public.String()}, HostEvent{Name: HostEventPeerRejected, Peer: public.ShortString()}},
		{"direct", "magicsock: disco: node %v %v now using %v mtu=%v tx=%x", []any{public.ShortString(), "d:abc", secretAddress, 1280, []byte{1}}, HostEvent{Name: HostEventPathDirect, Peer: public.ShortString()}},
		{"derp up", "magicsock: derp-%d connected; connGen=%v", []any{tailcfg.DERPRegionID(901), 3}, HostEvent{Name: HostEventDERPConnected, Region: 901}},
		{"derp lost", "magicsock: [%p] derp.Recv(derp-%d): %v", []any{&struct{}{}, 901, errors.New("read tcp " + secretAddress + ": i/o timeout")}, HostEvent{Name: HostEventDERPLost, Region: 901, Reason: "timeout"}},
		{"derp closed", "magicsock: closing connection to derp-%v (%v), age %v", []any{901, "idle", time.Minute}, HostEvent{Name: HostEventDERPClosed, Region: 901, Reason: "idle"}},
		{"unknown close", "magicsock: closing connection to derp-%v (%v), age %v", []any{901, "via " + secretAddress, time.Minute}, HostEvent{Name: HostEventDERPClosed, Region: 901, Reason: "other"}},
		{"link", "LinkChange: major, rebinding: %v", []any{"interfaces " + secretAddress}, HostEvent{Name: HostEventNetworkChange}},
		{"down", "LinkChange: all links down; pausing: %v", []any{secretAddress}, HostEvent{Name: HostEventNetworkDown}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			got, ok := classifyHostLog(testCase.format, testCase.args)
			if !ok || got != testCase.want {
				t.Fatalf("classify = %+v, %v; want %+v", got, ok, testCase.want)
			}
			if strings.Contains(got.Peer+got.Reason, "203.0.113.9") || strings.Contains(got.Peer, public.String()) {
				t.Fatalf("事件带出了地址或完整公钥：%+v", got)
			}
		})
	}
	if event, ok := classifyHostLog("NetworkMap: %v", []any{secretAddress}); ok {
		t.Fatalf("未知日志不应产生事件：%+v", event)
	}
}

func TestNetworkErrorReasonIsFixedCategory(t *testing.T) {
	cases := map[string]string{
		"read tcp 203.0.113.9:1: i/o timeout":             "timeout",
		"read: connection reset by peer":                  "reset",
		"read: no route to host":                          "no_route",
		"unexpected EOF":                                  "eof",
		"use of closed network connection":                "closed",
		"tls: bad certificate from 203.0.113.9 (private)": "other",
	}
	for message, want := range cases {
		if got := networkErrorReason([]any{errors.New(message)}, 0); got != want {
			t.Errorf("%q => %q, want %q", message, got, want)
		}
	}
	if got := networkErrorReason([]any{"not an error"}, 0); got != "unknown" {
		t.Errorf("非 error 参数 => %q", got)
	}
}

func TestHostEventFilterMergesRapidDuplicates(t *testing.T) {
	now := time.Unix(1000, 0)
	var events []HostEvent
	filter := newHostEventFilter(func(event HostEvent) { events = append(events, event) }, func() time.Time { return now })
	public := key.NewNode().Public().String()

	filter.logf("got meow from %v", public)
	now = now.Add(hostEventDedupeWindow - time.Millisecond)
	filter.logf("got meow from %v", public)
	if len(events) != 1 {
		t.Fatalf("窗口内重复应合并：%d", len(events))
	}
	now = now.Add(2 * time.Millisecond)
	filter.logf("got meow from %v", public)
	if len(events) != 2 {
		t.Fatalf("窗口外应再记一条：%d", len(events))
	}
	filter.logf("magicsock: derp-%d connected; connGen=%v", 1, 1)
	if len(events) != 3 {
		t.Fatalf("不同事件互不合并：%d", len(events))
	}
}
