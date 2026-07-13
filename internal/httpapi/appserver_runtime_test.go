package httpapi

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestCodexAppServerRuntimeListSessionsMapsThreadList(t *testing.T) {
	registry, project := appServerRuntimeFixture(t)
	fake := &fakeAppServerRPC{}
	fake.handler = func(method string, params map[string]any, result any) error {
		switch method {
		case "account/rateLimits/read":
			*(result.(*map[string]any)) = map[string]any{
				"rateLimits": map[string]any{
					"limitId":   "codex",
					"limitName": "Codex",
					"primary": map[string]any{
						"usedPercent": 42.5,
						"resetsAt":    1_780_301_000,
					},
					"credits": map[string]any{
						"hasCredits": true,
						"unlimited":  false,
					},
				},
			}
		case "thread/list":
			if params["cwd"] != project.RealPath {
				t.Fatalf("thread/list 必须使用 allowlist cwd 过滤：%v", params)
			}
			*(result.(*appServerThreadListResponse)) = appServerThreadListResponse{
				Data: []appServerThread{{
					ID:        "thread-1",
					Preview:   "hello",
					CWD:       project.RealPath,
					CreatedAt: 1_780_300_000,
					UpdatedAt: 1_780_300_010,
					Status:    appServerThreadStatus{Type: "idle"},
				}},
			}
		default:
			t.Fatalf("期望调用 thread/list 或 account/rateLimits/read，实际 %s", method)
		}
		return nil
	}

	runtime := NewCodexAppServerRuntime(registry, fake)
	page, err := runtime.ListSessions(context.Background(), "demo", 20, sessionPageCursor{}, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Sessions) != 1 {
		t.Fatalf("期望 1 条 session，got=%+v", page)
	}
	got := page.Sessions[0]
	if got.ID != "codex_thread-1" || got.ProjectID != "demo" || got.HistoryThreadID != "thread-1" {
		t.Fatalf("thread/list 映射异常：%+v", got)
	}
	if got.Title != "hello" || got.Status != "running" {
		t.Fatalf("session title/status 映射异常：%+v", got)
	}
	if got.Preview != "hello" || got.RateLimit == nil || got.RateLimit.LimitID != "codex" {
		t.Fatalf("session row 应包含 preview/rate-limit 摘要：%+v", got)
	}
}

func TestCodexAppServerRuntimeProjectsThreadContextForStatusSidebar(t *testing.T) {
	registry, project := appServerRuntimeFixture(t)
	fake := &fakeAppServerRPC{}
	fake.handler = func(method string, params map[string]any, result any) error {
		switch method {
		case "account/rateLimits/read":
			*(result.(*map[string]any)) = map[string]any{}
		case "thread/list":
			*(result.(*appServerThreadListResponse)) = appServerThreadListResponse{
				Data: []appServerThread{{
					ID:            "thread-context",
					Preview:       "context",
					CWD:           project.RealPath,
					ModelProvider: "openai",
					Source:        map[string]any{"custom": "desktop"},
					ThreadSource:  "user",
					GitInfo:       &appServerGitInfo{SHA: "abcdef1234567890", Branch: "codex/status-sidebar", OriginURL: "https://example.test/repo.git"},
					CreatedAt:     1_780_300_000,
					UpdatedAt:     1_780_300_010,
					Status:        appServerThreadStatus{Type: "active", ActiveFlags: []string{"waitingOnApproval"}},
					Turns: []appServerTurn{{
						ID:     "turn-context",
						Status: "inProgress",
						Items: []appServerThreadItem{{
							Type:    "commandExecution",
							ID:      "cmd-context",
							Command: "go test ./...",
							CWD:     project.RealPath,
							Status:  "running",
						}},
					}},
				}},
			}
		default:
			t.Fatalf("不期望调用 method=%s", method)
		}
		return nil
	}

	runtime := NewCodexAppServerRuntime(registry, fake)
	page, err := runtime.ListSessions(context.Background(), "demo", 20, sessionPageCursor{}, false)
	if err != nil {
		t.Fatal(err)
	}
	got := page.Sessions[0]
	if got.Status != "waiting_for_approval" {
		t.Fatalf("activeFlags 应投影成等待审批状态：%+v", got)
	}
	if got.Context == nil {
		t.Fatal("session row 应携带右侧栏 context")
	}
	if got.Context.Status == nil || got.Context.Status.Type != "active" || !containsString(got.Context.Status.ActiveFlags, "waitingOnApproval") {
		t.Fatalf("context status 应保留 app-server activeFlags：%+v", got.Context.Status)
	}
	if got.Context.Environment == nil || got.Context.Environment.CWD != project.RealPath || got.Context.Environment.Provider != "openai" {
		t.Fatalf("context environment 异常：%+v", got.Context.Environment)
	}
	if got.Context.Git == nil || got.Context.Git.Branch != "codex/status-sidebar" {
		t.Fatalf("context git 异常：%+v", got.Context.Git)
	}
	if len(got.Context.Tasks) != 1 || got.Context.Tasks[0].Kind != "command" || got.Context.Tasks[0].Title != "go test ./..." {
		t.Fatalf("context tasks 异常：%+v", got.Context.Tasks)
	}
	if len(got.Context.Sources) < 2 {
		t.Fatalf("context sources 应包含 session/thread 来源：%+v", got.Context.Sources)
	}
}

