package harnessclient

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/gorilla/websocket"
)

// recordedCall 记录一次到达 fake 服务的 RPC，用于断言报文外壳与凭据摆放位置。
type recordedCall struct {
	Path       string
	RequestURI string
	Cookie     string
	Envelope   map[string]any
}

type fakeHarness struct {
	t *testing.T

	token  string
	cookie string

	mu       sync.Mutex
	calls    []recordedCall
	opens    []map[string]any
	handlers map[string]func(args json.RawMessage) (any, *RemoteError)

	// muxOpen 在客户端声明订阅后被调用，用于按 endpoint 回放帧。
	muxOpen func(conn *websocket.Conn, open map[string]any) error
}

func newFakeHarness(t *testing.T) *fakeHarness {
	t.Helper()
	return &fakeHarness{
		t:        t,
		token:    "startup-token-fixture",
		cookie:   "harness_session=cookie-fixture",
		handlers: map[string]func(json.RawMessage) (any, *RemoteError){},
	}
}

func (f *fakeHarness) handle(method string, handler func(args json.RawMessage) (any, *RemoteError)) {
	f.handlers[method] = handler
}

func (f *fakeHarness) onMuxOpen(handler func(conn *websocket.Conn, open map[string]any) error) {
	f.muxOpen = handler
}

func (f *fakeHarness) recorded() []recordedCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recordedCall(nil), f.calls...)
}

// openedStreams 返回客户端声明过的订阅，用于断言 open 帧结构。
func (f *fakeHarness) openedStreams() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.opens...)
}

func (f *fakeHarness) serve() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		if r.URL.Query().Get("token") != f.token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		// 认证是一次 303 握手，普通 API 不接受 Authorization 头，只认这个 Cookie。
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "cookie-fixture", Path: "/"})
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc("/api/remote.mux", f.serveMuxStream)
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		if _, err := r.Cookie("harness_session"); err != nil {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		method := strings.TrimPrefix(r.URL.Path, "/api/")
		var envelope map[string]any
		if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.mu.Lock()
		f.calls = append(f.calls, recordedCall{
			Path:       r.URL.Path,
			RequestURI: r.RequestURI,
			Cookie:     r.Header.Get("Cookie"),
			Envelope:   envelope,
		})
		f.mu.Unlock()

		payload, _ := envelope["payload"].(map[string]any)
		rawArgs, _ := json.Marshal(payload["args"])
		handler := f.handlers[method]
		if handler == nil {
			writeEnvelope(w, f.t, envelope, nil, &RemoteError{Code: "unknown/method", Message: method})
			return
		}
		value, remoteErr := handler(rawArgs)
		writeEnvelope(w, f.t, envelope, value, remoteErr)
	})
	server := httptest.NewServer(mux)
	f.t.Cleanup(server.Close)
	return server
}

// serveMuxStream 处理事件流订阅：校验 Cookie、读取 open 帧、交给测试回放帧。
func (f *fakeHarness) serveMuxStream(w http.ResponseWriter, r *http.Request) {
	if _, err := r.Cookie("harness_session"); err != nil {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	conn, err := (&websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}).Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer func() { _ = conn.Close() }()

	_, raw, err := conn.ReadMessage()
	if err != nil {
		return
	}
	var open map[string]any
	if err := json.Unmarshal(raw, &open); err != nil {
		return
	}
	f.mu.Lock()
	f.opens = append(f.opens, open)
	f.mu.Unlock()

	if f.muxOpen == nil {
		return
	}
	if err := f.muxOpen(conn, open); err != nil && !errors.Is(err, net.ErrClosed) {
		f.t.Logf("事件流回放结束：%v", err)
	}
}

// sendFrame 按 Harness 的 remote.mux 形状写出一帧：streamId 在外，value 在内。
func sendFrame(conn *websocket.Conn, streamID string, value map[string]any) error {
	payload, err := json.Marshal(map[string]any{"streamId": streamID, "value": value})
	if err != nil {
		return err
	}
	return conn.WriteMessage(websocket.TextMessage, payload)
}

