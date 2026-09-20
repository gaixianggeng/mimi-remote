package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

// 本文件覆盖 /api/harness/ws 的流中继安全边界。
//
// 每个负向用例都同时断言两件事：移动端收到的错误，以及**上游一次都没被访问**。
// 后者才是这条通道的核心约束——越权订阅如果先建连再判断，攻击面就已经产生了。

// harnessNativeStreamStub 是一个最小的 Harness 替身：只实现本任务用到的四件事。
type harnessNativeStreamStub struct {
	t *testing.T

	token  string
	cookie string

	sessions []harnessclient.SessionSummary
	// muxOpen 在收到 open 帧后回放帧。
	muxOpen func(conn *websocket.Conn, open map[string]any)

	mu        sync.Mutex
	opened    []map[string]any
	listCalls int
	rpcCalls  []string
}

func newHarnessNativeStreamStub(t *testing.T) *harnessNativeStreamStub {
	t.Helper()
	return &harnessNativeStreamStub{
		t:      t,
		token:  "startup-token-stream-fixture",
		cookie: "harness_session=stream-fixture",
	}
}

func (stub *harnessNativeStreamStub) recordOpen(open map[string]any) {
	stub.mu.Lock()
	defer stub.mu.Unlock()
	stub.opened = append(stub.opened, open)
}

func (stub *harnessNativeStreamStub) openedStreams() []map[string]any {
	stub.mu.Lock()
	defer stub.mu.Unlock()
	return append([]map[string]any(nil), stub.opened...)
}

func (stub *harnessNativeStreamStub) upstreamTouches() (int, int) {
	stub.mu.Lock()
	defer stub.mu.Unlock()
	return len(stub.opened), stub.listCalls
}

func (stub *harnessNativeStreamStub) recordedRPCs() []string {
	stub.mu.Lock()
	defer stub.mu.Unlock()
	return append([]string(nil), stub.rpcCalls...)
}

func (stub *harnessNativeStreamStub) serve() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		if r.URL.Query().Get("token") != stub.token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "stream-fixture", Path: "/"})
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc("/api/remote.mux", func(w http.ResponseWriter, r *http.Request) {
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
		stub.recordOpen(open)
		if stub.muxOpen == nil {
			return
		}
		stub.muxOpen(conn, open)
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		if _, err := r.Cookie("harness_session"); err != nil {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		method := strings.TrimPrefix(r.URL.Path, "/api/")
		stub.mu.Lock()
		stub.rpcCalls = append(stub.rpcCalls, method)
		if method == "session/list" {
			stub.listCalls++
		}
		sessions := stub.sessions
		stub.mu.Unlock()

		var value any = map[string]any{}
		if method == "session/list" {
			value = map[string]any{"items": sessions}
		}
		var envelope map[string]any
		_ = json.NewDecoder(r.Body).Decode(&envelope)
		rpcID, _ := envelope["rpcId"].(string)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"type":   "server-response",
			"rpcId":  rpcID,
			"result": map[string]any{"ok": true, "value": value},
		})
	})
	server := httptest.NewServer(mux)
	stub.t.Cleanup(server.Close)
	return server
}

// harnessNativeStreamFixture 起一个配好 stub 的 agentd，返回可拨号的 WS 地址与授权目录。
//
// 授权目录必须返回给用例：正向用例要造一个 cwd 落在 allowlist 内的会话来证明
// "能通过的确实能通过"。只测拒绝会掩盖"全部被拒"的实现错误——形状写错时
// 每个 follow 都会被拒，看起来和策略生效一模一样。
func harnessNativeStreamFixture(t *testing.T, stub *harnessNativeStreamStub) (string, string) {
	t.Helper()
	upstream := stub.serve()
	tokenFile := filepath.Join(t.TempDir(), "harness-token")
	if err := os.WriteFile(tokenFile, []byte(stub.token), 0o600); err != nil {
		t.Fatal(err)
	}
	authorized := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "demo", Name: "Demo", Path: authorized}}
		cfg.DeepSeek = config.DeepSeekConfig{
			Enabled:   true,
			BaseURL:   upstream.URL,
			TokenFile: tokenFile,
		}
	})
	agentd := httptest.NewServer(server.handler)
	t.Cleanup(agentd.Close)
	return "ws" + strings.TrimPrefix(agentd.URL, "http") + "/api/harness/ws", authorized
}