func TestCodexAppServerRuntimeStatusNotificationIncludesContextActiveFlags(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})

	events := runtime.eventsFromNotification(appserver.Notification{
		Method: "thread/status/changed",
		Params: []byte(`{"threadId":"thread-status","status":{"type":"active","activeFlags":["waitingOnUserInput"]}}`),
	})
	if len(events) != 1 {
		t.Fatalf("期望 1 个 status event，got=%+v", events)
	}
	event := events[0]
	if event.Type != "session_status" || event.Status != "waiting_for_input" {
		t.Fatalf("status event 映射异常：%+v", event)
	}
	if event.Context == nil || event.Context.Status == nil || !containsString(event.Context.Status.ActiveFlags, "waitingOnUserInput") {
		t.Fatalf("status event 应携带 context activeFlags：%+v", event.Context)
	}
	if event.Row == nil || event.Row.Context == nil || event.Row.Context.Status == nil {
		t.Fatalf("status event 应携带含 context 的 session row：%+v", event.Row)
	}
}

func TestCodexAppServerRuntimeItemStartedNotificationIncludesContextTask(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})

	events := runtime.eventsFromNotification(appserver.Notification{
		Method: "item/started",
		Params: []byte(`{"threadId":"thread-task","turnId":"turn-task","item":{"type":"commandExecution","id":"cmd-task","command":"go test ./internal/httpapi","cwd":"/tmp/demo","status":"inProgress"}}`),
	})
	if len(events) != 1 {
		t.Fatalf("期望 1 个 item/started context event，got=%+v", events)
	}
	event := events[0]
	if event.Type != "session_context" || event.Context == nil || len(event.Context.Tasks) != 1 {
		t.Fatalf("item/started 应映射为 session_context task：%+v", event)
	}
	task := event.Context.Tasks[0]
	if task.Kind != "command" || task.Title != "go test ./internal/httpapi" || task.Status != "inProgress" {
		t.Fatalf("context task 应保留命令和 inProgress 状态：%+v", task)
	}
	if event.Row == nil || event.Row.Context == nil || len(event.Row.Context.Tasks) != 1 {
		t.Fatalf("item/started 应更新 session row context：%+v", event.Row)
	}
}

func TestCodexAppServerRuntimeListSessionsReturnsUnknownProjectError(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})

	if _, err := runtime.ListSessions(context.Background(), "missing", 20, sessionPageCursor{}, false); err == nil {
		t.Fatal("非法 project_id 不能被吞成空列表")
	}
}

