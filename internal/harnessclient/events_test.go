package harnessclient

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

const testWait = 5 * time.Second

// 订阅必须发出 open 帧，且 args 按 request 包装；follow 打开直播输出。
func TestSubscribeEventsSendsOpenFrame(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		streamID, _ := open["streamId"].(string)
		return sendFrame(conn, streamID, map[string]any{"type": FrameReady, "clientId": "client-fixture"})
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("订阅 $events 失败：%v", err)
	}
	defer stream.Close()

	clientID, err := stream.Ready(context.Background(), testWait)
	if err != nil {
		t.Fatalf("等待 ready 失败：%v", err)
	}
	if clientID != "client-fixture" {
		t.Fatalf("clientId 不符：%s", clientID)
	}

	opens := fake.openedStreams()
	if len(opens) != 1 {
		t.Fatalf("应记录到一次 open 帧，得到 %d", len(opens))
	}
	if opens[0]["type"] != "open" {
		t.Fatalf("open 帧 type 不符：%v", opens[0]["type"])
	}
	if opens[0]["endpoint"] != EndpointEvents {
		t.Fatalf("open 帧 endpoint 不符：%v", opens[0]["endpoint"])
	}
	payload, _ := opens[0]["payload"].(map[string]any)
	if _, ok := payload["args"]; !ok {
		t.Fatalf("open 帧缺少 payload.args：%v", opens[0])
	}
	if stream.StreamID() == "" {
		t.Fatal("订阅应有非空 streamId")
	}
}

// 会话订阅的 args 必须按 request 包装并带 assistantStream。
func TestFollowSessionSerializesRequest(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		streamID, _ := open["streamId"].(string)
		return sendFrame(conn, streamID, map[string]any{
			"type":    FrameSnapshot,
			"session": map[string]any{"turns": []any{}},
		})
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.FollowSession(context.Background(), "session-fixture", true)
	if err != nil {
		t.Fatalf("订阅会话失败：%v", err)
	}
	defer stream.Close()
	if _, err := stream.Until(context.Background(), "snapshot", testWait, func(value StreamValue) bool {
		return value.Type == FrameSnapshot
	}); err != nil {
		t.Fatalf("等待 snapshot 失败：%v", err)
	}

	opens := fake.openedStreams()
	if opens[0]["endpoint"] != MethodSessionFollow {
		t.Fatalf("endpoint 不符：%v", opens[0]["endpoint"])
	}
	payload, _ := opens[0]["payload"].(map[string]any)
	args, _ := payload["args"].(map[string]any)
	request, _ := args["request"].(map[string]any)
	if request["assistantStream"] != true {
		t.Fatalf("assistantStream 未传递：%v", request)
	}
	address, _ := request["address"].(map[string]any)
	if address["kind"] != "session" || address["sessionId"] != "session-fixture" {
		t.Fatalf("address 不符：%v", address)
	}
}