// dialHarnessNativeStream 拨号到原生流中继。
func dialHarnessNativeStream(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	header := http.Header{}
	header.Set("Authorization", "Bearer "+testToken)
	conn, response, err := websocket.DefaultDialer.Dial(url, header)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		t.Fatalf("拨号失败（status=%d）：%v", status, err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func sendHarnessNativeFrame(t *testing.T, conn *websocket.Conn, payload map[string]any) {
	t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteMessage(websocket.TextMessage, raw); err != nil {
		t.Fatal(err)
	}
}

// readHarnessNativeFrame 读一帧，超时即失败。
func readHarnessNativeFrame(t *testing.T, conn *websocket.Conn) map[string]any {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("读取中继帧失败：%v", err)
	}
	var frame map[string]any
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatalf("中继帧不是合法 JSON：%v（%s）", err, raw)
	}
	return frame
}

func harnessNativeFixtureSession(id, cwd string) harnessclient.SessionSummary {
	return harnessclient.SessionSummary{SessionID: id, CWD: cwd, UpdatedAt: 1}
}

// --- 订阅声明：本地校验先于上游访问 ---

func TestHarnessNativeStreamRejectsUnknownEndpointWithoutUpstream(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)

	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "open", "streamId": "s1", "endpoint": "session/prompt",
	})
	frame := readHarnessNativeFrame(t, conn)
	if frame["type"] != harnessclient.CarrierError {
		t.Fatalf("非白名单 endpoint 必须回错误帧，得到 %v", frame)
	}
	if opens, _ := stub.upstreamTouches(); opens != 0 {
		t.Fatalf("被拒的订阅不得触达上游，得到 %d 次", opens)
	}
}

func TestHarnessNativeStreamRejectsParamsForZeroArgSubscription(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)

	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "open", "streamId": "s1", "endpoint": "$events",
		"payload": map[string]any{"args": map[string]any{"sessionId": "whatever"}},
	})
	frame := readHarnessNativeFrame(t, conn)
	if frame["type"] != harnessclient.CarrierError {
		t.Fatalf("零参数订阅带参数必须拒绝，得到 %v", frame)
	}
	if opens, _ := stub.upstreamTouches(); opens != 0 {
		t.Fatalf("被拒的订阅不得触达上游，得到 %d 次", opens)
	}
}

func TestHarnessNativeStreamFollowRejectsUnauthorizedSessionWithoutUpstream(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	unauthorized := t.TempDir()
	// 上游知道这个会话，但它的 cwd 不在 projects allowlist 里。
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-out", unauthorized)}
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)

	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "open", "streamId": "s1", "endpoint": "session/follow",
		"payload": map[string]any{"args": map[string]any{"request": map[string]any{
			"address": map[string]any{"kind": "session", "sessionId": "session-out"},
		}}},
	})
	frame := readHarnessNativeFrame(t, conn)
	if frame["type"] != harnessclient.CarrierError {
		t.Fatalf("越权 follow 必须回错误帧，得到 %v", frame)
	}
	if opens, _ := stub.upstreamTouches(); opens != 0 {
		t.Fatalf("越权 follow 不得建立上游订阅，得到 %d 次", opens)
	}
}

