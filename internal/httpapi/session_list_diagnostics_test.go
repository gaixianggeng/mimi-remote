package httpapi

import (
	"bytes"
	"log"
	"strings"
	"testing"
	"time"
)

func TestSessionListDiagnosticsRedactsPayloadAndCorrelatesResponse(t *testing.T) {
	var output bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&output)
	defer log.SetOutput(previous)
	monitor := newRelayMonitor()
	monitor.active["gateway-test"] = &relayGatewayConnectionStats{pendingRPC: map[string]relayPendingRPC{}}
	connection := &relayGatewayConnMonitor{parent: monitor, id: "gateway-test"}
	request := []byte(`{"id":"private-id","method":"thread/list","params":{"cwd":"/private/path"}}`)
	response := []byte(`{"id":"private-id","result":{"data":[{"title":"private-title"}]}}`)
	connection.logSessionListStage(request, "request_policy", time.Millisecond)
	connection.beginRPCRequest(request, len(request))
	connection.logSessionListStage(response, "upstream_received", 0)
	connection.logSessionListStage(response, "response_policy", 2*time.Millisecond)
	connection.logSessionListStage([]byte(`{"id":2,"method":"thread/read"}`), "request_policy", 0)
	connection.logSessionListStage([]byte(`{"id":"unknown","result":{}}`), "upstream_received", 0)
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("只记录关联的列表请求和响应，got %d lines", len(lines))
	}
	for _, secret := range []string{"private-id", "/private/path", "private-title"} {
		if strings.Contains(output.String(), secret) {
			t.Fatal("诊断日志泄露请求 ID 或用户内容")
		}
	}
	var correlation string
	for _, line := range lines {
		for _, field := range strings.Fields(line) {
			if strings.HasPrefix(field, "rpc=") {
				if correlation != "" && correlation != field {
					t.Fatal("同一请求与响应的摘要必须相同")
				}
				correlation = field
			}
		}
	}
	if correlation == "" {
		t.Fatal("缺少关联摘要")
	}
}
