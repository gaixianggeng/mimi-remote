package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestCodexAutoThreadTitleGeneratorGeneratesAndSetsName(t *testing.T) {
	upstreamURL, state := newAutoThreadTitleUpstream(t, "", `{"title":"修复登录状态同步"}`)
	generator := newCodexAutoThreadTitleGenerator(autoThreadTitleTestRouter(t, upstreamURL))

	title, updated, err := generator.GenerateAndSet(context.Background(), autoThreadTitleRequest{
		ThreadID: "thread-target",
		CWD:      t.TempDir(),
		Prompt:   "登录后页面没有刷新，请修复状态同步",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !updated || title != "修复登录状态同步" {
		t.Fatalf("标题生成结果异常：updated=%t title=%q", updated, title)
	}

	state.mu.Lock()
	defer state.mu.Unlock()
	if state.readCalls != 2 {
		t.Fatalf("写回前后应各读取一次目标线程名称，got=%d", state.readCalls)
	}
	if state.setTitle != title {
		t.Fatalf("thread/name/set 标题异常：got=%q want=%q", state.setTitle, title)
	}
	if state.threadStart["approvalPolicy"] != "never" ||
		state.threadStart["sandbox"] != "read-only" ||
		state.threadStart["ephemeral"] != true {
		t.Fatalf("临时标题线程必须 never + read-only + ephemeral：%v", state.threadStart)
	}
	if _, exists := state.threadStart["model"]; exists {
		t.Fatalf("标题生成不应硬编码内部模型：%v", state.threadStart)
	}
	if state.turnStart["effort"] != "low" {
		t.Fatalf("标题 turn 必须使用 low effort：%v", state.turnStart)
	}
	schema, ok := state.turnStart["outputSchema"].(map[string]any)
	if !ok {
		t.Fatalf("标题 turn 缺少结构化输出 schema：%v", state.turnStart)
	}
	properties := schema["properties"].(map[string]any)
	titleSchema := properties["title"].(map[string]any)
	if titleSchema["maxLength"] != json.Number("36") {
		t.Fatalf("标题 schema 必须限制 36 字符：%v", titleSchema)
	}
}

func TestCodexAutoThreadTitleGeneratorDoesNotOverwriteExistingName(t *testing.T) {
	upstreamURL, state := newAutoThreadTitleUpstream(t, "用户手动标题", `{"title":"模型标题"}`)
	generator := newCodexAutoThreadTitleGenerator(autoThreadTitleTestRouter(t, upstreamURL))

	title, updated, err := generator.GenerateAndSet(context.Background(), autoThreadTitleRequest{
		ThreadID: "thread-target",
		CWD:      t.TempDir(),
		Prompt:   "不应覆盖标题",
	})
	if err != nil {
		t.Fatal(err)
	}
	if updated || title != "" {
		t.Fatalf("已有名称时应直接退出：updated=%t title=%q", updated, title)
	}

	state.mu.Lock()
	defer state.mu.Unlock()
	if state.readCalls != 1 || state.threadStart != nil || state.setTitle != "" {
		t.Fatalf("已有名称时不应创建模型线程或写回：%+v", state)
	}
}

func TestCodexAutoThreadTitleGeneratorDoesNotOverwriteNameChangedDuringGeneration(t *testing.T) {
	upstreamURL, state := newAutoThreadTitleUpstream(t, "", `{"title":"模型标题"}`)
	state.mu.Lock()
	state.renameAfterGeneration = "生成期间的手动标题"
	state.mu.Unlock()
	generator := newCodexAutoThreadTitleGenerator(autoThreadTitleTestRouter(t, upstreamURL))

	title, updated, err := generator.GenerateAndSet(context.Background(), autoThreadTitleRequest{
		ThreadID: "thread-target",
		CWD:      t.TempDir(),
		Prompt:   "生成期间用户会手动改名",
	})
	if err != nil {
		t.Fatal(err)
	}
	if updated || title != "" {
		t.Fatalf("第二次名称检查发现手动改名时应放弃写回：updated=%t title=%q", updated, title)
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.readCalls != 2 || state.setTitle != "" {
		t.Fatalf("生成期间改名不应被覆盖：readCalls=%d setTitle=%q", state.readCalls, state.setTitle)
	}
}

func TestCodexAutoThreadTitleGeneratorUsesSafeFallback(t *testing.T) {
	upstreamURL, state := newAutoThreadTitleUpstream(t, "", `not-json`)
	generator := newCodexAutoThreadTitleGenerator(autoThreadTitleTestRouter(t, upstreamURL))
	prompt := "修复 /Users/private/project，Token 是 sk-sensitive-value"

	title, updated, err := generator.GenerateAndSet(context.Background(), autoThreadTitleRequest{
		ThreadID: "thread-target",
		CWD:      t.TempDir(),
		Prompt:   prompt,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !updated || title != autoThreadTitleFallbackUntitled {
		t.Fatalf("模型输出异常时应使用安全通用标题：updated=%t title=%q", updated, title)
	}
	if strings.Contains(title, "/Users/") || strings.Contains(title, "sk-sensitive-value") {
		t.Fatalf("安全降级标题不能包含用户输入中的路径或 Token：%q", title)
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.setTitle != title {
		t.Fatalf("降级标题未持久化：got=%q want=%q", state.setTitle, title)
	}
}

func TestCodexAutoThreadTitleGeneratorCancellationClosesBlockedWebSocket(t *testing.T) {
	started := make(chan struct{})
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		conn, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		var frame runtimeWebSocketFrame
		if conn.ReadJSON(&frame) == nil {
			close(started)
		}
		_, _, _ = conn.ReadMessage()
	}))
	defer server.Close()
	generator := newCodexAutoThreadTitleGenerator(autoThreadTitleTestRouter(
		t,
		"ws"+strings.TrimPrefix(server.URL, "http"),
	))
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	cwd := t.TempDir()
	go func() {
		_, _, err := generator.GenerateAndSet(ctx, autoThreadTitleRequest{
			ThreadID: "thread-target",
			CWD:      cwd,
			Prompt:   "取消任务",
		})
		result <- err
	}()

	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("fake app-server 未收到 initialize")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("取消后应返回 context.Canceled，got=%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("取消后阻塞 WebSocket 未及时关闭")
	}
}

func TestAutoThreadTitleRequestOnlyConsumesNewCodexThreadOnce(t *testing.T) {
	for _, method := range []string{"thread/queue/add", "turn/start"} {
		t.Run(method, func(t *testing.T) {
			policy := &appServerGatewayPolicy{
				runtimeID: "codex",
				allowedThreads: map[string]appServerGatewayAllowedThread{
					"thread-new": {
						id:                "thread-new",
						runtimeID:         "codex",
						cwd:               "/tmp/project",
						scopeID:           "project",
						autoTitleEligible: true,
					},
				},
			}
			payload, err := json.Marshal(map[string]any{
				"id":     3,
				"method": method,
				"params": map[string]any{
					"threadId": "thread-new",
					"input": []any{
						map[string]any{"type": "text", "text": "检查支付回调"},
						map[string]any{"type": "localImage", "path": "/secret/screenshot.png"},
						map[string]any{"type": "skill", "name": "review", "path": "/secret/SKILL.md"},
					},
				},
			})
			if err != nil {
				t.Fatal(err)
			}

			request, ok := policy.takeAutoThreadTitleRequest(payload)
			if !ok {
				t.Fatalf("新 Codex thread 的首个 %s 应生成标题请求", method)
			}
			if request.ThreadID != "thread-new" || request.CWD != "/tmp/project" {
				t.Fatalf("标题请求线程绑定异常：%+v", request)
			}
			if !strings.Contains(request.Prompt, "检查支付回调") ||
				!strings.Contains(request.Prompt, "[Image]") ||
				!strings.Contains(request.Prompt, "@review") {
				t.Fatalf("标题 prompt 未保留安全摘要：%q", request.Prompt)
			}
			if strings.Contains(request.Prompt, "/secret/") {
				t.Fatalf("标题 prompt 不应复制图片或 Skill 路径：%q", request.Prompt)
			}
			if _, ok := policy.takeAutoThreadTitleRequest(payload); ok {
				t.Fatal("同一新 thread 的标题资格只能消费一次")
			}
		})
	}
}

func TestAutoThreadTitleCoordinatorDeduplicatesAndSerializes(t *testing.T) {
	generator := &blockingAutoThreadTitleGenerator{
		started: make(chan string, 2),
		release: make(chan struct{}, 2),
	}
	coordinator := newAutoThreadTitleCoordinator(generator, 2*time.Second)
	notifications := make(chan string, 2)
	request := func(threadID string) autoThreadTitleRequest {
		return autoThreadTitleRequest{
			ThreadID: threadID,
			CWD:      "/tmp/project",
			Prompt:   "生成标题",
			Notify: func(threadID string, _ string) {
				notifications <- threadID
			},
		}
	}

	coordinator.Schedule(request("thread-1"))
	coordinator.Schedule(request("thread-1"))
	coordinator.Schedule(request("thread-2"))

	first := receiveString(t, generator.started)
	select {
	case second := <-generator.started:
		t.Fatalf("标题任务必须串行，%s 尚未释放时启动了 %s", first, second)
	case <-time.After(50 * time.Millisecond):
	}
	generator.release <- struct{}{}
	second := receiveString(t, generator.started)
	if second == first {
		t.Fatalf("去重后第二个任务应属于另一个线程：first=%s second=%s", first, second)
	}
	generator.release <- struct{}{}
	receiveString(t, notifications)
	receiveString(t, notifications)
	coordinator.Close()

	if generator.calls.Load() != 2 {
		t.Fatalf("重复线程只能调用生成器一次，calls=%d", generator.calls.Load())
	}
	if generator.maxActive.Load() != 1 {
		t.Fatalf("标题生成全局并发必须为 1，max=%d", generator.maxActive.Load())
	}
}

func TestGatewayPublishesAutoThreadTitleNotificationToOriginatingClient(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		var frame appServerGatewayFrame
		if json.Unmarshal(payload, &frame) != nil {
			return
		}
		params, _ := decodeGatewayParams(frame.Params)
		switch frame.Method {
		case "thread/start":
			cwd, _ := gatewayStringParam(params, "cwd")
			writeAutoTitleRPCResult(t, conn, *frame.ID, map[string]any{
				"thread": map[string]any{
					"id":  "thread-new",
					"cwd": cwd,
				},
			})
		case "thread/queue/add":
			writeAutoTitleRPCResult(t, conn, *frame.ID, map[string]any{
				"queuedSubmission": map[string]any{
					"id":                  "submission-main",
					"input":               params["input"],
					"clientUserMessageId": "client-main",
				},
			})
		}
	})
	handler, router, projectDir := buildAppServerGatewayFixture(t, upstreamURL, nil)
	router.autoThreadTitles = immediateAutoThreadTitleScheduler{title: "自动生成标题"}
	server := httptest.NewServer(handler)
	defer server.Close()
	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	if err := conn.WriteJSON(map[string]any{
		"id":     1,
		"method": "thread/start",
		"params": map[string]any{
			"cwd":            projectDir,
			"approvalPolicy": "on-request",
			"sandbox":        "workspace-write",
		},
	}); err != nil {
		t.Fatal(err)
	}
	var startResponse runtimeWebSocketFrame
	if err := json.Unmarshal(readGatewayRaw(t, conn), &startResponse); err != nil || string(startResponse.ID) != "1" {
		t.Fatalf("thread/start response 异常：err=%v frame=%+v", err, startResponse)
	}

	if err := conn.WriteJSON(map[string]any{
		"id":     2,
		"method": "thread/queue/add",
		"params": map[string]any{
			"threadId":            "thread-new",
			"input":               []any{map[string]any{"type": "text", "text": "实现自动标题"}},
			"clientUserMessageId": "client-main",
		},
	}); err != nil {
		t.Fatal(err)
	}

	var sawQueueResponse bool
	var sawTitleNotification bool
	for range 2 {
		var frame runtimeWebSocketFrame
		if err := json.Unmarshal(readGatewayRaw(t, conn), &frame); err != nil {
			t.Fatal(err)
		}
		if string(frame.ID) == "2" {
			sawQueueResponse = true
		}
		if frame.Method == "thread/name/updated" {
			var params struct {
				ThreadID   string `json:"threadId"`
				ThreadName string `json:"threadName"`
			}
			if err := json.Unmarshal(frame.Params, &params); err != nil {
				t.Fatal(err)
			}
			sawTitleNotification = params.ThreadID == "thread-new" && params.ThreadName == "自动生成标题"
		}
	}
	if !sawQueueResponse || !sawTitleNotification {
		t.Fatalf("移动端应同时收到 queue/add response 和标题通知：queue=%t title=%t", sawQueueResponse, sawTitleNotification)
	}
}

func TestGatewayDropsInternalAutoThreadTitleNotifications(t *testing.T) {
	router := &Router{}
	router.rememberAutoThreadTitleThread("thread-title-internal")
	policy := &appServerGatewayPolicy{router: router, runtimeID: "codex"}
	payload, err := json.Marshal(map[string]any{
		"method": "item/completed",
		"params": map[string]any{
			"threadId": "thread-title-internal",
			"turnId":   "turn-title",
			"item":     map[string]any{"type": "agentMessage", "text": `{"title":"内部标题"}`},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
	if policyErr != nil {
		t.Fatalf("内部标题 notification 应静默丢弃，不能变成策略错误：%+v", policyErr)
	}
	if forward {
		t.Fatal("内部 ephemeral 标题 thread 的事件不能转发到移动端")
	}
}

type autoThreadTitleUpstreamState struct {
	mu                    sync.Mutex
	targetName            string
	agentOutput           string
	readCalls             int
	threadStart           map[string]any
	turnStart             map[string]any
	setTitle              string
	renameAfterGeneration string
}

func newAutoThreadTitleUpstream(
	t *testing.T,
	existingName string,
	agentOutput string,
) (string, *autoThreadTitleUpstreamState) {
	t.Helper()
	state := &autoThreadTitleUpstreamState{
		targetName:  existingName,
		agentOutput: agentOutput,
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		conn, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			var frame runtimeWebSocketFrame
			if err := conn.ReadJSON(&frame); err != nil {
				return
			}
			switch frame.Method {
			case "initialized":
				continue
			case "initialize":
				writeAutoTitleRPCResult(t, conn, frame.ID, map[string]any{
					"userAgent": "codex-cli/0.144.2",
				})
			case "thread/read":
				state.mu.Lock()
				state.readCalls++
				name := state.targetName
				state.mu.Unlock()
				var wireName any
				if name != "" {
					wireName = name
				}
				writeAutoTitleRPCResult(t, conn, frame.ID, map[string]any{
					"thread": map[string]any{
						"id":   "thread-target",
						"name": wireName,
					},
				})
			case "thread/start":
				state.mu.Lock()
				state.threadStart = decodeAutoTitleTestParams(t, frame.Params)
				state.mu.Unlock()
				writeAutoTitleRPCResult(t, conn, frame.ID, map[string]any{
					"thread": map[string]any{"id": "thread-title"},
				})
			case "turn/start":
				state.mu.Lock()
				state.turnStart = decodeAutoTitleTestParams(t, frame.Params)
				output := state.agentOutput
				if state.renameAfterGeneration != "" {
					state.targetName = state.renameAfterGeneration
				}
				state.mu.Unlock()
				// 先于 turn/start response 发 item/completed，验证 RPC 在等待
				// response 时会缓存 notification，而不是静默丢弃。
				writeAutoTitleNotification(t, conn, "item/completed", map[string]any{
					"threadId": "thread-title",
					"turnId":   "turn-title",
					"item": map[string]any{
						"type": "agentMessage",
						"text": output,
					},
				})
				writeAutoTitleRPCResult(t, conn, frame.ID, map[string]any{
					"turn": map[string]any{"id": "turn-title"},
				})
				writeAutoTitleNotification(t, conn, "turn/completed", map[string]any{
					"threadId": "thread-title",
					"turn": map[string]any{
						"id":     "turn-title",
						"status": "completed",
						"items":  []any{},
					},
				})
			case "thread/name/set":
				params := decodeAutoTitleTestParams(t, frame.Params)
				state.mu.Lock()
				state.setTitle, _ = params["name"].(string)
				state.targetName = state.setTitle
				state.mu.Unlock()
				writeAutoTitleRPCResult(t, conn, frame.ID, map[string]any{})
			default:
				t.Errorf("fake app-server 收到未预期方法：%s", frame.Method)
				writeAutoTitleRPCResult(t, conn, frame.ID, map[string]any{})
			}
		}
	}))
	t.Cleanup(server.Close)
	return "ws" + strings.TrimPrefix(server.URL, "http"), state
}

func autoThreadTitleTestRouter(t *testing.T, upstreamURL string) *Router {
	t.Helper()
	return &Router{
		cfg: config.Config{
			AppServer: config.AppServerConfig{
				Transport: "ssh",
				SSHTarget: upstreamURL,
			},
		},
		version:      "test",
		appServerSSH: directWSTestTransport{upstreamURL: upstreamURL},
	}
}

func decodeAutoTitleTestParams(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var params map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.UseNumber()
	if err := decoder.Decode(&params); err != nil {
		t.Errorf("fake app-server params 解码失败：%v", err)
		return nil
	}
	return params
}

func writeAutoTitleRPCResult(t *testing.T, conn *websocket.Conn, id json.RawMessage, result any) {
	t.Helper()
	if err := conn.WriteJSON(map[string]any{"id": id, "result": result}); err != nil {
		t.Errorf("fake app-server 写 response 失败：%v", err)
	}
}

func writeAutoTitleNotification(t *testing.T, conn *websocket.Conn, method string, params any) {
	t.Helper()
	if err := conn.WriteJSON(map[string]any{"method": method, "params": params}); err != nil {
		t.Errorf("fake app-server 写 notification 失败：%v", err)
	}
}

type immediateAutoThreadTitleScheduler struct {
	title string
}

func (s immediateAutoThreadTitleScheduler) Schedule(request autoThreadTitleRequest) {
	if request.Notify != nil {
		request.Notify(request.ThreadID, s.title)
	}
}

func (immediateAutoThreadTitleScheduler) Close() {}

type blockingAutoThreadTitleGenerator struct {
	started   chan string
	release   chan struct{}
	calls     atomic.Int64
	active    atomic.Int64
	maxActive atomic.Int64
}

func (g *blockingAutoThreadTitleGenerator) GenerateAndSet(
	ctx context.Context,
	request autoThreadTitleRequest,
) (string, bool, error) {
	g.calls.Add(1)
	active := g.active.Add(1)
	defer g.active.Add(-1)
	for {
		max := g.maxActive.Load()
		if active <= max || g.maxActive.CompareAndSwap(max, active) {
			break
		}
	}
	g.started <- request.ThreadID
	select {
	case <-g.release:
		return "测试标题", true, nil
	case <-ctx.Done():
		return "", false, ctx.Err()
	}
}

func receiveString(t *testing.T, values <-chan string) string {
	t.Helper()
	select {
	case value := <-values:
		return value
	case <-time.After(time.Second):
		t.Fatal("等待异步标题测试结果超时")
		return ""
	}
}