func TestHarnessNativeStreamFollowForwardsAuthorizedSession(t *testing.T) {
	// 正向对照：授权目录内的会话必须真的建立上游订阅，并把形参原样透传。
	// 缺了这条，"所有 follow 都被拒"同样能让上面那条负向用例变绿。
	stub := newHarnessNativeStreamStub(t)
	url, authorized := harnessNativeStreamFixture(t, stub)
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-in", authorized)}
	conn := dialHarnessNativeStream(t, url)

	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "open", "streamId": "s1", "endpoint": "session/follow",
		"payload": map[string]any{"args": map[string]any{"request": map[string]any{
			"address":         map[string]any{"kind": "session", "sessionId": "session-in"},
			"assistantStream": true,
			"maxMessages":     200,
		}}},
	})

	waitForHarnessNativeStream(t, stub)
	opened := stub.openedStreams()
	if len(opened) != 1 {
		t.Fatalf("应恰好建立一条上游订阅，得到 %d", len(opened))
	}
	if opened[0]["endpoint"] != "session/follow" {
		t.Fatalf("endpoint 必须原样透传，得到 %v", opened[0]["endpoint"])
	}
	// 形参键必须是 request（逐字冻结），且 address 在它内部。
	payload, _ := opened[0]["payload"].(map[string]any)
	args, _ := payload["args"].(map[string]any)
	request, ok := args["request"].(map[string]any)
	if !ok {
		t.Fatalf("follow 形参必须包在 request 键内，得到 %v", args)
	}
	address, _ := request["address"].(map[string]any)
	if address["sessionId"] != "session-in" {
		t.Fatalf("address.sessionId 必须透传，得到 %v", request)
	}
	if request["assistantStream"] != true {
		t.Fatalf("assistantStream 必须透传，得到 %v", request)
	}
}

func TestHarnessNativeStreamFollowRejectsSubagentAddress(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)

	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "open", "streamId": "s1", "endpoint": "session/follow",
		"payload": map[string]any{"args": map[string]any{"request": map[string]any{
			"address": map[string]any{"kind": "subagent", "parentSessionId": "p", "childSessionId": "c"},
		}}},
	})
	frame := readHarnessNativeFrame(t, conn)
	if frame["type"] != harnessclient.CarrierError {
		t.Fatalf("首版只开放 session 形态，得到 %v", frame)
	}
	if opens, _ := stub.upstreamTouches(); opens != 0 {
		t.Fatalf("被拒的订阅不得触达上游，得到 %d 次", opens)
	}
}

// --- $events：ready 脱敏与 waterfall 归属 ---

func TestHarnessNativeStreamStripsReadyMetadata(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		streamID, _ := open["streamId"].(string)
		_ = conn.WriteMessage(websocket.TextMessage, mustRawJSON(map[string]any{
			"type":     "item",
			"streamId": streamID,
			"value": map[string]any{
				"type":     "ready",
				"clientId": "upstream-client-secret",
				"host":     map[string]any{"home": "/Users/someone/private"},
			},
		}))
		<-make(chan struct{}) // 保持订阅打开
	}
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)

	sendHarnessNativeFrame(t, conn, map[string]any{"type": "open", "streamId": "s1", "endpoint": "$events"})
	frame := readHarnessNativeFrame(t, conn)

	encoded := string(mustRawJSON(frame))
	if strings.Contains(encoded, "upstream-client-secret") {
		t.Fatalf("clientId 不得下发移动端：%s", encoded)
	}
	if strings.Contains(encoded, "/Users/someone/private") || strings.Contains(encoded, "home") {
		t.Fatalf("host.home 不得下发移动端：%s", encoded)
	}
	value, _ := frame["value"].(map[string]any)
	if value["type"] != "ready" {
		t.Fatalf("ready 帧仍应下发（只是脱敏），得到 %v", frame)
	}
}

func TestHarnessNativeStreamDropsUnauthorizedWaterfall(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	unauthorized := t.TempDir()
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-out", unauthorized)}
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		streamID, _ := open["streamId"].(string)
		_ = conn.WriteMessage(websocket.TextMessage, mustRawJSON(map[string]any{
			"type":     "item",
			"streamId": streamID,
			"value": map[string]any{
				"type":    "waterfall",
				"event":   "approval/request",
				"eventId": "evt-out",
				"agentId": "session-out",
				"request": map[string]any{"toolName": "bash", "callId": "c1", "reason": "越权内容"},
			},
		}))
		<-make(chan struct{})
	}
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)

	sendHarnessNativeFrame(t, conn, map[string]any{"type": "open", "streamId": "s1", "endpoint": "$events"})

	// 越权交互不得下发。本 stub 只回放这一帧，因此"读不到任何帧"才是正确行为：
	// 只要有帧到达（无论内容）就说明越权交互被投递了。
	_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, raw, err := conn.ReadMessage(); err == nil {
		t.Fatalf("未授权交互不得下发任何帧，得到 %s", raw)
	}
}