// writeEnvelope 复刻 Harness 的 Connection RPC 响应外壳：业务结果一律在 result 里。
func writeEnvelope(w http.ResponseWriter, t *testing.T, request map[string]any, value any, remoteErr *RemoteError) {
	t.Helper()
	result := map[string]any{"ok": remoteErr == nil}
	if remoteErr == nil {
		if value != nil {
			result["value"] = value
		}
	} else {
		result["error"] = remoteErr
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]any{
		"type":   "server-response",
		"rpcId":  request["rpcId"],
		"result": result,
	}); err != nil {
		t.Errorf("写出响应失败：%v", err)
	}
}

// 认证必须走 token 换 Cookie，且 RPC 不携带 token。
func TestAuthenticateExchangesTokenForCookie(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client, err := New(Config{BaseURL: server.URL, AccessToken: fake.token})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	if client.Authenticated() {
		t.Fatal("构造后不应处于已认证状态")
	}
	// 未认证就调用必须被本地拦住，不发网络请求。
	if err := client.Call(context.Background(), MethodSessionModelCatalog, nil, nil); !errors.Is(err, ErrNotAuthenticated) {
		t.Fatalf("未认证调用应返回 ErrNotAuthenticated，得到 %v", err)
	}
	if err := client.Authenticate(context.Background()); err != nil {
		t.Fatalf("认证失败：%v", err)
	}
	if !client.Authenticated() {
		t.Fatal("认证后应处于已认证状态")
	}

	fake.handle(MethodSessionModelCatalog, func(json.RawMessage) (any, *RemoteError) {
		return ModelCatalogResult{Groups: []ModelCatalogGroup{{ID: "ark-coding-plan-cn", Models: []ModelEntry{{ID: "deepseek-v4-pro"}}}}}, nil
	})
	catalog, err := client.ModelCatalog(context.Background())
	if err != nil {
		t.Fatalf("取模型目录失败：%v", err)
	}
	if len(catalog.Groups) != 1 || catalog.Groups[0].Models[0].ID != "deepseek-v4-pro" {
		t.Fatalf("模型目录解析不符：%+v", catalog)
	}

	calls := fake.recorded()
	if len(calls) != 1 {
		t.Fatalf("应记录到一次 RPC，得到 %d", len(calls))
	}
	if !strings.Contains(calls[0].Cookie, "harness_session=cookie-fixture") {
		t.Fatalf("RPC 应携带换来的 Cookie：%q", calls[0].Cookie)
	}
	if strings.Contains(calls[0].Cookie, fake.token) {
		t.Fatal("启动 token 不得出现在 RPC 请求里")
	}
	if calls[0].Path != "/api/session/modelCatalog" {
		t.Fatalf("RPC 路径不符：%s", calls[0].Path)
	}
	// Harness 按字面路径路由，方法名里的 "/" 不能被转义成 %2F，否则会落到 404。
	if calls[0].RequestURI != "/api/session/modelCatalog" {
		t.Fatalf("RPC 实际请求行必须保持字面路径：%s", calls[0].RequestURI)
	}
}

// 含 $ 的 endpoint（$events/result）同样必须保持字面路径。
func TestCallKeepsLiteralPathForDollarEndpoint(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	fake.handle(EndpointEventsResult, func(json.RawMessage) (any, *RemoteError) { return map[string]any{}, nil })
	if err := client.ResolveApproval(context.Background(), "client-1", "event-1", OutcomeRejected); err != nil {
		t.Fatalf("回传审批结论失败：%v", err)
	}
	call := fake.recorded()[0]
	if call.RequestURI != "/api/$events/result" {
		t.Fatalf("回传路径必须是字面 $events/result：%s", call.RequestURI)
	}
	args, _ := call.Envelope["payload"].(map[string]any)
	inner, _ := args["args"].(map[string]any)
	if inner["clientId"] != "client-1" || inner["eventId"] != "event-1" {
		t.Fatalf("回传参数不符：%v", inner)
	}
	outcome, _ := inner["outcome"].(map[string]any)
	// 隔离实验里拒绝审批用的就是 {kind:'result', value:'rejected'}，不存在 rejection 这种 kind。
	if outcome["kind"] != "result" || outcome["value"] != OutcomeRejected {
		t.Fatalf("拒绝审批应回传 result/rejected：%v", outcome)
	}
}

