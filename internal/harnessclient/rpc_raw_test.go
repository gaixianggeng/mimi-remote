package harnessclient

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// 本文件覆盖 CallRaw：中继用的"不解码业务结果"的原始 RPC 通道。
//
// 与 Call 的区别只有一处——要不要把 result.value 解码成 Go 类型。外壳校验
// （方法名、result 存在性、result.ok、HTTP 状态、401 失效）必须完全一致，
// 否则 CallRaw 就成了绕过校验的捷径。

// TestCallRawRPCIsLosslessForUnmodeledFields 证明 CallRaw 不会丢掉未建模字段。
//
// 这正是它存在的理由：中继要把原生结果原样下发给移动端，而 agentd 侧的模型不可能
// 覆盖 Harness 每个版本的全部字段。先解码再编码会把没建模的字段静默吃掉。
func TestCallRawRPCIsLosslessForUnmodeledFields(t *testing.T) {
	fake := newFakeHarness(t)
	fake.handle(MethodSessionPage, func(json.RawMessage) (any, *RemoteError) {
		return map[string]any{
			"records": []any{
				map[string]any{
					"type": "event",
					"event": map[string]any{
						"type": "turn/start",
						"seq":  1,
						// 下面这些键当前没有对应 Go 字段
						"futureField": "kept",
						"nested":      map[string]any{"a": 1},
					},
				},
			},
			"hasMore": false,
		}, nil
	})
	server := fake.serve()
	client := newAuthenticatedClient(t, server.URL)

	raw, err := client.CallRaw(context.Background(), MethodSessionPage, map[string]any{
		"request": map[string]any{
			"address":    map[string]any{"kind": "session", "sessionId": "s1"},
			"throughSeq": 16,
		},
	})
	if err != nil {
		t.Fatalf("CallRaw 失败：%v", err)
	}
	for _, needle := range []string{`"futureField"`, `"kept"`, `"hasMore"`} {
		if !strings.Contains(string(raw), needle) {
			t.Fatalf("原始结果必须保留 %s：%s", needle, raw)
		}
	}
}

// TestCallRawRPCRequiresAuth 证明未认证时不会发出请求。
func TestCallRawRPCRequiresAuth(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client, err := New(Config{BaseURL: server.URL, AccessToken: fake.token})
	if err != nil {
		t.Fatal(err)
	}

	if _, err := client.CallRaw(context.Background(), MethodSessionList, map[string]any{}); err != ErrNotAuthenticated {
		t.Fatalf("未认证必须返回 ErrNotAuthenticated，得到 %v", err)
	}
	if calls := fake.recorded(); len(calls) != 0 {
		t.Fatalf("未认证时不得发出 RPC，实际 %d 次", len(calls))
	}
}

// TestCallRawRPCRejectsEnvelopeErrors 证明 ok=false 必须当成失败，且 details 不丢。
//
// 这里用手写的 wire 外壳而不是序列化 Go 结构：真实 Harness 的错误对象是
// {code, message, details}。若按 "data" 解码，details 会被静默丢掉，
// 而序列化再反序列化的往返测试恰好发现不了这个错误。
func TestCallRawRPCRejectsEnvelopeErrors(t *testing.T) {
	server := serveRawRPCResponse(t, `{
		"type": "server-response",
		"rpcId": "rpc-fixture-0001",
		"result": {
			"ok": false,
			"error": {
				"code": "session/agent-busy",
				"message": "prompt rejected",
				"details": {"reason": "busy"}
			}
		}
	}`)
	client := newAuthenticatedClient(t, server.URL)

	_, err := client.CallRaw(context.Background(), MethodSessionList, map[string]any{})
	if err == nil {
		t.Fatal("ok=false 必须返回错误")
	}
	var remoteErr *RemoteError
	if !asRemoteError(err, &remoteErr) {
		t.Fatalf("必须是 *RemoteError，得到 %T：%v", err, err)
	}
	if remoteErr.Code != "session/agent-busy" || remoteErr.Message != "prompt rejected" {
		t.Fatalf("错误码与文案必须原样保留：%+v", remoteErr)
	}
	if !strings.Contains(string(remoteErr.Details), "busy") {
		t.Fatalf("details 必须被解析（wire 名是 details 不是 data）：%+v", remoteErr)
	}
}

// TestCallRawRPCRejectsMissingResultEnvelope 证明缺 result 外壳不是空成功。
//
// 裸 {args:...} 会被网关判为 gateway/bad-request，且 HTTP 仍是 200。
func TestCallRawRPCRejectsMissingResultEnvelope(t *testing.T) {
	server := serveRawRPCResponse(t, `{"type":"server-response","rpcId":"rpc-fixture-0002"}`)
	client := newAuthenticatedClient(t, server.URL)

	if _, err := client.CallRaw(context.Background(), MethodSessionList, map[string]any{}); err == nil {
		t.Fatal("缺 result 外壳必须失败")
	} else if !strings.Contains(err.Error(), "result") {
		t.Fatalf("错误信息应说明缺少 result 外壳：%v", err)
	}
}

// TestCallRawRPCRejectsInvalidMethod 证明方法名校验在 CallRaw 上同样生效。
func TestCallRawRPCRejectsInvalidMethod(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := newAuthenticatedClient(t, server.URL)

	for _, method := range []string{"", "session/../../etc", "session/list extra", "session/list%2f.."} {
		if _, err := client.CallRaw(context.Background(), method, map[string]any{}); err == nil {
			t.Fatalf("非法方法名 %q 必须被拒", method)
		}
	}
	if calls := fake.recorded(); len(calls) != 0 {
		t.Fatalf("非法方法名不得发出请求，实际 %d 次", len(calls))
	}
}

// --- 支撑 ---

func newAuthenticatedClient(t *testing.T, baseURL string) *Client {
	t.Helper()
	client, err := New(Config{BaseURL: baseURL, AccessToken: "startup-token-fixture"})
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Authenticate(context.Background()); err != nil {
		t.Fatalf("认证失败：%v", err)
	}
	return client
}

// serveRawRPCResponse 提供一个固定回包，用来精确控制 wire 形状。
func serveRawRPCResponse(t *testing.T, body string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "cookie-fixture", Path: "/"})
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func asRemoteError(err error, target **RemoteError) bool {
	remoteErr, ok := err.(*RemoteError)
	if ok {
		*target = remoteErr
	}
	return ok
}