// TestHarnessNativeStreamForwardsAuthorizedWaterfall 是 waterfall 投递的正向对照。
//
// 只有拒绝用例时，"投递链路整体坏掉"与"策略正确生效"完全无法区分——越权用例照样
// 通过。H03 必须验收要求"已授权 waterfall 即使页面未打开也能送达"，本用例证明：
// 未开任何 session/follow 时 waterfall 仍能送达，且送达后应答被接纳并转发上游
// （与"未投递即拒绝"形成对照）。
func TestHarnessNativeStreamForwardsAuthorizedWaterfall(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, authorized := harnessNativeStreamFixture(t, stub)
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-in", authorized)}
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		streamID, _ := open["streamId"].(string)
		_ = conn.WriteMessage(websocket.TextMessage, mustRawJSON(map[string]any{
			"type": "item", "streamId": streamID,
			"value": map[string]any{"type": "ready", "clientId": "upstream-client-1"},
		}))
		_ = conn.WriteMessage(websocket.TextMessage, mustRawJSON(map[string]any{
			"type": "item", "streamId": streamID,
			"value": map[string]any{
				"type":    "waterfall",
				"event":   harnessclient.WaterfallApprovalRequest,
				"eventId": "evt-in",
				"agentId": "session-in",
				"request": map[string]any{"toolName": "bash", "callId": "c1", "reason": "授权内容"},
			},
		}))
		<-make(chan struct{})
	}
	conn := dialHarnessNativeStream(t, url)
	sendHarnessNativeFrame(t, conn, map[string]any{"type": "open", "streamId": "s1", "endpoint": "$events"})

	// 首帧是 ready，第二帧才是 waterfall。
	var delivered map[string]any
	for attempt := 0; attempt < 2; attempt++ {
		frame := readHarnessNativeFrame(t, conn)
		if value, ok := frame["value"].(map[string]any); ok && value["type"] == "waterfall" {
			delivered = value
			break
		}
	}
	if delivered == nil {
		t.Fatal("已授权的 waterfall 必须送达")
	}
	if delivered["event"] != harnessclient.WaterfallApprovalRequest {
		t.Fatalf("原生事件名不得被改写：%v", delivered["event"])
	}
	if delivered["eventId"] != "evt-in" || delivered["agentId"] != "session-in" {
		t.Fatalf("原生身份字段不得被改写：%v", delivered)
	}
	if _, ok := delivered["method"]; ok {
		t.Fatalf("下行不得出现 app-server 的 method 字段：%v", delivered)
	}

	for _, opened := range stub.openedStreams() {
		if opened["endpoint"] == "session/follow" {
			t.Fatalf("投递不得依赖页面打开：%v", opened)
		}
	}

	// 已送达的 eventId，应答必须被接纳并真正转发上游。
	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "respond", "eventId": "evt-in",
		"outcome": map[string]any{"kind": "result", "value": "allowed-once"},
	})
	waitForHarnessNativeRPC(t, stub, "$events/result")
}

