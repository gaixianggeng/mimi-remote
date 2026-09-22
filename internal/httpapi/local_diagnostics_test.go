package httpapi

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/diagnosticlog"
)

type testDiagnosticLogs struct {
	enabled bool
	clears  int
}

func (d *testDiagnosticLogs) Status() (DiagnosticLogStatus, error) {
	return DiagnosticLogStatus{Enabled: d.enabled, MaxTotalBytes: 10 << 20, RetentionDays: 7}, nil
}
func (d *testDiagnosticLogs) SetEnabled(on bool) (DiagnosticLogStatus, error) {
	d.enabled = on
	return d.Status()
}
func (d *testDiagnosticLogs) Clear() (DiagnosticLogStatus, error) { d.clears++; return d.Status() }
func (d *testDiagnosticLogs) Export() ([]string, error)           { return []string{"safe-line"}, nil }

const localDiagnosticTestToken = "local-diagnostic-test-secret"

func TestLocalDiagnosticsAccessBoundary(t *testing.T) {
	for _, tc := range []struct {
		name, remote, host, auth, query, origin, method string
		status                                          int
	}{
		{"local", "127.0.0.1:1234", "localhost:8787", localDiagnosticTestToken, "", "", http.MethodPost, 200},
		{"paired-client-through-tunnel", "127.0.0.1:1234", "localhost:8787", testToken, "", "", http.MethodPost, 401},
		{"missing-token", "127.0.0.1:1234", "localhost:8787", "", "", "", http.MethodPost, 401},
		{"query-token", "127.0.0.1:1234", "localhost:8787", "", "?token=" + localDiagnosticTestToken, "", http.MethodPost, 401},
		{"remote", "192.0.2.1:1234", "localhost:8787", localDiagnosticTestToken, "", "", http.MethodPost, 403},
		{"rebound-host", "127.0.0.1:1234", "example.invalid:8787", localDiagnosticTestToken, "", "", http.MethodPost, 403},
		{"browser", "127.0.0.1:1234", "localhost:8787", localDiagnosticTestToken, "", "http://localhost:8787", http.MethodPost, 403},
		{"wrong-method", "127.0.0.1:1234", "localhost:8787", localDiagnosticTestToken, "", "", http.MethodGet, 405},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logs := &testDiagnosticLogs{}
			r := &Router{diagnosticLogs: logs}
			mux := http.NewServeMux()
			r.registerLocalDiagnostics(mux, localDiagnosticTestToken)
			req := httptest.NewRequest(tc.method, "http://localhost/api/local/diagnostics/start"+tc.query, nil)
			req.RemoteAddr = tc.remote
			req.Host = tc.host
			if tc.auth != "" {
				req.Header.Set("Authorization", "Bearer "+tc.auth)
			}
			if tc.origin != "" {
				req.Header.Set("Origin", tc.origin)
			}
			response := httptest.NewRecorder()
			mux.ServeHTTP(response, req)
			if response.Code != tc.status {
				t.Fatalf("got %d want %d", response.Code, tc.status)
			}
			if logs.enabled != (tc.status == 200) {
				t.Fatal("未授权请求改变了开关")
			}
		})
	}
}

func TestLocalDiagnosticsOperations(t *testing.T) {
	logs := &testDiagnosticLogs{}
	r := &Router{diagnosticLogs: logs}
	mux := http.NewServeMux()
	r.registerLocalDiagnostics(mux, localDiagnosticTestToken)
	for _, action := range []string{"status", "start", "stop", "clear", "export"} {
		method := http.MethodPost
		if action == "status" || action == "export" {
			method = http.MethodGet
		}
		req := httptest.NewRequest(method, "http://localhost/api/local/diagnostics/"+action, nil)
		req.RemoteAddr = "127.0.0.1:1234"
		req.Header.Set("Authorization", "Bearer "+localDiagnosticTestToken)
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, req)
		if response.Code != 200 || response.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("%s: %s", action, response.Body.String())
		}
	}
	if logs.enabled || logs.clears != 1 {
		t.Fatal("操作未生效")
	}
	r.diagnosticLogs = nil
	req := httptest.NewRequest(http.MethodGet, "http://localhost/api/local/diagnostics/status", nil)
	req.RemoteAddr = "127.0.0.1:1234"
	req.Header.Set("Authorization", "Bearer "+localDiagnosticTestToken)
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, req)
	if response.Code != 503 {
		t.Fatal("未启用文件日志的服务必须明确报告不可用")
	}
}

func TestGatewayDiagnosticsFollowRequestsWithoutPayload(t *testing.T) {
	var output bytes.Buffer
	recorder, _ := diagnosticlog.New(&output)
	defer recorder.Close()
	restore := diagnosticlog.Install(recorder)
	defer restore()
	recorder.Start()
	monitor := newRelayMonitor()
	conn := monitor.startGatewayConnection("private-ip", "private-host", "private-upstream", time.Millisecond)
	request := []byte(`{"id":"private-request-id","method":"turn/start","params":{"input":"private-message"}}`)
	conn.beginRPCRequest(request, len(request))
	response := []byte(`{"id":"private-request-id","error":{"message":"private-error"}}`)
	conn.recordForward("upstream_to_client", len(response), len(response), 0, 0, response)
	delta := []byte(`{"method":"item/agentMessage/delta","params":{"delta":"private-reply"}}`)
	if err := recorder.Sync(nil); err != nil {
		t.Fatal(err)
	}
	before := output.Len()
	conn.recordForward("upstream_to_client", len(delta), len(delta), 0, 0, delta)
	if err := recorder.Sync(nil); err != nil {
		t.Fatal(err)
	}
	if output.Len() != before {
		t.Fatal("不能逐 token 记录")
	}
	for _, method := range []string{"turn/started", "turn/completed", "item/commandExecution/requestApproval"} {
		recordGatewayLifecycle(conn.id, method, []byte(`{"params":{"threadId":"private-thread","turnId":"private-turn"}}`))
	}
	if err := recorder.Sync(nil); err != nil {
		t.Fatal(err)
	}
	text := output.String()
	if strings.Contains(text, "private") {
		t.Fatal("日志泄露原始请求字段")
	}
	for _, part := range []string{`"stage":"rpc_request"`, `"stage":"rpc_response","outcome":"failed"`, `"stage":"approval"`, `"stage":"turn_completed"`} {
		if !strings.Contains(text, part) {
			t.Fatalf("缺少事件 %s", part)
		}
	}
	if !strings.Contains(text, diagnosticlog.Reference(conn.id+`:"private-request-id"`)) {
		t.Fatal("请求与响应缺少共同关联标记")
	}
}