// 方法名白名单：拒绝会被拼进路径的可疑字符与越界路径段。
func TestValidateMethodRejectsUnsafeNames(t *testing.T) {
	safe := []string{MethodSessionList, MethodSessionModelCatalog, EndpointEvents, EndpointEventsResult, "session/follow"}
	for _, method := range safe {
		if err := ValidateMethod(method); err != nil {
			t.Errorf("合法方法名被拒绝：%s：%v", method, err)
		}
	}
	unsafe := []string{
		"", " session/list", "session/list ", "session/list?x=1", "session/list#f",
		"../etc/passwd", "session/../../etc/passwd", "/session/list", "session/list/",
		"session//list", "session/./list", "session list", "session\u0000list", "session/list\\x",
	}
	for _, method := range unsafe {
		if err := ValidateMethod(method); err == nil {
			t.Errorf("非法方法名应被拒绝：%q", method)
		}
	}
}

// 首版只开放 queue 模式，steer 必须被本地拒绝而不是发出去。
func TestPromptRejectsUnverifiedMode(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)
	fake.handle(MethodSessionPrompt, func(json.RawMessage) (any, *RemoteError) { return nil, nil })

	err := client.Prompt(context.Background(), PromptRequest{
		SessionID: "s",
		RequestID: "req-1",
		Mode:      "steer",
		Content:   []PromptContent{{Type: "text", Text: "hi"}},
	})
	if err == nil {
		t.Fatal("steer 模式应被拒绝")
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("被拒绝的请求不应发出")
	}
	if err := client.Prompt(context.Background(), PromptRequest{SessionID: "s", Content: []PromptContent{{Type: "text", Text: "hi"}}}); err == nil {
		t.Fatal("缺少 requestId 应被拒绝")
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("缺少 requestId 的请求不应发出")
	}
}

// 错误 token 不能换到 Cookie。
func TestAuthenticateRejectsWrongToken(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client, err := New(Config{BaseURL: server.URL, AccessToken: "wrong-token"})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	if err := client.Authenticate(context.Background()); err == nil {
		t.Fatal("错误 token 不应认证成功")
	}
	if client.Authenticated() {
		t.Fatal("认证失败后不应处于已认证状态")
	}
}

// 缺少 token 必须在本地失败，不发出请求。
func TestAuthenticateRequiresToken(t *testing.T) {
	client, err := New(Config{BaseURL: "http://127.0.0.1:1"})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	if err := client.Authenticate(context.Background()); err == nil {
		t.Fatal("缺少 token 应返回错误")
	}
}

// 认证把 token 放在 query 上，而 net/http 会把完整 URL 包进传输错误；
// 连接失败时错误信息不得回带 token。
func TestAuthenticateNeverLeaksTokenInTransportError(t *testing.T) {
	const token = "startup-token-should-not-leak"

	// 借一个真实端口再关掉，保证是"连不上"而不是地址非法。
	probe := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	baseURL := probe.URL
	probe.Close()

	client, err := New(Config{BaseURL: baseURL, AccessToken: token})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	err = client.Authenticate(context.Background())
	if err == nil {
		t.Fatal("不可达服务应返回错误")
	}
	if strings.Contains(err.Error(), token) {
		t.Fatalf("认证错误不得包含 token：%v", err)
	}
}

// 报文外壳必须是 client-request + payload.args，否则 Harness 会判 gateway/bad-request。
func TestCallUsesConnectionEnvelope(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	fake.handle(MethodSessionCreate, func(args json.RawMessage) (any, *RemoteError) {
		var decoded struct {
			Request CreateSessionRequest `json:"request"`
		}
		if err := json.Unmarshal(args, &decoded); err != nil {
			t.Errorf("解析 args 失败：%v", err)
		}
		if decoded.Request.CWD != "/workspace/approved" {
			t.Errorf("cwd 未按 args.request 传递：%+v", decoded.Request)
		}
		return CreateSessionResult{SessionID: "session-fixture"}, nil
	})
	created, err := client.CreateSession(context.Background(), CreateSessionRequest{CWD: "/workspace/approved"})
	if err != nil {
		t.Fatalf("新建会话失败：%v", err)
	}
	if created.SessionID != "session-fixture" {
		t.Fatalf("sessionId 不符：%s", created.SessionID)
	}

	call := fake.recorded()[0]
	if call.Envelope["type"] != "client-request" {
		t.Fatalf("外壳 type 不符：%v", call.Envelope["type"])
	}
	if call.Envelope["method"] != MethodSessionCreate {
		t.Fatalf("外壳 method 不符：%v", call.Envelope["method"])
	}
	if rpcID, _ := call.Envelope["rpcId"].(string); rpcID == "" {
		t.Fatal("外壳缺少 rpcId")
	}
	payload, ok := call.Envelope["payload"].(map[string]any)
	if !ok {
		t.Fatalf("外壳缺少 payload：%v", call.Envelope)
	}
	args, ok := payload["args"].(map[string]any)
	if !ok {
		t.Fatalf("payload 缺少 args：%v", payload)
	}
	if _, ok := args["request"]; !ok {
		t.Fatalf("args 未按 request 包装：%v", args)
	}
}