func TestCodexAppServerRuntimeCreateSessionStartsThreadWithAllowlistedCWD(t *testing.T) {
	registry, project := appServerRuntimeFixture(t)
	fake := &fakeAppServerRPC{}
	fake.handler = func(method string, params map[string]any, result any) error {
		switch method {
		case "thread/start":
			if params["cwd"] != project.RealPath {
				t.Fatalf("thread/start 只能使用 allowlist cwd：%v", params)
			}
			if _, ok := params["runtimeWorkspaceRoots"]; ok {
				t.Fatalf("thread/start 不能发送需要 experimentalApi 的 runtimeWorkspaceRoots：%v", params)
			}
			if params["approvalPolicy"] != "on-request" || params["sandbox"] != "danger-full-access" {
				t.Fatalf("移动端入口必须使用用户批准 + 完全访问默认值：%v", params)
			}
			if _, ok := params["model"]; ok {
				t.Fatalf("thread/start 默认模型必须交给 app-server rollout，不应发送 model：%v", params)
			}
			*(result.(*appServerThreadEnvelope)) = appServerThreadEnvelope{Thread: appServerThread{
				ID:        "thread-new",
				Preview:   "first prompt",
				CWD:       project.RealPath,
				CreatedAt: 1_780_300_000,
				UpdatedAt: 1_780_300_000,
				Status:    appServerThreadStatus{Type: "active"},
			}}
		case "turn/start":
			if params["threadId"] != "thread-new" || params["cwd"] != project.RealPath {
				t.Fatalf("turn/start thread/cwd 异常：%v", params)
			}
			input := params["input"].([]any)
			text := input[0].(map[string]any)["text"]
			if text != "first prompt" || params["clientUserMessageId"] != "client-1" {
				t.Fatalf("turn/start 输入或 client id 丢失：%v", params)
			}
			*(result.(*appServerTurnEnvelope)) = appServerTurnEnvelope{Turn: appServerTurn{ID: "turn-1", Status: "inProgress"}}
		default:
			t.Fatalf("不期望调用 method=%s", method)
		}
		return nil
	}

	runtime := NewCodexAppServerRuntime(registry, fake)
	result, err := runtime.CreateSession(context.Background(), RuntimeCreateRequest{
		Project:         project,
		Prompt:          "first prompt",
		ClientMessageID: "client-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Snapshot.ID != "codex_thread-new" || result.Snapshot.ProjectID != "demo" {
		t.Fatalf("create session snapshot 异常：%+v", result.Snapshot)
	}
	if result.Snapshot.ActiveTurnID != "turn-1" {
		t.Fatalf("create session 应返回 active_turn_id：%+v", result.Snapshot)
	}
	if got := fake.methods(); len(got) != 2 || got[0] != "thread/start" || got[1] != "turn/start" {
		t.Fatalf("调用顺序异常：%v", got)
	}
}

func TestCodexAppServerRuntimeResumeSessionUsesThreadResumeThenTurnStart(t *testing.T) {
	registry, project := appServerRuntimeFixture(t)
	fake := &fakeAppServerRPC{}
	fake.handler = func(method string, params map[string]any, result any) error {
		switch method {
		case "thread/resume":
			if params["threadId"] != "thread-old" || params["cwd"] != project.RealPath {
				t.Fatalf("thread/resume 参数异常：%v", params)
			}
			if _, ok := params["model"]; ok {
				t.Fatalf("thread/resume 默认模型必须交给 app-server rollout，不应发送 model：%v", params)
			}
			if params["excludeTurns"] != true || params["approvalPolicy"] != "on-request" || params["sandbox"] != "danger-full-access" {
				t.Fatalf("thread/resume 必须保留安全默认值和 excludeTurns：%v", params)
			}
			*(result.(*appServerThreadEnvelope)) = appServerThreadEnvelope{Thread: appServerThread{
				ID:        "thread-old",
				Name:      "resumed",
				CWD:       project.RealPath,
				CreatedAt: 1_780_300_000,
				UpdatedAt: 1_780_300_020,
				Status:    appServerThreadStatus{Type: "idle"},
			}}
		case "turn/start":
			if params["threadId"] != "thread-old" {
				t.Fatalf("resume 后 prompt 必须发到同一 thread：%v", params)
			}
			if _, ok := params["model"]; ok {
				t.Fatalf("turn/start 默认模型必须交给 app-server rollout，不应发送 model：%v", params)
			}
			if params["effort"] != "xhigh" || params["approvalPolicy"] != "on-request" {
				t.Fatalf("turn/start 必须保留默认推理强度和审批策略：%v", params)
			}
			*(result.(*appServerTurnEnvelope)) = appServerTurnEnvelope{Turn: appServerTurn{ID: "turn-resume", Status: "inProgress"}}
		default:
			t.Fatalf("不期望调用 method=%s", method)
		}
		return nil
	}

	runtime := NewCodexAppServerRuntime(registry, fake)
	result, err := runtime.CreateSession(context.Background(), RuntimeCreateRequest{
		Project:  project,
		ResumeID: "thread-old",
		Prompt:   "continue",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Snapshot.ID != "codex_thread-old" || result.Snapshot.Title != "resumed" {
		t.Fatalf("resume snapshot 异常：%+v", result.Snapshot)
	}
	if got := fake.methods(); len(got) != 2 || got[0] != "thread/resume" || got[1] != "turn/start" {
		t.Fatalf("调用顺序异常：%v", got)
	}
}

func TestCodexAppServerRuntimeMessagesPaginatesThreadReadTurns(t *testing.T) {
	registry, project := appServerRuntimeFixture(t)
	fake := &fakeAppServerRPC{}
	startedAt := int64(1_780_300_000)
	completedAt := int64(1_780_300_002)
	fake.handler = func(method string, params map[string]any, result any) error {
		if method != "thread/read" || params["threadId"] != "thread-msg" || params["includeTurns"] != true {
			t.Fatalf("messages 必须通过 thread/read(includeTurns=true) 读取：method=%s params=%v", method, params)
		}
		*(result.(*appServerThreadEnvelope)) = appServerThreadEnvelope{Thread: appServerThread{
			ID:        "thread-msg",
			CWD:       project.RealPath,
			CreatedAt: startedAt,
			UpdatedAt: completedAt,
			Status:    appServerThreadStatus{Type: "idle"},
			Turns: []appServerTurn{{
				ID:          "turn-msg",
				Status:      "completed",
				StartedAt:   &startedAt,
				CompletedAt: &completedAt,
				Items: []appServerThreadItem{
					{Type: "userMessage", ID: "user-1", ClientID: "client-1", Content: []appServerUserInput{{Type: "text", Text: "hi"}}},
					{Type: "agentMessage", ID: "assistant-1", Text: "hello"},
				},
			}},
		}}
		return nil
	}

	runtime := NewCodexAppServerRuntime(registry, fake)
	first, err := runtime.SessionMessages(context.Background(), "codex_thread-msg", "", 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Messages) != 1 || first.Messages[0].Role != "assistant" || first.Messages[0].Content != "hello" {
		t.Fatalf("第一页应返回最近 assistant 消息：%+v", first)
	}
	if !first.HasMoreBefore || first.PreviousCursor == "" {
		t.Fatalf("第一页应给出 previous cursor：%+v", first)
	}

	second, err := runtime.SessionMessages(context.Background(), "codex_thread-msg", first.PreviousCursor, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Messages) != 1 || second.Messages[0].Role != "user" || second.Messages[0].ClientMessageID != "client-1" {
		t.Fatalf("第二页应返回更早 user 消息并保留 client id：%+v", second)
	}
}

func TestCodexAppServerRuntimeTokenUsageNotificationUpdatesSessionRow(t *testing.T) {
	registry, project := appServerRuntimeFixture(t)
	fake := &fakeAppServerRPC{notifications: make(chan appserver.Notification, 4)}
	fake.handler = func(method string, params map[string]any, result any) error {
		switch method {
		case "account/rateLimits/read":
			*(result.(*map[string]any)) = map[string]any{
				"rateLimits": map[string]any{
					"limitId": "codex",
					"primary": map[string]any{"usedPercent": 12.5},
				},
			}
		case "thread/list":
			*(result.(*appServerThreadListResponse)) = appServerThreadListResponse{
				Data: []appServerThread{{
					ID:        "thread-usage",
					Preview:   "usage",
					CWD:       project.RealPath,
					CreatedAt: 1_780_300_000,
					UpdatedAt: 1_780_300_000,
					Status:    appServerThreadStatus{Type: "active"},
				}},
			}
		case "thread/read":
			*(result.(*appServerThreadEnvelope)) = appServerThreadEnvelope{Thread: appServerThread{
				ID:        "thread-usage",
				Preview:   "usage",
				CWD:       project.RealPath,
				CreatedAt: 1_780_300_000,
				UpdatedAt: 1_780_300_010,
				Status:    appServerThreadStatus{Type: "active"},
			}}
		default:
			t.Fatalf("不期望调用 method=%s params=%v", method, params)
		}
		return nil
	}

	runtime := NewCodexAppServerRuntime(registry, fake)
	if _, err := runtime.ListSessions(context.Background(), "demo", 20, sessionPageCursor{}, false); err != nil {
		t.Fatal(err)
	}
	events, detach, err := runtime.Subscribe(context.Background(), "codex_thread-usage")
	if err != nil {
		t.Fatal(err)
	}
	defer detach()

	fake.notifications <- appserver.Notification{
		Method: "thread/tokenUsage/updated",
		Params: []byte(`{"threadId":"thread-usage","turnId":"turn-usage","tokenUsage":{"total":{"totalTokens":123,"inputTokens":45,"outputTokens":78,"cachedInputTokens":0,"reasoningOutputTokens":0},"last":{"totalTokens":123,"inputTokens":45,"outputTokens":78,"cachedInputTokens":0,"reasoningOutputTokens":0},"modelContextWindow":200000}}`),
	}

	select {
	case event := <-events:
		if event.Type != "session_status" || event.Usage == nil || event.Usage.TotalTokens != 123 {
			t.Fatalf("usage notification 应转成 session_status usage：%+v", event)
		}
		if event.Row == nil || event.Row.Usage == nil || event.Row.RateLimit == nil {
			t.Fatalf("usage event 应携带可归并的 session row：%+v", event.Row)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("未收到 token usage 事件")
	}

	detail, err := runtime.SessionDetail(context.Background(), "codex_thread-usage", 0)
	if err != nil {
		t.Fatal(err)
	}
	if detail.Snapshot.Usage == nil || detail.Snapshot.Usage.OutputTokens != 78 || detail.Snapshot.RateLimit == nil {
		t.Fatalf("detail snapshot 应保留 usage/rate-limit：%+v", detail.Snapshot)
	}
}

func TestCodexAppServerRuntimeRejectsDisallowedMethods(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	fake := &fakeAppServerRPC{}
	runtime := NewCodexAppServerRuntime(registry, fake)

	disallowed := []string{
		"fs/readFile",
		"command/exec",
		"process/kill",
		"config/write",
		"plugin/install",
		"marketplace/list",
		"remoteControl/start",
		"thread/shellCommand",
	}
	for _, method := range disallowed {
		if err := runtime.call(context.Background(), method, map[string]any{"path": "/etc/passwd"}, nil); err == nil {
			t.Fatalf("runtime 必须拒绝高风险 method=%s", method)
		}
	}
	if len(fake.calls) != 0 {
		t.Fatalf("被拒绝方法不能透传到 app-server：%+v", fake.calls)
	}

	allowed := []string{
		"thread/list",
		"thread/start",
		"thread/resume",
		"thread/read",
		"turn/start",
		"turn/interrupt",
		"account/rateLimits/read",
	}
	for _, method := range allowed {
		if err := runtime.call(context.Background(), method, map[string]any{}, nil); err != nil {
			t.Fatalf("allowlist method=%s 不应被拒绝：%v", method, err)
		}
	}
	if got := fake.methods(); len(got) != len(allowed) {
		t.Fatalf("允许方法应全部透传，got=%v", got)
	}
}

func TestCodexAppServerRuntimeSafeParamsUseFullAccessWithApproval(t *testing.T) {
	_, project := appServerRuntimeFixture(t)

	start := safeThreadStartParams(project)
	if start["approvalPolicy"] != "on-request" || start["sandbox"] != "danger-full-access" {
		t.Fatalf("thread/start 必须使用用户批准 + 完全访问默认值：%v", start)
	}
	if start["cwd"] != project.RealPath {
		t.Fatalf("thread/start 必须使用 allowlist cwd：%v", start)
	}
	if _, ok := start["model"]; ok {
		t.Fatalf("thread/start 默认模型必须交给 app-server rollout，不应发送 model：%v", start)
	}
	if _, ok := start["runtimeWorkspaceRoots"]; ok {
		t.Fatalf("thread/start 不能发送需要 experimentalApi 的 runtimeWorkspaceRoots：%v", start)
	}

	turn := safeTurnStartParams("thread-1", project, "hello", "client-1")
	if turn["approvalPolicy"] == "never" {
		t.Fatalf("turn/start 不能暴露 approvalPolicy=never：%v", turn)
	}
	if turn["effort"] != "xhigh" {
		t.Fatalf("turn/start 必须默认使用超高思考：%v", turn)
	}
	if _, ok := turn["model"]; ok {
		t.Fatalf("turn/start 默认模型必须交给 app-server rollout，不应发送 model：%v", turn)
	}
	sandbox, ok := turn["sandboxPolicy"].(map[string]any)
	if !ok {
		t.Fatalf("turn/start 必须包含 sandboxPolicy：%v", turn)
	}
	if sandbox["type"] != "dangerFullAccess" || sandbox["networkAccess"] != false {
		t.Fatalf("turn/start sandbox 必须使用完全访问且默认禁网：%v", sandbox)
	}
	if _, ok := sandbox["writableRoots"]; ok {
		t.Fatalf("dangerFullAccess 不应携带 writableRoots：%v", sandbox)
	}
}

func TestCodexAppServerRuntimeApprovalRequestBroadcastsAndDeclines(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	fake := &fakeAppServerRPC{notifications: make(chan appserver.Notification, 1)}
	runtime := NewCodexAppServerRuntime(registry, fake)
	events, detach, err := runtime.Subscribe(context.Background(), "codex_thread-approval")
	if err != nil {
		t.Fatal(err)
	}
	defer detach()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	resultCh := make(chan any, 1)
	errCh := make(chan *appserver.RPCError, 1)
	go func() {
		result, rpcErr := runtime.HandleServerRequest(ctx, appserver.ServerRequest{
			Method: "item/commandExecution/requestApproval",
			Params: []byte(`{"threadId":"thread-approval","turnId":"turn-1","itemId":"cmd-1","command":"rm -rf tmp","reason":"needs write"}`),
		})
		resultCh <- result
		errCh <- rpcErr
	}()

	select {
	case event := <-events:
		if event.Type != "approval_request" || event.SessionID != "codex_thread-approval" || event.TurnID != "turn-1" || event.ItemID != "cmd-1" {
			t.Fatalf("approval event 元数据异常：%+v", event)
		}
		if event.Approval["kind"] != "command" || !strings.Contains(event.Approval["title"].(string), "rm -rf tmp") {
			t.Fatalf("approval payload 异常：%+v", event.Approval)
		}
		if err := runtime.ResolveApproval("codex_thread-approval", "cmd-1", "decline", "no"); err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("未收到 approval_request 事件")
	}
	var rpcErr *appserver.RPCError
	select {
	case rpcErr = <-errCh:
	case <-time.After(2 * time.Second):
		t.Fatal("审批决定后 HandleServerRequest 未返回")
	}
	if rpcErr != nil {
		t.Fatal(rpcErr)
	}
	result := readApprovalResult(t, resultCh).(map[string]any)
	if decision := result["decision"]; decision != "decline" {
		t.Fatalf("新版审批默认应 decline，got=%v", result)
	}
	if _, hasMessage := result["message"]; hasMessage {
		t.Fatalf("新版审批默认响应必须匹配 app-server 协议，不能携带额外 message 字段：%v", result)
	}
}

func TestCodexAppServerRuntimeApprovalTimeoutFailsClosed(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	result, rpcErr := runtime.HandleServerRequest(ctx, appserver.ServerRequest{
		Method: "item/fileChange/requestApproval",
		Params: []byte(`{"threadId":"thread-timeout","turnId":"turn-1","itemId":"patch-1"}`),
	})
	if rpcErr != nil {
		t.Fatal(rpcErr)
	}
	typed := result.(map[string]any)
	if typed["decision"] != "decline" {
		t.Fatalf("审批超时必须 fail-closed decline：%+v", typed)
	}
	if _, hasMessage := typed["message"]; hasMessage {
		t.Fatalf("超时拒绝响应不能携带 app-server 协议外字段：%+v", typed)
	}
}

func TestCodexAppServerRuntimePermissionsApprovalDeclinesWithEmptyGrant(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	resultCh := make(chan any, 1)
	errCh := make(chan *appserver.RPCError, 1)
	go func() {
		result, rpcErr := runtime.HandleServerRequest(ctx, appserver.ServerRequest{
			Method: "item/permissions/requestApproval",
			Params: []byte(`{"threadId":"thread-permission","turnId":"turn-1","itemId":"perm-1","reason":"need more access"}`),
		})
		resultCh <- result
		errCh <- rpcErr
	}()
	waitFor(t, func() bool {
		return runtime.ResolveApproval("codex_thread-permission", "perm-1", "accept", "") == nil
	}, "等待 permissions approval 注册")
	var rpcErr *appserver.RPCError
	select {
	case rpcErr = <-errCh:
	case <-time.After(2 * time.Second):
		t.Fatal("permissions 审批决定后 HandleServerRequest 未返回")
	}
	if rpcErr != nil {
		t.Fatal(rpcErr)
	}
	typed := readApprovalResult(t, resultCh).(map[string]any)
	if _, ok := typed["permissions"].(map[string]any); !ok || typed["scope"] != "turn" {
		t.Fatalf("permissions 默认拒绝应返回空权限和 turn scope：%+v", typed)
	}
	if _, hasDecision := typed["decision"]; hasDecision {
		t.Fatalf("permissions 响应不能包含 decision 字段：%+v", typed)
	}
}

func TestCodexAppServerRuntimeLegacyApprovalDeclinesWithDenied(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	resultCh := make(chan any, 1)
	errCh := make(chan *appserver.RPCError, 1)
	go func() {
		result, rpcErr := runtime.HandleServerRequest(ctx, appserver.ServerRequest{
			Method: "execCommandApproval",
			Params: []byte(`{"conversationId":"thread-legacy","callId":"call-1","command":["rm","tmp"]}`),
		})
		resultCh <- result
		errCh <- rpcErr
	}()
	waitFor(t, func() bool {
		return runtime.ResolveApproval("codex_thread-legacy", "call-1", "decline", "") == nil
	}, "等待 legacy approval 注册")
	var rpcErr *appserver.RPCError
	select {
	case rpcErr = <-errCh:
	case <-time.After(2 * time.Second):
		t.Fatal("legacy 审批决定后 HandleServerRequest 未返回")
	}
	if rpcErr != nil {
		t.Fatal(rpcErr)
	}
	if result := readApprovalResult(t, resultCh); result.(map[string]any)["decision"] != "denied" {
		t.Fatalf("旧审批协议默认应 denied，got=%v", result)
	}
}

func TestCodexAppServerRuntimeMapsCommandExecutionOutputDelta(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})

	events := runtime.eventsFromNotification(appserver.Notification{
		Method: "item/commandExecution/outputDelta",
		Params: []byte(`{"threadId":"thread-log","turnId":"turn-1","itemId":"cmd-1","delta":"go test output\n"}`),
	})
	if len(events) != 1 || events[0].Type != "log_delta" || events[0].Data != "go test output\n" {
		t.Fatalf("命令输出应映射为 log_delta：%+v", events)
	}
}

func TestCodexAppServerRuntimeMapsCompletedAgentMessageContentAndCommentary(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})

	events := runtime.eventsFromNotification(appserver.Notification{
		Method: "item/completed",
		Params: []byte(`{"threadId":"thread-complete","turnId":"turn-1","item":{"type":"agentMessage","id":"assistant-1","content":"final from content"}}`),
	})
	if len(events) != 1 || events[0].Type != "message_completed" || events[0].Message == nil {
		t.Fatalf("agentMessage content 应映射为 message_completed：%+v", events)
	}
	if events[0].Message.Content != "final from content" || events[0].Message.Role != "assistant" || events[0].Message.Kind != "message" {
		t.Fatalf("assistant 完整消息字段异常：%+v", events[0].Message)
	}

	commentary := runtime.eventsFromNotification(appserver.Notification{
		Method: "item/completed",
		Params: []byte(`{"threadId":"thread-complete","turnId":"turn-1","item":{"type":"agentMessage","id":"commentary-1","text":"我先检查上下文。","phase":"commentary"}}`),
	})
	if len(commentary) != 1 || commentary[0].Type != "message_completed" || commentary[0].Message == nil {
		t.Fatalf("commentary agentMessage 应映射为 message_completed：%+v", commentary)
	}
	if commentary[0].Message.Role != "system" || commentary[0].Message.Kind != "reasoning_summary" {
		t.Fatalf("commentary 应作为 system reasoning summary 展示：%+v", commentary[0].Message)
	}
}