// TestHarnessNativeStreamFollowKeepsFixtureWireShape 用冻结夹具钉死 follow 的原生
// 参数嵌套，并证明上游帧没有被 Codex 化。
//
// 这一条针对一个真实踩过的坑：把 address 当成顶层参数解析时，每个 follow 都会因
// 形状不符被拒——而只有拒绝用例时，这与"策略生效"完全无法区分。
func TestHarnessNativeStreamFollowKeepsFixtureWireShape(t *testing.T) {
	fixture, err := os.ReadFile("../../contracts/harness-native/fixtures/stream/mux-carrier.json")
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Observations []struct {
			Label string          `json:"label"`
			Value json.RawMessage `json:"value"`
		} `json:"observations"`
	}
	if err := json.Unmarshal(fixture, &document); err != nil {
		t.Fatal(err)
	}
	var open map[string]any
	for _, observation := range document.Observations {
		if observation.Label != "client.open" {
			continue
		}
		if err := json.Unmarshal(observation.Value, &open); err != nil {
			t.Fatal(err)
		}
	}
	if open == nil {
		t.Fatal("夹具缺少 client.open 观测")
	}

	stub := newHarnessNativeStreamStub(t)
	url, authorized := harnessNativeStreamFixture(t, stub)
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("h00-session-0001", authorized)}
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) { <-make(chan struct{}) }
	conn := dialHarnessNativeStream(t, url)

	// 夹具里的 sessionId 落在授权范围内，因此这一帧必须被接受并原样转发上游。
	sendHarnessNativeFrame(t, conn, open)
	waitForHarnessNativeStream(t, stub)

	opened := stub.openedStreams()
	if len(opened) != 1 {
		t.Fatalf("应恰好建立 1 条上游订阅，得到 %d", len(opened))
	}
	if opened[0]["endpoint"] != "session/follow" {
		t.Fatalf("endpoint 应原样转发，得到 %v", opened[0]["endpoint"])
	}
	payload, _ := opened[0]["payload"].(map[string]any)
	args, _ := payload["args"].(map[string]any)
	request, _ := args["request"].(map[string]any)
	address, _ := request["address"].(map[string]any)
	if address["sessionId"] != "h00-session-0001" {
		t.Fatalf("原生参数嵌套 args.request.address.sessionId 必须保留，得到 %v", opened[0])
	}
	if request["assistantStream"] != true || request["maxMessages"] != float64(200) {
		t.Fatalf("原生可选参数必须保留，得到 %v", request)
	}
	encoded := string(mustRawJSON(opened[0]))
	for _, codexField := range []string{"jsonrpc", "\"method\"", "threadId"} {
		if strings.Contains(encoded, codexField) {
			t.Fatalf("上游帧不得被 Codex 化（出现 %s）：%s", codexField, encoded)
		}
	}
}

func TestHarnessNativeStreamRejectsRespondForNeverDeliveredEvent(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)

	sendHarnessNativeFrame(t, conn, map[string]any{
		"type": "respond", "eventId": "evt-never-delivered",
		"outcome": map[string]any{"kind": "result", "value": "allowed-once"},
	})
	frame := readHarnessNativeFrame(t, conn)
	if frame["type"] != harnessclient.CarrierError {
		t.Fatalf("未投递的 eventId 必须拒绝，得到 %v", frame)
	}
	for _, method := range stub.recordedRPCs() {
		if method == "$events/result" {
			t.Fatal("被拒的应答不得触达上游")
		}
	}
}

// --- 退订与释放 ---

func TestHarnessNativeStreamCancelEndsStreamAndIsIdempotent(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		<-make(chan struct{}) // 保持订阅打开，等客户端主动退订
	}
	url, _ := harnessNativeStreamFixture(t, stub)
	conn := dialHarnessNativeStream(t, url)

	// 普通订阅的取消仍是幂等的；$events 绑定退役关闭连接由 H03 专项覆盖。
	sendHarnessNativeFrame(t, conn, map[string]any{"type": "open", "streamId": "s1", "endpoint": "session/control"})
	waitForHarnessNativeStream(t, stub)

	sendHarnessNativeFrame(t, conn, map[string]any{"type": "cancel", "streamId": "s1"})
	frame := readHarnessNativeFrame(t, conn)
	if frame["type"] != harnessclient.CarrierEnd {
		t.Fatalf("退订应回 end 帧，得到 %v", frame)
	}

	// 重复退订是空操作，不是错误（客户端与中继对"谁先发现流已结束"有竞态）。
	sendHarnessNativeFrame(t, conn, map[string]any{"type": "cancel", "streamId": "s1"})
	_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, raw, err := conn.ReadMessage(); err == nil {
		t.Fatalf("重复退订不应产生任何帧，得到 %s", raw)
	}
}

func waitForHarnessNativeStream(t *testing.T, stub *harnessNativeStreamStub) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if opens, _ := stub.upstreamTouches(); opens > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("上游订阅始终未建立")
}

// waitForHarnessNativeRPC 等到上游真的收到某个 RPC。正向用例必须等，不能像负向
// 用例那样只断言"没收到"——否则转发链路坏掉时用例照样通过。
func waitForHarnessNativeRPC(t *testing.T, stub *harnessNativeStreamStub, method string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, recorded := range stub.recordedRPCs() {
			if recorded == method {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("上游始终未收到 %s", method)
}

func mustRawJSON(value any) []byte {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}
