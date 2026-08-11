package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

func TestAuthorizedProjectsByGitCommonDirUsesUniquePrimaryProject(t *testing.T) {
	browseRoot := t.TempDir()
	projectDir := filepath.Join(browseRoot, "repository")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, projectDir, "init")
	runGitTestCommand(t, projectDir, "config", "user.email", "mim24@example.invalid")
	runGitTestCommand(t, projectDir, "config", "user.name", "MIM-24")
	if err := os.WriteFile(filepath.Join(projectDir, "README.md"), []byte("mim24\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, projectDir, "add", "README.md")
	runGitTestCommand(t, projectDir, "commit", "-m", "initial")

	configuredWorktreeA := filepath.Join(browseRoot, "configured-worktree-a")
	configuredWorktreeB := filepath.Join(browseRoot, "configured-worktree-b")
	externalWorktree := filepath.Join(browseRoot, "external-worktree")
	for index, worktree := range []string{configuredWorktreeA, configuredWorktreeB, externalWorktree} {
		runGitTestCommand(t, projectDir, "worktree", "add", "-b", fmt.Sprintf("mim24-%d", index), worktree)
	}
	t.Cleanup(func() {
		for _, worktree := range []string{configuredWorktreeA, configuredWorktreeB, externalWorktree} {
			_ = exec.Command("git", "-C", projectDir, "worktree", "remove", "--force", worktree).Run()
		}
	})

	newPolicy := func(t *testing.T, configured []config.ProjectConfig) *appServerGatewayPolicy {
		t.Helper()
		registry, err := projects.NewRegistry(configured)
		if err != nil {
			t.Fatal(err)
		}
		return &appServerGatewayPolicy{
			router: &Router{
				cfg:      config.Config{BrowseRoots: []string{browseRoot}},
				projects: registry,
			},
		}
	}
	projectConfigs := []config.ProjectConfig{
		{ID: "root", Name: "Root", Path: projectDir},
		{ID: "worktree-a", Name: "Worktree A", Path: configuredWorktreeA},
		{ID: "worktree-b", Name: "Worktree B", Path: configuredWorktreeB},
	}
	policy := newPolicy(t, projectConfigs)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	projectByCommonDir := policy.authorizedProjectsByGitCommonDir(ctx)
	got, ok := projectForGlobalThread(ctx, gatewayScope{
		id:       workspaceIDForRealPath(externalWorktree),
		realPath: externalWorktree,
		browse:   true,
	}, projectByCommonDir)
	if !ok || got.ID != "root" {
		t.Fatalf("同仓多个 Project 必须稳定映射到唯一主工作树项目，got=%+v ok=%v", got, ok)
	}

	t.Run("multiple worktrees without primary fail closed", func(t *testing.T) {
		ambiguous := newPolicy(t, projectConfigs[1:])
		if got := ambiguous.authorizedProjectsByGitCommonDir(ctx); len(got) != 0 {
			t.Fatalf("缺少主工作树时不得猜测 Project 归属：%+v", got)
		}
	})
	t.Run("duplicate primary project IDs fail closed", func(t *testing.T) {
		duplicate := newPolicy(t, []config.ProjectConfig{
			{ID: "root-a", Name: "Root A", Path: projectDir},
			{ID: "root-b", Name: "Root B", Path: projectDir},
			projectConfigs[1],
		})
		if got := duplicate.authorizedProjectsByGitCommonDir(ctx); len(got) != 0 {
			t.Fatalf("同一路径重复配置为多个 Project 时不得猜测归属：%+v", got)
		}
	})
}

func TestAppServerGatewayGlobalDiscoveryFiltersByRepositoryAndUsesOpaquePaging(t *testing.T) {
	browseRoot := t.TempDir()
	var projectDir string
	var externalWorktree string
	var secondExternalWorktree string
	var symlinkedWorktree string
	var otherRepo string
	var deletedWorktree string
	var listPage atomic.Int64

	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params map[string]any  `json:"params"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("fake upstream 收到无效 JSON：%v", err)
			return
		}
		switch frame.Method {
		case "thread/list":
			if listPage.Add(1) == 1 {
				_ = conn.WriteJSON(map[string]any{
					"jsonrpc": "2.0",
					"id":      json.RawMessage(frame.ID),
					"result": map[string]any{
						"data": []any{
							map[string]any{
								"id": "thread-root", "cwd": projectDir, "name": "Root",
								"canAcceptDirectInput": true,
							},
							map[string]any{
								"id": "thread-root-child", "cwd": projectDir, "name": "Root child",
								"parentThreadId": "thread-root", "canAcceptDirectInput": true,
							},
							map[string]any{
								"id": "thread-external", "cwd": externalWorktree, "name": "External",
								"parentThreadId": "thread-root", "agentNickname": "worker-a",
								"agentRole": "worker", "sessionId": "session-a",
								"canAcceptDirectInput": true,
							},
							map[string]any{
								"id": "thread-symlink", "cwd": symlinkedWorktree, "name": "Symlink",
							},
							map[string]any{
								"id": "thread-second-worktree", "cwd": secondExternalWorktree, "name": "Second",
							},
							map[string]any{"id": "thread-other", "cwd": otherRepo, "name": "Other repo"},
							map[string]any{"id": "thread-deleted", "cwd": deletedWorktree, "name": "Deleted"},
							map[string]any{"id": "thread-relative", "cwd": "relative/path", "name": "Relative"},
						},
						"nextCursor": "upstream-secret-cursor",
						"private":    "must-not-pass-through",
					},
				})
			} else {
				if got, _ := frame.Params["cursor"].(string); got != "upstream-secret-cursor" {
					t.Errorf("gateway 必须把连接级 opaque cursor 还原为 upstream cursor，got=%q", got)
				}
				_ = conn.WriteJSON(map[string]any{
					"jsonrpc": "2.0",
					"id":      json.RawMessage(frame.ID),
					"result": map[string]any{
						"data":       []any{},
						"nextCursor": nil,
					},
				})
			}
		case "thread/read":
			_ = conn.WriteJSON(map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(frame.ID),
				"result": map[string]any{
					"thread": map[string]any{
						"id": "thread-external", "cwd": externalWorktree,
						"parentThreadId": "thread-root", "canAcceptDirectInput": true,
					},
				},
			})
		}
	})
	handler, dir := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.BrowseRoots = []string{browseRoot}
	})
	projectDir = dir

	runGitTestCommand(t, projectDir, "init")
	runGitTestCommand(t, projectDir, "config", "user.email", "mim24@example.invalid")
	runGitTestCommand(t, projectDir, "config", "user.name", "MIM-24")
	if err := os.WriteFile(filepath.Join(projectDir, "README.md"), []byte("mim24\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, projectDir, "add", "README.md")
	runGitTestCommand(t, projectDir, "commit", "-m", "initial")

	externalWorktree = filepath.Join(browseRoot, "codex-external-worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "-b", "mim24-external", externalWorktree)
	t.Cleanup(func() {
		_ = exec.Command("git", "-C", projectDir, "worktree", "remove", "--force", externalWorktree).Run()
	})
	symlinkedWorktree = filepath.Join(browseRoot, "codex-external-link")
	if err := os.Symlink(externalWorktree, symlinkedWorktree); err != nil {
		if runtime.GOOS == "windows" {
			t.Skip("Windows symlink creation requires Developer Mode or elevation")
		}
		t.Fatal(err)
	}
	secondExternalWorktree = filepath.Join(browseRoot, "codex-second-worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "-b", "mim24-second", secondExternalWorktree)
	t.Cleanup(func() {
		_ = exec.Command("git", "-C", projectDir, "worktree", "remove", "--force", secondExternalWorktree).Run()
	})

	deletedWorktree = filepath.Join(browseRoot, "deleted-worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "-b", "mim24-deleted", deletedWorktree)
	runGitTestCommand(t, projectDir, "worktree", "remove", "--force", deletedWorktree)

	otherRepo = filepath.Join(browseRoot, "unrelated-repository")
	if err := os.MkdirAll(otherRepo, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, otherRepo, "init")

	server := httptest.NewServer(handler)
	defer server.Close()
	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	if err := conn.WriteJSON(map[string]any{
		"id": 700, "method": "thread/list",
		"params": map[string]any{
			"limit":       50,
			"sortKey":     "updated_at",
			"sourceKinds": []any{"cli", "vscode", "appServer", "subAgent"},
		},
	}); err != nil {
		t.Fatal(err)
	}
	firstRequest := readUpstreamFrame(t, received)
	if bytes.Contains(firstRequest, []byte(`"cwd"`)) {
		t.Fatalf("受控全局发现不能伪造 cwd：%s", firstRequest)
	}
	if !bytes.Contains(firstRequest, []byte(`"sourceKinds":["cli","vscode","appServer","subAgent"]`)) {
		t.Fatalf("受控全局发现必须显式包含 Codex 派发的 subAgent 来源：%s", firstRequest)
	}

	firstResponse := readGatewayRaw(t, conn)
	if bytes.Contains(firstResponse, []byte("upstream-secret-cursor")) ||
		bytes.Contains(firstResponse, []byte("must-not-pass-through")) {
		t.Fatalf("gateway 不得原样下发 upstream cursor 或未知字段：%s", firstResponse)
	}
	var response struct {
		Result struct {
			Data []struct {
				ID                   string `json:"id"`
				CWD                  string `json:"cwd"`
				ParentThreadID       string `json:"parentThreadId"`
				AgentNickname        string `json:"agentNickname"`
				AgentRole            string `json:"agentRole"`
				SessionID            string `json:"sessionId"`
				CanAcceptDirectInput *bool  `json:"canAcceptDirectInput"`
				MimiRemote           struct {
					ProjectID string `json:"projectId"`
					ReadOnly  bool   `json:"readOnly"`
				} `json:"mimiRemote"`
			} `json:"data"`
			NextCursor string `json:"nextCursor"`
		} `json:"result"`
	}
	if err := json.Unmarshal(firstResponse, &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Result.Data) != 5 {
		t.Fatalf("仅应保留项目根与同仓库多个外部 Worktree（含 symlink），got=%s", firstResponse)
	}
	byID := map[string]struct {
		readOnly bool
		canInput *bool
	}{}
	for _, item := range response.Result.Data {
		if item.MimiRemote.ProjectID != "demo" {
			t.Fatalf("安全结果必须绑定授权 project，got=%+v", item)
		}
		byID[item.ID] = struct {
			readOnly bool
			canInput *bool
		}{item.MimiRemote.ReadOnly, item.CanAcceptDirectInput}
		if item.ID == "thread-external" &&
			(item.ParentThreadID != "thread-root" || item.AgentNickname != "worker-a" ||
				item.AgentRole != "worker" || item.SessionID != "session-a") {
			t.Fatalf("子会话稳定元数据必须保留：%+v", item)
		}
	}
	if external := byID["thread-external"]; !external.readOnly ||
		external.canInput == nil || *external.canInput {
		t.Fatalf("外部 Worktree 会话必须 fail-closed 为只读：%+v", external)
	}
	if root := byID["thread-root"]; root.readOnly || root.canInput == nil || !*root.canInput {
		t.Fatalf("项目根顶层 thread 应保留显式写能力：%+v", root)
	}
	if child := byID["thread-root-child"]; !child.readOnly || child.canInput == nil || *child.canInput {
		t.Fatalf("显式 parent 子 Thread 即使声明可输入也必须保持只读：%+v", child)
	}
	if !strings.HasPrefix(response.Result.NextCursor, "mimi_") {
		t.Fatalf("分页 cursor 必须是当前连接生成的 opaque token：%q", response.Result.NextCursor)
	}

	foreignConn := dialAuthedGateway(t, server.URL)
	defer foreignConn.Close()
	if err := foreignConn.WriteJSON(map[string]any{
		"id": 708, "method": "thread/list",
		"params": map[string]any{"limit": 50, "cursor": response.Result.NextCursor},
	}); err != nil {
		t.Fatal(err)
	}
	if errFrame := readGatewayError(t, foreignConn); !strings.Contains(errFrame.message, "不属于当前授权连接") {
		t.Fatalf("连接级 opaque cursor 不得跨连接复用：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)

	if err := conn.WriteJSON(map[string]any{
		"id": 701, "method": "thread/read",
		"params": map[string]any{"threadId": "thread-external", "includeTurns": true},
	}); err != nil {
		t.Fatal(err)
	}
	_ = readUpstreamFrame(t, received)
	readResponse := readGatewayRaw(t, conn)
	if !bytes.Contains(readResponse, []byte(`"canAcceptDirectInput":false`)) ||
		!bytes.Contains(readResponse, []byte(`"readOnly":true`)) {
		t.Fatalf("thread/read 不得把外部 Worktree 恢复为可写：%s", readResponse)
	}

	if err := conn.WriteJSON(map[string]any{
		"id": 702, "method": "turn/start",
		"params": map[string]any{
			"threadId":          "thread-external",
			"cwd":               externalWorktree,
			"input":             []any{map[string]any{"type": "text", "text": "must be rejected"}},
			"approvalPolicy":    "on-request",
			"approvalsReviewer": "user",
			"sandboxPolicy": map[string]any{
				"type": "workspaceWrite", "writableRoots": []string{externalWorktree}, "networkAccess": false,
			},
		},
	}); err != nil {
		t.Fatal(err)
	}
	if errFrame := readGatewayError(t, conn); !strings.Contains(errFrame.message, "只读子会话") {
		t.Fatalf("只读子 Thread 必须阻止 turn/start：%+v", errFrame)
	}
	assertNoUpstreamFrame(t, received)

	readOnlyMutations := []map[string]any{
		{
			"id": 704, "method": "thread/name/set",
			"params": map[string]any{"threadId": "thread-external", "name": "must be rejected"},
		},
		{
			"id": 705, "method": "thread/archive",
			"params": map[string]any{"threadId": "thread-external"},
		},
		{
			"id": 706, "method": "turn/interrupt",
			"params": map[string]any{"threadId": "thread-external", "turnId": "turn-running"},
		},
		{
			"id": 707, "method": "thread/fork",
			"params": map[string]any{
				"threadId": "thread-external", "cwd": externalWorktree,
				"approvalPolicy": "on-request", "approvalsReviewer": "user",
				"sandbox": "danger-full-access",
			},
		},
	}
	for _, request := range readOnlyMutations {
		if err := conn.WriteJSON(request); err != nil {
			t.Fatal(err)
		}
		if errFrame := readGatewayError(t, conn); !strings.Contains(errFrame.message, "只读子会话") {
			t.Fatalf("%s 必须被只读边界阻止：%+v", request["method"], errFrame)
		}
		assertNoUpstreamFrame(t, received)
	}

	if err := conn.WriteJSON(map[string]any{
		"id": 703, "method": "thread/list",
		"params": map[string]any{"limit": 50, "cursor": response.Result.NextCursor},
	}); err != nil {
		t.Fatal(err)
	}
	secondRequest := readUpstreamFrame(t, received)
	if bytes.Contains(secondRequest, []byte(response.Result.NextCursor)) ||
		!bytes.Contains(secondRequest, []byte("upstream-secret-cursor")) {
		t.Fatalf("upstream 只能看到还原后的原始 cursor：%s", secondRequest)
	}
	secondResponse := readGatewayRaw(t, conn)
	if !bytes.Contains(secondResponse, []byte(`"nextCursor":null`)) {
		t.Fatalf("末页应稳定返回 null cursor：%s", secondResponse)
	}
}

func TestReceiverThreadIDsOnlyComeFromCollabAgentToolCalls(t *testing.T) {
	raw := json.RawMessage(`{
		"thread": {
			"turns": [{
				"items": [
					{
						"id": "tool-item-is-not-a-thread",
						"type": "collabAgentToolCall",
						"receiverThreadIds": ["child-a", "child-b", "child-a", " padded-child "],
						"agentsStates": {
							"child-a": {"status": "running"},
							"child-b": {"status": "completed"}
						}
					},
					{
						"id": "ordinary-item",
						"type": "commandExecution",
						"receiverThreadIds": ["must-not-be-authorized"]
					}
				]
			}]
		}
	}`)
	related := relatedThreadsForParent(
		receiverThreadIDsFromJSON(raw),
		"codex",
		"/authorized/repository",
		"project-demo",
	)
	if len(related) != 2 || related[0].id != "child-a" || related[1].id != "child-b" {
		t.Fatalf("receiverThreadIds 应支持多 receiver 并去重，got=%+v", related)
	}
	for _, thread := range related {
		if thread.id == "tool-item-is-not-a-thread" || thread.id == "must-not-be-authorized" ||
			thread.id == "padded-child" || thread.id == " padded-child " {
			t.Fatalf("tool item id 或非 collab item receiver 不得成为 Thread ID：%+v", related)
		}
		if !thread.directInputKnown || thread.canAcceptDirectInput || !thread.readOnly {
			t.Fatalf("receiver 子 Thread 未返回 capability 时必须只读：%+v", thread)
		}
	}
}

func TestReceiverReadOnlyAuthorizationCannotBeUpgradedByThreadRead(t *testing.T) {
	policy := &appServerGatewayPolicy{
		runtimeID: "codex",
		allowedThreads: map[string]appServerGatewayAllowedThread{
			"child-a": {
				id: "child-a", runtimeID: "codex", cwd: "/repo", scopeID: "repo",
				directInputKnown: true, canAcceptDirectInput: false, readOnly: true,
			},
		},
	}
	normalized, ok := policy.normalizeAllowedThread(appServerGatewayAllowedThread{
		id: "child-a", runtimeID: "codex", cwd: "/repo", scopeID: "repo",
		directInputKnown: true, canAcceptDirectInput: true,
	})
	if !ok || !normalized.readOnly || !normalized.directInputKnown || normalized.canAcceptDirectInput {
		t.Fatalf("thread/read 不得升级父侧 receiver 的只读授权：%+v", normalized)
	}
}

func TestReadOnlyThreadResponseRejectsReceiverOutsideParentScope(t *testing.T) {
	projectDir := t.TempDir()
	outsideDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{
		ID: "demo", Name: "Demo", Path: projectDir,
	}})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{cfg: config.Config{}, projects: registry}
	scope, ok := router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("测试项目必须能解析授权作用域")
	}
	policy := &appServerGatewayPolicy{
		router:         router,
		runtimeID:      "codex",
		pendingThreads: map[string]appServerGatewayPendingThreadRequest{},
		allowedThreads: map[string]appServerGatewayAllowedThread{
			"child-outside": {
				id: "child-outside", runtimeID: "codex", cwd: scope.realPath, scopeID: scope.id,
				directInputKnown: true, canAcceptDirectInput: false, readOnly: true,
			},
		},
	}
	id := json.RawMessage("801")
	if err := policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{
		method: "thread/read", threadID: "child-outside", cwd: scope.realPath, scopeID: scope.id,
	}); err != nil {
		t.Fatal(err)
	}
	payload := []byte(fmt.Sprintf(
		`{"id":801,"result":{"thread":{"id":"child-outside","cwd":%q,"parentThreadId":"parent","canAcceptDirectInput":false,"turns":[{"items":[{"type":"agentMessage","text":"must-not-leak"}]}]}}}`,
		outsideDir,
	))
	_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
	if forward || policyErr == nil {
		t.Fatalf("跨作用域子 Thread 正文必须被阻断：forward=%v err=%+v", forward, policyErr)
	}
	if policyErr.data["reason"] != "thread_read_scope_mismatch" ||
		!strings.Contains(policyErr.message, "不在授权作用域") {
		t.Fatalf("跨作用域错误必须可诊断且不泄露正文：%+v", policyErr)
	}
}

func TestContextSubagentMergeKeepsStableIdentityAcrossStatusUpdates(t *testing.T) {
	canAccept := false
	merged := mergeContextSubagents(
		[]session.ContextSubagent{{
			ID:                   "child-a",
			ParentThreadID:       "parent-a",
			SessionID:            "session-a",
			Nickname:             "Noether",
			Role:                 "review",
			Status:               "running",
			CanAcceptDirectInput: &canAccept,
		}},
		[]session.ContextSubagent{{
			ID:            "child-a",
			Status:        "completed",
			StatusMessage: "done",
		}},
	)
	if len(merged) != 1 {
		t.Fatalf("同一子 Thread 应合并为一条：%+v", merged)
	}
	got := merged[0]
	if got.ParentThreadID != "parent-a" || got.SessionID != "session-a" ||
		got.Nickname != "Noether" || got.Role != "review" ||
		got.Status != "completed" || got.StatusMessage != "done" ||
		got.CanAcceptDirectInput == nil || *got.CanAcceptDirectInput {
		t.Fatalf("状态更新必须保留稳定身份与只读 capability：%+v", got)
	}
}
