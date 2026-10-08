//go:build darwin

package appserver

import (
	"context"
	"net"
	"path/filepath"
	"strings"
	"testing"
)

func TestFrontDoorConnectionSources(t *testing.T) {
	listener := "p10|cagentd|f3|tunix|d0x10|n/public.sock|\n"
	for _, tc := range []struct {
		name, output string
		want         CodexRuntimeConnections
		invalid      bool
	}{
		{"idle listener", listener, CodexRuntimeConnections{}, false},
		{"mixed clients", listener + "p11|cagentd|f4|tunix|d0x11|n->0x10|\np12|ccodex|f5|tunix|d0x12|n->0x10|\np13|cother|f6|tunix|d0x13|n->0x10|", CodexRuntimeConnections{1, 1, 1}, false},
		{"inherited socket", listener + "p12|ccodex|f5|tunix|d0x12|n->0x10|f6|tunix|d0x12|n->0x10|\np14|ccodex|f5|tunix|d0x12|n->0x10|", CodexRuntimeConnections{Codex: 1}, false},
		{"unrelated socket", listener + "p12|ccodex|f5|tunix|d0x12|n->0xff|", CodexRuntimeConnections{}, false},
		{"missing listener", "p12|ccodex|f5|tunix|d0x12|n->0x10|", CodexRuntimeConnections{}, true},
		{"missing socket address", listener + "p12|ccodex|f5|tunix|n->0x10|", CodexRuntimeConnections{}, true},
		{"missing process", "f5|tunix|d0x12|n->0x10|", CodexRuntimeConnections{}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := frontDoorConnections([]byte(strings.ReplaceAll(tc.output, "|", "\x00")), "/public.sock")
			if (err != nil) != tc.invalid || got != tc.want {
				t.Fatalf("got=%+v err=%v want=%+v invalid=%v", got, err, tc.want, tc.invalid)
			}
		})
	}
}

func TestFrontDoorConnectionSnapshotUsesRealUnixPeers(t *testing.T) {
	socket := filepath.Join(shortSharedLocalCodexHome(t), "front.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	door := &FrontDoor{public: socket}
	client, err := net.Dial("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	counts := door.RuntimeConnections(context.Background())
	if counts == nil || *counts != (CodexRuntimeConnections{Other: 1}) {
		t.Fatalf("应识别测试进程的一条连接，got=%+v", counts)
	}
	_ = client.Close()
	_ = server.Close()
	counts = door.RuntimeConnections(context.Background())
	if counts == nil || *counts != (CodexRuntimeConnections{}) {
		t.Fatalf("关闭后不应残留占用，got=%+v", counts)
	}
}