// 业务失败必须解析成 *RemoteError，不能因为 HTTP 200 就当成功。
func TestCallSurfacesRemoteError(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	fake.handle(MethodSessionPrompt, func(json.RawMessage) (any, *RemoteError) {
		return nil, &RemoteError{Code: "session/not-found", Message: "会话不存在"}
	})
	err := client.Prompt(context.Background(), PromptRequest{
		SessionID: "missing",
		RequestID: "req-1",
		Content:   []PromptContent{{Type: "text", Text: "hi"}},
	})
	var remoteErr *RemoteError
	if !errors.As(err, &remoteErr) {
		t.Fatalf("应返回 *RemoteError，得到 %v", err)
	}
	if remoteErr.Code != "session/not-found" {
		t.Fatalf("错误码不符：%s", remoteErr.Code)
	}
	if !strings.Contains(remoteErr.Error(), "session/not-found") {
		t.Fatalf("错误串应包含错误码：%s", remoteErr.Error())
	}
}

// 缺少 result 外壳说明请求外壳不被接受，必须报错而不是空成功。
func TestCallRejectsResponseWithoutResult(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "c", Path: "/"})
			w.WriteHeader(http.StatusSeeOther)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"type":"server-response","rpcId":"x"}`))
	}))
	defer server.Close()

	client, err := New(Config{BaseURL: server.URL, AccessToken: "t"})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	if err := client.Authenticate(context.Background()); err != nil {
		t.Fatalf("认证失败：%v", err)
	}
	err = client.Call(context.Background(), MethodSessionModelCatalog, map[string]any{}, nil)
	if !errors.Is(err, ErrNoResult) {
		t.Fatalf("应返回 ErrNoResult，得到 %v", err)
	}
}

// 401 说明 Cookie 已失效，必须清除凭据让上层重新认证。
func TestCallClearsCredentialsOnUnauthorized(t *testing.T) {
	// 不再下发 Cookie 的服务，模拟 Harness 重启后原 Cookie 失效。
	expired := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer expired.Close()

	client, err := New(Config{BaseURL: expired.URL, AccessToken: "t"})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	client.mu.Lock()
	client.cookie = "harness_session=stale"
	client.mu.Unlock()

	if err := client.Call(context.Background(), MethodSessionModelCatalog, map[string]any{}, nil); err == nil {
		t.Fatal("401 应返回错误")
	}
	if client.Authenticated() {
		t.Fatal("401 后必须清除凭据")
	}
}

// base_url 校验：只允许 http/https 且必须有主机。
func TestNewValidatesBaseURL(t *testing.T) {
	cases := []struct {
		name    string
		baseURL string
		wantErr bool
	}{
		{"empty", "", true},
		{"no scheme", "127.0.0.1:5173", true},
		{"unsupported scheme", "ftp://127.0.0.1:5173", true},
		{"loopback http", "http://127.0.0.1:5173", false},
		{"trailing slash trimmed", "http://127.0.0.1:5173/", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client, err := New(Config{BaseURL: tc.baseURL})
			if tc.wantErr {
				if err == nil {
					t.Fatal("应返回错误")
				}
				return
			}
			if err != nil {
				t.Fatalf("不应返回错误：%v", err)
			}
			if strings.HasSuffix(client.BaseURL(), "/") {
				t.Fatalf("base_url 应去掉尾部斜杠：%s", client.BaseURL())
			}
		})
	}
}

func authenticatedClient(t *testing.T, fake *fakeHarness, baseURL string) *Client {
	t.Helper()
	client, err := New(Config{BaseURL: baseURL, AccessToken: fake.token})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	if err := client.Authenticate(context.Background()); err != nil {
		t.Fatalf("认证失败：%v", err)
	}
	return client
}
