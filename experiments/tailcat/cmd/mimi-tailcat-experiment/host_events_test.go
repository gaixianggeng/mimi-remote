package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
)

// agentd 按这个前缀和字段名解析（internal/tailcatevents），两边是分开的 Go 模块，这里钉住线上格式。
func TestHostEventWriterEmitsOneWhitelistedJSONLine(t *testing.T) {
	var output bytes.Buffer
	write := newHostEventWriter(&output)
	write(tunnel.HostEvent{Name: tunnel.HostEventDERPLost, Peer: "[SbEMg]", Region: 901, Reason: "timeout", DurationMillis: 12})

	line := output.String()
	if !strings.HasSuffix(line, "\n") || strings.Count(line, "\n") != 1 {
		t.Fatalf("必须是一整行：%q", line)
	}
	payload, ok := strings.CutPrefix(strings.TrimSuffix(line, "\n"), "mimi-tailcat-event ")
	if !ok {
		t.Fatalf("缺少事件前缀：%q", line)
	}
	var decoded map[string]any
	if err := json.Unmarshal([]byte(payload), &decoded); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"event": "derp_lost", "peer": "[SbEMg]", "region": float64(901), "reason": "timeout", "ms": float64(12)}
	for key, value := range want {
		if decoded[key] != value {
			t.Fatalf("字段 %s = %v，want %v", key, decoded[key], value)
		}
	}
}