func TestCodexAppServerRuntimeDiffUpdatedUsesChangesArray(t *testing.T) {
	registry, _ := appServerRuntimeFixture(t)
	runtime := NewCodexAppServerRuntime(registry, &fakeAppServerRPC{})

	events := runtime.eventsFromNotification(appserver.Notification{
		Method: "item/fileChange/patchUpdated",
		Params: []byte(`{"threadId":"thread-diff","turnId":"turn-1","itemId":"patch-1","changes":[{"path":"internal/httpapi/appserver_runtime.go","kind":"update","diff":"---"}]}`),
	})
	if len(events) != 1 || events[0].Type != "diff_updated" {
		t.Fatalf("patchUpdated 应映射为 diff_updated：%+v", events)
	}
	if events[0].Diff["path"] != "internal/httpapi/appserver_runtime.go" || events[0].Diff["status"] != "update" {
		t.Fatalf("diff_updated 应保留真实文件路径和变更类型：%+v", events[0].Diff)
	}
	files, ok := events[0].Diff["files"].([]map[string]any)
	if !ok || len(files) != 1 {
		t.Fatalf("diff_updated 应包含 files 摘要：%+v", events[0].Diff)
	}
}

func readApprovalResult(t *testing.T, resultCh <-chan any) any {
	t.Helper()
	select {
	case result := <-resultCh:
		return result
	case <-time.After(2 * time.Second):
		t.Fatal("未收到审批处理结果")
		return nil
	}
}

