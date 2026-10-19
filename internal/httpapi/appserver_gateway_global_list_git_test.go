package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

// stubGatewayGitCommonDirectory 替换全局发现的 Git 判定入口，测试结束时等后台判定
// 全部退出再恢复，避免迟到的 goroutine 读到被恢复的变量。
func stubGatewayGitCommonDirectory(t *testing.T, stub func(ctx context.Context, path string) (string, error)) {
	t.Helper()
	original := gatewayGitCommonDirectory
	gatewayGitCommonDirectory = stub
	t.Cleanup(func() { gatewayGitCommonDirectory = original })
}

func slowGitCommonDirectory(delay time.Duration) func(ctx context.Context, path string) (string, error) {
	return func(ctx context.Context, path string) (string, error) {
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return "", ctx.Err()
		}
		return resolveGatewayGitCommonDirectory(ctx, path)
	}
}

func hungGitCommonDirectory(ctx context.Context, _ string) (string, error) {
	<-ctx.Done()
	return "", ctx.Err()
}

func globalListResponseCursor(t *testing.T, payload []byte) (string, bool) {
	t.Helper()
	var response struct {
		Result struct {
			NextCursor *string `json:"nextCursor"`
		} `json:"result"`
	}
	if err := json.Unmarshal(payload, &response); err != nil {
		t.Fatalf("thread/list 响应无效：%v %s", err, payload)
	}
	if response.Result.NextCursor == nil {
		return "", false
	}
	return *response.Result.NextCursor, true
}

