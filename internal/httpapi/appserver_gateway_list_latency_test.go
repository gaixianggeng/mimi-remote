package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestGlobalThreadListDoesNotRepeatGitBeforeQueuedReply(t *testing.T) {
	browseRoot := t.TempDir()
	var listPayload []byte
	reply := []byte(`{"method":"item/agentMessage/delta","params":{"threadId":"thread-0","itemId":"reply","delta":"OK"}}`)
	sent := make(chan time.Time, 1)
	upstreamURL, _, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, _ []byte) {
		sent <- time.Now()
		_ = conn.WriteMessage(websocket.TextMessage, listPayload)
		_ = conn.WriteMessage(websocket.TextMessage, reply)
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
	gitCalls := countGlobalListGitCalls(t)
	server := httptest.NewServer(handler)
	defer server.Close()
	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"id":1,"method":"thread/list","params":{"limit":50}}`)); err != nil {
		t.Fatal(err)
	}
	list := readGatewayRaw(t, conn)
	if !bytes.Contains(list, []byte(`"thread-29"`)) {
		t.Fatalf("正文前的列表必须完整返回：%s", list)
	}
	if got := readGatewayRaw(t, conn); !bytes.Equal(got, reply) {
		t.Fatalf("紧跟列表的正文必须原样转发：%s", got)
	}
	t.Logf("上游正文已就绪至客户端收到：%s，Git 调用：%d", time.Since(<-sent), gitCalls())
	if got := gitCalls(); got != 2 {
		t.Fatalf("正文不能等待逐任务重复的 Git 查询：calls=%d", got)
	}
}

func TestGlobalThreadListDoesNotProbeGitForKnownProjects(t *testing.T) {
	projectDir := newCommittedGitRepo(t)
	policy := globalListLatencyPolicy(t, projectDir, t.TempDir())
	gitCalls := countGlobalListGitCalls(t)
	for _, count := range []int{0, 30} {
		_, allowed, err := policy.sanitizeGlobalThreadListResponse(
			globalListLatencyPayload(t, projectDir, count),
			appServerGatewayPendingThreadRequest{},
		)
		if err != nil || len(allowed) != count {
			t.Fatalf("已配置项目的任务列表应完整保留：count=%d allowed=%d err=%v", count, len(allowed), err)
		}
	}
	if got := gitCalls(); got != 0 {
		t.Fatalf("已知项目和空列表不应扫描 Git，避免阻塞同一连接的正文：calls=%d", got)
	}
}

func TestGlobalThreadListDoesNotScanProjectsForNonRepository(t *testing.T) {
	projectDir := newCommittedGitRepo(t)
	browseRoot := t.TempDir()
	policy := globalListLatencyPolicy(t, projectDir, browseRoot)
	gitCalls := countGlobalListGitCalls(t)
	_, allowed, err := policy.sanitizeGlobalThreadListResponse(
		globalListLatencyPayload(t, browseRoot, 30), appServerGatewayPendingThreadRequest{},
	)
	if err != nil || len(allowed) != 0 {
		t.Fatalf("普通目录不能通过 Git 归属获得全局发现权限：allowed=%d err=%v", len(allowed), err)
	}
	if got := gitCalls(); got != 1 {
		t.Fatalf("目录不属于 Git 仓库时不应继续扫描项目：calls=%d", got)
	}
}

func TestGlobalThreadListResolvesRepeatedWorkspaceOncePerPage(t *testing.T) {
	projectDir := newCommittedGitRepo(t)
	browseRoot := t.TempDir()
	worktreeDir := filepath.Join(browseRoot, "worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "--detach", worktreeDir)
	policy := globalListLatencyPolicy(t, projectDir, browseRoot)
	gitCalls := countGlobalListGitCalls(t)
	payload := globalListLatencyPayload(t, worktreeDir, 30)
	started := time.Now()
	_, allowed, err := policy.sanitizeGlobalThreadListResponse(payload, appServerGatewayPendingThreadRequest{})
	t.Logf("30 条同目录任务的列表处理耗时：%s，Git 调用：%d", time.Since(started), gitCalls())
	if err != nil || len(allowed) != 30 {
		t.Fatalf("同仓外部 Worktree 的任务应完整保留：allowed=%d err=%v", len(allowed), err)
	}
	for _, thread := range allowed {
		if !thread.readOnly || thread.canAcceptDirectInput {
			t.Fatalf("外部 Worktree 仍必须只读：%+v", thread)
		}
	}
	if got := gitCalls(); got != 2 {
		t.Errorf("每页只需查询主项目和外部 Worktree 各一次：calls=%d", got)
	}

	// 归属只在当前响应内复用。目录不再属于原仓库时，下一页必须重新判定。
	marker := filepath.Join(worktreeDir, ".git")
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	_, allowed, err = policy.sanitizeGlobalThreadListResponse(payload, appServerGatewayPendingThreadRequest{})
	if err != nil || len(allowed) != 0 {
		t.Fatalf("下一次响应不能沿用失效的仓库归属：allowed=%d err=%v", len(allowed), err)
	}
	if got := gitCalls(); got != 3 {
		t.Errorf("未匹配目录也只在本页查询一次：total calls=%d", got)
	}
}

func globalListLatencyPolicy(t *testing.T, projectDir, browseRoot string) *appServerGatewayPolicy {
	t.Helper()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "project", Name: "Project", Path: projectDir}})
	if err != nil {
		t.Fatal(err)
	}
	return &appServerGatewayPolicy{runtimeID: "codex", router: &Router{
		projects: registry,
		cfg:      config.Config{BrowseRoots: []string{browseRoot}, WorktreesRoot: t.TempDir()},
	}}
}

func globalListLatencyPayload(t *testing.T, cwd string, count int) []byte {
	t.Helper()
	items := make([]map[string]any, 0, count)
	for i := 0; i < count; i++ {
		items = append(items, map[string]any{"id": fmt.Sprintf("thread-%d", i), "cwd": cwd, "canAcceptDirectInput": true})
	}
	data, err := json.Marshal(map[string]any{"id": 1, "result": map[string]any{"data": items, "nextCursor": nil}})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func countGlobalListGitCalls(t *testing.T) func() int {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Git 调用计数使用 POSIX wrapper；权限行为另由跨平台全局发现测试覆盖")
	}
	realGit, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	logPath := filepath.Join(dir, "calls")
	script := "#!/bin/sh\nprintf 'call\\n' >> \"$MIMI_LIST_GIT_LOG\"\nexec \"$MIMI_LIST_REAL_GIT\" \"$@\"\n"
	if err := os.WriteFile(filepath.Join(dir, "git"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MIMI_LIST_GIT_LOG", logPath)
	t.Setenv("MIMI_LIST_REAL_GIT", realGit)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return func() int {
		data, err := os.ReadFile(logPath)
		if err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		return strings.Count(string(data), "\n")
	}
}