func appServerRuntimeFixture(t *testing.T) (*projects.Registry, projects.Project) {
	t.Helper()
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: projectDir}})
	if err != nil {
		t.Fatal(err)
	}
	project, ok := registry.Get("demo")
	if !ok {
		t.Fatal("测试项目不存在")
	}
	return registry, project
}

type fakeAppServerCall struct {
	Method string
	Params map[string]any
}

type fakeAppServerRPC struct {
	calls         []fakeAppServerCall
	notifications chan appserver.Notification
	handler       func(method string, params map[string]any, result any) error
}

func (f *fakeAppServerRPC) Call(ctx context.Context, method string, params any, result any) error {
	paramMap := map[string]any{}
	if params != nil {
		data, err := json.Marshal(params)
		if err != nil {
			return err
		}
		if err := json.Unmarshal(data, &paramMap); err != nil {
			return err
		}
	}
	f.calls = append(f.calls, fakeAppServerCall{Method: method, Params: paramMap})
	if f.handler != nil {
		return f.handler(method, paramMap, result)
	}
	return nil
}

func (f *fakeAppServerRPC) methods() []string {
	out := make([]string, 0, len(f.calls))
	for _, call := range f.calls {
		out = append(out, call.Method)
	}
	return out
}

func (f *fakeAppServerRPC) Notifications() <-chan appserver.Notification {
	return f.notifications
}

func TestUnixTimeUsesUTC(t *testing.T) {
	if got := unixTime(1).Location(); got != time.UTC {
		t.Fatalf("unixTime 应返回 UTC 时间，got=%v", got)
	}
}

func waitFor(t *testing.T, condition func() bool, reason string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal(reason)
}