func TestGlobalThreadListReusesGitOwnershipAcrossResponses(t *testing.T) {
	projectDir := newCommittedGitRepo(t)
	browseRoot := t.TempDir()
	worktreeDir := filepath.Join(browseRoot, "worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "--detach", worktreeDir)
	policy := globalListLatencyPolicy(t, projectDir, browseRoot)
	gitCalls := countGlobalListGitCalls(t)
	payload := globalListLatencyPayload(t, worktreeDir, 30)

	for round := 0; round < 3; round++ {
		_, allowed, err := policy.sanitizeGlobalThreadListResponse(payload, appServerGatewayPendingThreadRequest{})
		if err != nil || len(allowed) != 30 {
			t.Fatalf("第 %d 轮同仓外部 Worktree 的任务应完整保留：allowed=%d err=%v", round, len(allowed), err)
		}
	}
	if got := gitCalls(); got != 2 {
		t.Fatalf("Git 归属应跨响应复用，只在首轮查询主项目和外部 Worktree 各一次：calls=%d", got)
	}

	// 已登记项目变化必须立刻生效：缓存只记目录的 common-dir，授权仍按当前项目表判定。
	registry, err := projects.NewRegistry(nil)
	if err != nil {
		t.Fatal(err)
	}
	policy.router.projects = registry
	_, allowed, err := policy.sanitizeGlobalThreadListResponse(payload, appServerGatewayPendingThreadRequest{})
	if err != nil || len(allowed) != 0 {
		t.Fatalf("项目被移除后外部 Worktree 不能沿用缓存获得授权：allowed=%d err=%v", len(allowed), err)
	}
}

func TestGlobalThreadListSlowGitDoesNotHoldOtherResponses(t *testing.T) {
	const gitDelay = 1500 * time.Millisecond
	stubGatewayGitCommonDirectory(t, slowGitCommonDirectory(gitDelay))
	browseRoot := t.TempDir()
	var listPayload []byte
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		var request struct {
			ID     int    `json:"id"`
			Method string `json:"method"`
		}
		_ = json.Unmarshal(payload, &request)
		switch request.ID {
		case 2:
			_ = conn.WriteMessage(websocket.TextMessage, []byte(`{"id":2,"result":{"data":[],"nextCursor":null}}`))
		default:
			reply := bytes.Replace(listPayload, []byte(`"id":1,`), []byte(`"id":`+jsonInt(request.ID)+`,`), 1)
			_ = conn.WriteMessage(websocket.TextMessage, reply)
		}
	})
	handler, projectDir := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.BrowseRoots = []string{browseRoot}
		cfg.WorktreesRoot = t.TempDir()
	})
	runGitTestCommand(t, projectDir, "init")
	runGitTestCommand(t, projectDir, "-c", "user.email=test@example.invalid", "-c", "user.name=Test", "commit", "--allow-empty", "-m", "initial")
	worktreeDir := filepath.Join(browseRoot, "worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "--detach", worktreeDir)
	listPayload = globalListLatencyPayload(t, worktreeDir, 30)
	server := httptest.NewServer(handler)
	defer server.Close()
	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"id":1,"method":"thread/list","params":{"limit":50}}`)); err != nil {
		t.Fatal(err)
	}
	<-received
	scoped, err := json.Marshal(map[string]any{"id": 2, "method": "thread/list", "params": map[string]any{"cwd": projectDir, "limit": 20}})
	if err != nil {
		t.Fatal(err)
	}
	sentScoped := time.Now()
	if err := conn.WriteMessage(websocket.TextMessage, scoped); err != nil {
		t.Fatal(err)
	}
	<-received
	var list []byte
	var scopedElapsed time.Duration
	for list == nil || scopedElapsed == 0 {
		frame := readGatewayRaw(t, conn)
		switch {
		case bytes.Contains(frame, []byte(`"id":2`)):
			scopedElapsed = time.Since(sentScoped)
		case bytes.Contains(frame, []byte(`"id":1`)):
			list = frame
		default:
			t.Fatalf("意外的帧：%s", frame)
		}
	}
	if scopedElapsed >= gitDelay {
		t.Fatalf("Git 判定慢时同连接的作用域列表不能跟着等完：elapsed=%s git=%s", scopedElapsed, gitDelay)
	}
	if bytes.Contains(list, []byte(`"thread-0"`)) {
		t.Fatalf("归属未判定的外部 Worktree 会话不能放行：%s", list)
	}
	retryCursor, ok := globalListResponseCursor(t, list)
	if !ok || retryCursor == "" {
		t.Fatalf("未判定完的页必须给出重取本页的 cursor，不能让客户端当作遍历结束：%s", list)
	}

	// 后台判定完成后，重取同一页（首页不带上游 cursor）应完整返回。
	time.Sleep(gitDelay)
	retry, err := json.Marshal(map[string]any{"id": 3, "method": "thread/list", "params": map[string]any{"limit": 50, "cursor": retryCursor}})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteMessage(websocket.TextMessage, retry); err != nil {
		t.Fatal(err)
	}
	if upstreamRetry := <-received; bytes.Contains(upstreamRetry, []byte(`"cursor"`)) {
		t.Fatalf("重取首页不能带 cursor 发给上游：%s", upstreamRetry)
	}
	complete := readGatewayRaw(t, conn)
	if !bytes.Contains(complete, []byte(`"thread-29"`)) {
		t.Fatalf("判定完成后重取本页应完整返回：%s", complete)
	}
	if cursor, ok := globalListResponseCursor(t, complete); ok {
		t.Fatalf("完整判定的末页应原样结束遍历：cursor=%q", cursor)
	}
}

func TestGlobalThreadListGitTimeoutKeepsPageUnsettled(t *testing.T) {
	originalTimeout := gatewayGitOwnershipResolveTimeout
	gatewayGitOwnershipResolveTimeout = 50 * time.Millisecond
	t.Cleanup(func() { gatewayGitOwnershipResolveTimeout = originalTimeout })
	stubGatewayGitCommonDirectory(t, hungGitCommonDirectory)

	projectDir := newCommittedGitRepo(t)
	browseRoot := t.TempDir()
	worktreeDir := filepath.Join(browseRoot, "worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "--detach", worktreeDir)
	policy := globalListLatencyPolicy(t, projectDir, browseRoot)
	payload := globalListLatencyPayload(t, worktreeDir, 30)
	pending := appServerGatewayPendingThreadRequest{upstreamCursor: "upstream-page-2"}

	for round := 0; round < 2; round++ {
		rewritten, allowed, err := policy.sanitizeGlobalThreadListResponse(payload, pending)
		if err != nil || len(allowed) != 0 {
			t.Fatalf("Git 超时时不能放行未判定的会话：allowed=%d err=%v", len(allowed), err)
		}
		// 上游这页本来是末页（nextCursor=null）；未判定完时仍要让客户端重取本页。
		token, ok := globalListResponseCursor(t, rewritten)
		if !ok || token == "" {
			t.Fatalf("第 %d 轮：Git 超时不能被当作完整遍历：%s", round, rewritten)
		}
		params := map[string]any{"cursor": token}
		if err := policy.resolveGlobalListCursor(params); err != nil || params["cursor"] != "upstream-page-2" {
			t.Fatalf("重取 cursor 必须回到本页的上游 cursor：params=%v err=%v", params, err)
		}
	}

	// 超时不能被缓存成“不在仓库”：Git 恢复后同一目录重新判定并放行。
	gatewayGitCommonDirectory = resolveGatewayGitCommonDirectory
	gatewayGitOwnershipResolveTimeout = originalTimeout
	_, allowed, err := policy.sanitizeGlobalThreadListResponse(payload, pending)
	if err != nil || len(allowed) != 30 {
		t.Fatalf("Git 恢复后应重新判定并完整放行：allowed=%d err=%v", len(allowed), err)
	}
}

func TestGlobalThreadListTransientGitFailureIsNotCachedAsNonRepository(t *testing.T) {
	projectDir := newCommittedGitRepo(t)
	browseRoot := t.TempDir()
	worktreeDir := filepath.Join(browseRoot, "worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "--detach", worktreeDir)
	policy := globalListLatencyPolicy(t, projectDir, browseRoot)
	payload := globalListLatencyPayload(t, worktreeDir, 30)

	// 进程起不来之类的失败没有给出“是不是仓库”的结论：不能放行，也不能推进遍历。
	stubGatewayGitCommonDirectory(t, func(context.Context, string) (string, error) {
		return "", errors.New("fork/exec git: resource temporarily unavailable")
	})
	rewritten, allowed, err := policy.sanitizeGlobalThreadListResponse(payload, appServerGatewayPendingThreadRequest{})
	if err != nil || len(allowed) != 0 {
		t.Fatalf("Git 临时失败时不能放行未判定的会话：allowed=%d err=%v", len(allowed), err)
	}
	if token, ok := globalListResponseCursor(t, rewritten); !ok || token == "" {
		t.Fatalf("Git 临时失败不能被当作完整遍历：%s", rewritten)
	}

	// 失败没有被缓存成“不在仓库”：Git 恢复后立即重新判定并放行。
	gatewayGitCommonDirectory = resolveGatewayGitCommonDirectory
	_, allowed, err = policy.sanitizeGlobalThreadListResponse(payload, appServerGatewayPendingThreadRequest{})
	if err != nil || len(allowed) != 30 {
		t.Fatalf("Git 恢复后应重新判定并完整放行：allowed=%d err=%v", len(allowed), err)
	}
}

func TestGlobalThreadListBrokenWorktreeIsSettledAsNonRepository(t *testing.T) {
	projectDir := newCommittedGitRepo(t)
	browseRoot := t.TempDir()
	brokenDir := filepath.Join(browseRoot, "broken")
	if err := os.MkdirAll(brokenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// 仓库已删除、Worktree 只剩指向它的 .git 文件：Git 明确回答“不是仓库”。
	marker := []byte("gitdir: " + filepath.Join(t.TempDir(), "gone", ".git", "worktrees", "broken") + "\n")
	if err := os.WriteFile(filepath.Join(brokenDir, ".git"), marker, 0o644); err != nil {
		t.Fatal(err)
	}
	policy := globalListLatencyPolicy(t, projectDir, browseRoot)
	rewritten, allowed, err := policy.sanitizeGlobalThreadListResponse(
		globalListLatencyPayload(t, brokenDir, 3), appServerGatewayPendingThreadRequest{},
	)
	if err != nil || len(allowed) != 0 {
		t.Fatalf("失效 Worktree 的会话不能放行：allowed=%d err=%v", len(allowed), err)
	}
	if cursor, ok := globalListResponseCursor(t, rewritten); ok {
		t.Fatalf("Git 已明确回答不是仓库，本页应判定完、遍历照常结束：cursor=%q", cursor)
	}
}

func TestGatewayGitCommonDirectoryDistinguishesVerdictFromFailure(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// Git 跑完并给出“不是仓库”：确定结论。
	dir, err := resolveGatewayGitCommonDirectory(ctx, t.TempDir())
	if err != nil || dir != "" {
		t.Fatalf("非仓库目录应得到确定的否定结论：dir=%q err=%v", dir, err)
	}
	// 进程根本没起来：没有结论，不能当作“不是仓库”。
	_, _, err = runCommand(ctx, t.TempDir(), 1024, "mimi-definitely-missing-git")
	if err == nil || gitCommandExitedWithVerdict(err) {
		t.Fatalf("进程起不来不能被当作 Git 的结论：err=%v", err)
	}
}

func TestGlobalListRetryCursorForFirstPageOmitsUpstreamCursor(t *testing.T) {
	policy := &appServerGatewayPolicy{runtimeID: "codex"}
	token, err := policy.storeGlobalListRetryCursor("")
	if err != nil || token == "" {
		t.Fatalf("首页也要能生成重取 cursor：token=%q err=%v", token, err)
	}
	params := map[string]any{"cursor": token}
	if err := policy.resolveGlobalListCursor(params); err != nil {
		t.Fatal(err)
	}
	if _, exists := params["cursor"]; exists {
		t.Fatalf("重取首页时不能把 cursor 发给上游：%v", params)
	}
	params = map[string]any{"cursor": "mimi_unknown"}
	if err := policy.resolveGlobalListCursor(params); err == nil {
		t.Fatal("不属于当前连接的 cursor 仍必须拒绝")
	}
}

func jsonInt(value int) string {
	data, _ := json.Marshal(value)
	return string(data)
}