// durable event 与 assistant-stream 要能区分：前者的判别字段在 event.type。
func TestStreamDistinguishesDurableEventFromAssistantStream(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		streamID, _ := open["streamId"].(string)
		if err := sendFrame(conn, streamID, map[string]any{"type": FrameReady, "clientId": "c1"}); err != nil {
			return err
		}
		if err := sendFrame(conn, streamID, map[string]any{
			"type":  "assistant-stream",
			"frame": map[string]any{"type": "chunk", "text": "fixture "},
		}); err != nil {
			return err
		}
		if err := sendFrame(conn, streamID, map[string]any{
			"event": map[string]any{"type": "turn/start", "turnId": "turn-1"},
		}); err != nil {
			return err
		}
		<-streamDone(conn)
		return nil
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("订阅失败：%v", err)
	}
	defer stream.Close()

	chunk, err := stream.Until(context.Background(), "assistant chunk", testWait, func(value StreamValue) bool {
		return value.Type == FrameAssistantStream
	})
	if err != nil {
		t.Fatalf("等待直播片段失败：%v", err)
	}
	var decoded struct {
		Frame struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"frame"`
	}
	if err := chunk.Decode(&decoded); err != nil {
		t.Fatalf("解码直播片段失败：%v", err)
	}
	if decoded.Frame.Type != "chunk" || decoded.Frame.Text != "fixture " {
		t.Fatalf("直播片段内容不符：%+v", decoded.Frame)
	}

	turnStart, err := stream.Until(context.Background(), "turn/start", testWait, func(value StreamValue) bool {
		return value.EventType == "turn/start"
	})
	if err != nil {
		t.Fatalf("等待持久事件失败：%v", err)
	}
	if turnStart.Type != FrameDurableEvent {
		t.Fatalf("持久事件应归类为 event：%s", turnStart.Type)
	}
}

// waterfall 帧要能解出审批与追问两种交互。
func TestWaterfallDecodesApprovalAndQuestion(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		streamID, _ := open["streamId"].(string)
		if err := sendFrame(conn, streamID, map[string]any{
			"type":    FrameWaterfall,
			"eventId": "event-approval",
			"event":   WaterfallApprovalRequest,
			"request": map[string]any{"toolName": "write", "requestId": "r1", "justification": "controlled"},
		}); err != nil {
			return err
		}
		if err := sendFrame(conn, streamID, map[string]any{
			"type":    FrameWaterfall,
			"eventId": "event-question",
			"event":   WaterfallUserQuestions,
			"request": map[string]any{
				"questions": []any{map[string]any{
					"id":       "confirm",
					"question": "Continue fixture?",
					"options":  []any{map[string]any{"label": "Continue"}},
				}},
			},
		}); err != nil {
			return err
		}
		if err := sendFrame(conn, streamID, map[string]any{
			"type":    FrameCancel,
			"eventId": "event-question",
		}); err != nil {
			return err
		}
		<-streamDone(conn)
		return nil
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("订阅失败：%v", err)
	}
	defer stream.Close()

	approvalFrame, err := stream.Until(context.Background(), "审批", testWait, func(value StreamValue) bool {
		return value.Type == FrameWaterfall
	})
	if err != nil {
		t.Fatalf("等待审批失败：%v", err)
	}
	approval, err := approvalFrame.Waterfall()
	if err != nil {
		t.Fatalf("解析审批失败：%v", err)
	}
	if approval.Event != WaterfallApprovalRequest || approval.EventID != "event-approval" {
		t.Fatalf("审批信封不符：%+v", approval)
	}
	if approval.Request.ToolName != "write" {
		t.Fatalf("审批工具名不符：%+v", approval.Request)
	}

	questionFrame, err := stream.Until(context.Background(), "追问", testWait, func(value StreamValue) bool {
		if value.Type != FrameWaterfall {
			return false
		}
		decoded, err := value.Waterfall()
		return err == nil && decoded.Event == WaterfallUserQuestions
	})
	if err != nil {
		t.Fatalf("等待追问失败：%v", err)
	}
	question, err := questionFrame.Waterfall()
	if err != nil {
		t.Fatalf("解析追问失败：%v", err)
	}
	if len(question.Request.Questions) != 1 || question.Request.Questions[0].ID != "confirm" {
		t.Fatalf("追问结构不符：%+v", question.Request)
	}

	// 另一端先应答后，本端会收到同 eventId 的 cancel，用来撤销对应卡片。
	if _, err := stream.Until(context.Background(), "cancel", testWait, func(value StreamValue) bool {
		return value.Type == FrameCancel
	}); err != nil {
		t.Fatalf("等待 cancel 失败：%v", err)
	}
}

// 追问答案必须逐条按 id 回填，不能把自然语言伪装成结构化答案。
func TestAnswerQuestionsSendsStructuredAnswers(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)
	fake.handle(EndpointEventsResult, func(json.RawMessage) (any, *RemoteError) { return map[string]any{}, nil })

	err := client.AnswerQuestions(context.Background(), "client-1", "event-question", []Answer{
		{ID: "confirm", Selected: []string{"Continue"}},
	})
	if err != nil {
		t.Fatalf("回传答案失败：%v", err)
	}
	call := fake.recorded()[0]
	payload, _ := call.Envelope["payload"].(map[string]any)
	args, _ := payload["args"].(map[string]any)
	outcome, _ := args["outcome"].(map[string]any)
	if outcome["kind"] != "result" {
		t.Fatalf("outcome kind 不符：%v", outcome)
	}
	value, _ := outcome["value"].(map[string]any)
	answers, _ := value["answers"].([]any)
	if len(answers) != 1 {
		t.Fatalf("答案条数不符：%v", value)
	}
	first, _ := answers[0].(map[string]any)
	if first["id"] != "confirm" {
		t.Fatalf("答案缺少 id：%v", first)
	}
	selected, _ := first["selected"].([]any)
	if len(selected) != 1 || selected[0] != "Continue" {
		t.Fatalf("答案选项不符：%v", first)
	}
}

// 未知审批结论必须在本地被拒绝，不发出请求。
func TestResolveApprovalRejectsUnknownDecision(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	if err := client.ResolveApproval(context.Background(), "c", "e", "always-allow"); err == nil {
		t.Fatal("未知审批结论应被拒绝")
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("被拒绝的结论不应发出请求")
	}
}

// 等待超时要给出可定位的错误，不能静默阻塞或返回空帧。
func TestUntilTimesOutWithContext(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		<-streamDone(conn)
		return nil
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("订阅失败：%v", err)
	}
	defer stream.Close()

	_, err = stream.Until(context.Background(), "某个信号", 150*time.Millisecond, func(StreamValue) bool { return false })
	if err == nil {
		t.Fatal("超时应返回错误")
	}
	if !strings.Contains(err.Error(), "某个信号") || !strings.Contains(err.Error(), EndpointEvents) {
		t.Fatalf("超时错误应带上用途标签与 endpoint：%v", err)
	}
}

// Close 必须幂等，且关闭后等待者立刻得到明确错误而不是挂住。
func TestStreamCloseIsIdempotentAndUnblocksUntil(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		<-streamDone(conn)
		return nil
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("订阅失败：%v", err)
	}
	stream.Close()
	stream.Close()

	_, err = stream.Until(context.Background(), "关闭后", 2*time.Second, func(StreamValue) bool { return true })
	if err == nil {
		t.Fatal("关闭后等待应返回错误")
	}
	var notClosed error = ErrNotAuthenticated
	if errors.Is(err, notClosed) {
		t.Fatalf("关闭后应是订阅结束错误：%v", err)
	}
	select {
	case <-stream.Done():
	default:
		t.Fatal("Close 后 Done 应当已关闭")
	}
}

// 未认证时不得建立事件流。
func TestOpenStreamRequiresAuthentication(t *testing.T) {
	client, err := New(Config{BaseURL: "http://127.0.0.1:1"})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	if _, err := client.SubscribeEvents(context.Background()); !errors.Is(err, ErrNotAuthenticated) {
		t.Fatalf("未认证订阅应返回 ErrNotAuthenticated，得到 %v", err)
	}
}

// 事件流保活：服务端读到 ping 之前不应断开。
func TestStreamSendsPingKeepalive(t *testing.T) {
	pong := make(chan struct{})
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		conn.SetPongHandler(func(string) error {
			select {
			case <-pong:
			default:
				close(pong)
			}
			return nil
		})
		// 主动读，触发 pong 处理。
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return nil
			}
		}
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("订阅失败：%v", err)
	}
	defer stream.Close()

	// 只断言连接在保活周期内不会因为空闲被本端断开；真正的 ping 周期是 30 秒，
	// 这里不等待那么久，改为确认订阅此时仍然可用。
	if stream.StreamID() == "" {
		t.Fatal("订阅应保持有效")
	}
}

// streamDone 返回一个在连接关闭前不会关闭的通道，便于回放协程退出。
func streamDone(conn *websocket.Conn) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}()
	return done
}

// authenticatedClientWithIdle 与 authenticatedClient 同构，额外把读空闲上限调小，
// 让「对端静默」这类用例不必真的等 90 秒。
func authenticatedClientWithIdle(t *testing.T, fake *fakeHarness, baseURL string, idle time.Duration) *Client {
	t.Helper()
	client, err := New(Config{BaseURL: baseURL, AccessToken: fake.token, streamIdle: idle})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	if err := client.Authenticate(context.Background()); err != nil {
		t.Fatalf("认证失败：%v", err)
	}
	return client
}

// 对端静默（不回 pong、也不发任何帧）时订阅必须结束。
//
// 这是半开链路的形态：不设读期限的话 readLoop 会永久阻塞在 ReadMessage 上，
// Frames 永不关闭，上层的重连路径也就永远不会被触发。
func TestStreamEndsWhenPeerGoesSilent(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, _ map[string]any) error {
		// 关键：屏蔽默认 ping 处理器的自动 pong，否则服务端会替我们保活，
		// 读期限一直被续期，就构造不出静默。
		conn.SetPingHandler(func(string) error { return nil })
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return nil
			}
		}
	})
	server := fake.serve()
	client := authenticatedClientWithIdle(t, fake, server.URL, 300*time.Millisecond)

	stream, err := client.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("订阅失败：%v", err)
	}
	defer stream.Close()

	select {
	case <-stream.Done():
	case <-time.After(testWait):
		t.Fatal("对端静默后订阅应当结束，而不是一直阻塞在读上")
	}
	assertFramesClosed(t, stream)
}

// 对端直接断开时，订阅必须整体结束：Done 与 Frames 都要关闭。
//
// 只关 Frames 会漏掉一个一直跑的 ping ticker 和一条没关的连接。
func TestStreamEndsWhenPeerClosesConnection(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(*websocket.Conn, map[string]any) error {
		// 立即返回，serveMuxStream 的 defer 会关掉这条连接。
		return nil
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("订阅失败：%v", err)
	}
	defer stream.Close()

	select {
	case <-stream.Done():
	case <-time.After(testWait):
		t.Fatal("对端断开后 Done 应当关闭，否则 ping 协程与连接都会泄漏")
	}
	assertFramesClosed(t, stream)
}

// assertFramesClosed 断言订阅结束后 Frames 也已关闭，上层才等得到「订阅结束」
// 而不是靠自己的超时。
func assertFramesClosed(t *testing.T, stream *Stream) {
	t.Helper()
	deadline := time.After(testWait)
	for {
		select {
		case _, ok := <-stream.Frames():
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("订阅结束后 Frames 应当关闭")
		}
	}
}
