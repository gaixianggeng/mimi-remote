package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

func newWorktreeCleanupFixture(t *testing.T, count int) worktreeCleanupFixture {
	t.Helper()
	requireGit(t)
	repo := newCommittedGitRepo(t)
	worktreesRoot := t.TempDir()
	projectRoot := filepath.Join(worktreesRoot, "checkouts", "repo")
	if err := os.MkdirAll(projectRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	worktrees := make([]managedWorktree, 0, count)
	for index := 0; index < count; index++ {
		checkoutPath := filepath.Join(projectRoot, fmt.Sprintf("cleanup-%02d", index))
		branch := fmt.Sprintf("mimi/cleanup-%02d", index)
		runGitTestCommand(t, repo, "worktree", "add", "-b", branch, checkoutPath, "HEAD")
		lastUsed := now.Add(-time.Duration(60-index*5) * 24 * time.Hour)
		entry := managedWorktree{
			Version:        managedWorktreeRegistryVersion,
			Path:           canonicalTestPath(t, checkoutPath),
			CheckoutPath:   canonicalTestPath(t, checkoutPath),
			RepositoryPath: canonicalTestPath(t, repo),
			Base:           "HEAD",
			Branch:         branch,
			CreatedAt:      lastUsed.Add(-24 * time.Hour),
			LastUsedAt:     lastUsed,
			RootProject:    projects.Project{ID: "repo", Name: "Repo", Path: repo, RealPath: canonicalTestPath(t, repo)},
		}
		writeManagedWorktreeRegistryForTest(t, worktreesRoot, entry)
		worktrees = append(worktrees, entry)
	}
	t.Cleanup(func() {
		for _, entry := range worktrees {
			_ = exec.Command("git", "-C", repo, "worktree", "remove", "--force", entry.CheckoutPath).Run()
		}
	})
	cfg := config.Config{
		Auth:          config.AuthConfig{Token: testToken},
		WorktreesRoot: worktreesRoot,
		Codex:         config.CodexConfig{Bin: "/bin/cat", Env: map[string]string{"TERM": "xterm-256color"}},
		Session:       config.SessionConfig{OutputBufferBytes: 8 * 1024},
		Projects:      []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}},
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	manager := session.NewManager(session.Options{
		CodexBin: cfg.Codex.Bin, Env: cfg.Codex.Env, OutputBuffer: cfg.Session.OutputBufferBytes,
	})
	t.Cleanup(manager.Shutdown)
	router := &Router{
		cfg:                         cfg,
		projects:                    registry,
		sessions:                    manager,
		gatewayThreads:              map[string]appServerGatewayAllowedThread{},
		managedWorktrees:            map[string]managedWorktree{},
		managedWorktreeCleanupPlans: map[string]worktreeCleanupPlan{},
	}
	handler := auth.New(testToken, false).Middleware(http.HandlerFunc(router.worktreeCleanupHandler))
	server := testServer{handler: handler, manager: manager}
	return worktreeCleanupFixture{server: server, router: router, repo: repo, worktreesRoot: worktreesRoot, worktrees: worktrees}
}

func newManagedWorktreeGatewayPolicyForTest(router *Router) *appServerGatewayPolicy {
	return &appServerGatewayPolicy{
		router:                router,
		runtimeID:             "codex",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		pendingHistory:        map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets:        map[string]appServerGatewayHistoryBudget{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
}

func requestWorktreeCleanup(t *testing.T, server testServer, payload worktreeCleanupRequest) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/worktrees/cleanup", payload))
	return rec
}

func cleanupItemForPath(t *testing.T, items []worktreeCleanupItem, path string) worktreeCleanupItem {
	t.Helper()
	for _, item := range items {
		if item.Workspace.Path == path {
			return item
		}
	}
	t.Fatalf("cleanup response 缺少 path=%s", path)
	return worktreeCleanupItem{}
}

func readManagedWorktreeRegistryForTest(t *testing.T, file string) managedWorktree {
	t.Helper()
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatalf("读取 registry 失败：%v", err)
	}
	var worktree managedWorktree
	if err := json.Unmarshal(data, &worktree); err != nil {
		t.Fatalf("解析 registry 失败：%v", err)
	}
	return worktree
}

func writeManagedWorktreeRegistryForTest(t *testing.T, worktreesRoot string, entry managedWorktree) string {
	t.Helper()
	registryDir := filepath.Join(worktreesRoot, "registry")
	if err := os.MkdirAll(registryDir, 0o755); err != nil {
		t.Fatalf("创建 registry 目录失败：%v", err)
	}
	data, err := json.Marshal(entry)
	if err != nil {
		t.Fatalf("编码 registry 失败：%v", err)
	}
	registryFile := filepath.Join(registryDir, workspaceIDForRealPath(entry.Path)+".json")
	if err := os.WriteFile(registryFile, data, 0o600); err != nil {
		t.Fatalf("写入 registry 失败：%v", err)
	}
	return registryFile
}

func TestGitStatusReturnsEmptyStateForAllowedNonRepository(t *testing.T) {
	requireGit(t)
	projectDir := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "plain", Name: "Plain", Path: projectDir}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/status", gitStatusRequest{Path: projectDir})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("非 Git 目录应返回可展示空态，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if response.IsRepository {
		t.Fatalf("非 Git 目录不应标记为仓库：%+v", response)
	}
}

func TestGitStatusRejectsPathOutsideAllowlist(t *testing.T) {
	requireGit(t)
	outside := t.TempDir()
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/status", gitStatusRequest{Path: outside})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("越界路径应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestCommandActionListFiltersByWorkspaceScope(t *testing.T) {
	projectDir := t.TempDir()
	subdir := filepath.Join(projectDir, "app")
	if err := os.MkdirAll(subdir, 0o755); err != nil {
		t.Fatal(err)
	}
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
		cfg.Actions = []config.ActionConfig{
			{ID: "test", Name: "测试", Command: "/bin/echo", Args: []string{"ok"}, WorkingDir: "app", RequiresConfirmation: true},
			{ID: "outside", Name: "越界", Command: "/bin/echo", Args: []string{"bad"}, WorkingDir: "../outside"},
		}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/actions/list", commandActionListRequest{Path: projectDir})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("action list 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response commandActionListResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 commandActionListResponse：%v", err)
	}
	if response.Path != canonicalTestPath(t, projectDir) {
		t.Fatalf("响应 path 应 canonical 化，got=%q", response.Path)
	}
	if len(response.Actions) != 1 || response.Actions[0].ID != "test" {
		t.Fatalf("只应返回当前 scope 内可执行 action，got=%+v", response.Actions)
	}
	if response.Actions[0].WorkingDir != canonicalTestPath(t, subdir) {
		t.Fatalf("working_dir 应解析到子目录，got=%q", response.Actions[0].WorkingDir)
	}
	if !response.Actions[0].RequiresConfirmation {
		t.Fatalf("requires_confirmation 应透传给 iPad 端：%+v", response.Actions[0])
	}
}

func TestCommandActionRunExecutesConfiguredCommand(t *testing.T) {
	projectDir := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
		cfg.Actions = []config.ActionConfig{
			{ID: "echo", Name: "Echo", Command: "/bin/echo", Args: []string{"hello"}, TimeoutSeconds: 2},
		}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/actions/run", commandActionRunRequest{Path: projectDir, ID: "echo"})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("action run 应成功返回执行结果，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response commandActionRunResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 commandActionRunResponse：%v", err)
	}
	if !response.Success || response.ExitCode != 0 || strings.TrimSpace(response.Output) != "hello" {
		t.Fatalf("action 执行结果异常：%+v", response)
	}
}

func TestCommandActionRunRequiresExplicitConfirmation(t *testing.T) {
	projectDir := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
		cfg.Actions = []config.ActionConfig{
			{ID: "deploy", Name: "Deploy", Command: "/bin/echo", Args: []string{"ship"}, RequiresConfirmation: true},
		}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/actions/run", commandActionRunRequest{Path: projectDir, ID: "deploy"})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("未确认的高风险 action 应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/actions/run", commandActionRunRequest{Path: projectDir, ID: "deploy", Confirmed: true})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("显式确认后 action 应可执行，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response commandActionRunResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 commandActionRunResponse：%v", err)
	}
	if !response.Success || strings.TrimSpace(response.Output) != "ship" {
		t.Fatalf("确认 action 执行结果异常：%+v", response)
	}
}

func TestCommandActionRunReturnsNonZeroExitWithoutHTTPFailure(t *testing.T) {
	projectDir := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
		cfg.Actions = []config.ActionConfig{
			{ID: "missing", Name: "Missing", Command: "/bin/ls", Args: []string{"definitely-missing-file"}},
		}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/actions/run", commandActionRunRequest{Path: projectDir, ID: "missing"})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("命令非 0 退出不应变成 HTTP 失败，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response commandActionRunResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 commandActionRunResponse：%v", err)
	}
	if response.Success || response.ExitCode == 0 || !strings.Contains(response.Output, "definitely-missing-file") {
		t.Fatalf("非 0 退出应保留 exit_code 和 stderr 输出：%+v", response)
	}
}

func TestCommandActionRunRejectsPathOutsideAllowlist(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Actions = []config.ActionConfig{{ID: "echo", Name: "Echo", Command: "/bin/echo"}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/actions/run", commandActionRunRequest{Path: t.TempDir(), ID: "echo"})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("越界路径应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestCapabilityListDiscoversSkillsAndMCPWithoutSecrets(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	binDir := filepath.Join(t.TempDir(), "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	fakeMCP := filepath.Join(binDir, "fake-mcp")
	if err := os.WriteFile(fakeMCP, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
	projectDir := t.TempDir()
	if err := os.Mkdir(filepath.Join(projectDir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	repoSkillDir := filepath.Join(projectDir, ".agents", "skills", "review")
	if err := os.MkdirAll(repoSkillDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repoSkillDir, "SKILL.md"), []byte("---\nname: review\ndescription: Review code changes.\n---\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	userSkillDir := filepath.Join(home, ".agents", "skills", "triage")
	if err := os.MkdirAll(userSkillDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(userSkillDir, "SKILL.md"), []byte("---\nname: triage\ndescription: Triage issues.\n---\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	userCodexDir := filepath.Join(home, ".codex")
	if err := os.MkdirAll(userCodexDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(userCodexDir, "config.toml"), []byte(`
[mcp_servers.context7]
command = "fake-mcp"
args = ["-y", "@upstash/context7-mcp"]
env = { SECRET_TOKEN = "should-not-leak" }

[mcp_servers.missing]
command = "missing-mcp-command"

[mcp_servers.disabled]
url = "https://example.invalid/mcp"
enabled = false

[plugins."sample@test".mcp_servers.docs]
url = "https://docs.example.invalid/mcp"
`), 0o600); err != nil {
		t.Fatal(err)
	}
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/capabilities/list", capabilityListRequest{Path: projectDir})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("capability list 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response capabilityListResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 capabilityListResponse：%v", err)
	}
	if !containsSkill(response.Skills, "review", "repo") || !containsSkill(response.Skills, "triage", "user") {
		t.Fatalf("应发现 repo/user skills：%+v", response.Skills)
	}
	if !containsMCP(response.MCPServers, "context7", "", "stdio", true) {
		t.Fatalf("应发现 stdio MCP server：%+v", response.MCPServers)
	}
	if got := findMCP(response.MCPServers, "context7", ""); got == nil || got.Status != "ready" {
		t.Fatalf("stdio MCP command 可执行时应标记 ready：%+v", response.MCPServers)
	}
	if got := findMCP(response.MCPServers, "missing", ""); got == nil || got.Status != "missing_command" {
		t.Fatalf("stdio MCP command 缺失时应标记 missing_command：%+v", response.MCPServers)
	}
	if !containsMCP(response.MCPServers, "disabled", "", "http", false) {
		t.Fatalf("应保留 disabled 状态：%+v", response.MCPServers)
	}
	if got := findMCP(response.MCPServers, "disabled", ""); got == nil || got.Status != "disabled" {
		t.Fatalf("disabled MCP 应标记 disabled：%+v", response.MCPServers)
	}
	if !containsMCP(response.MCPServers, "docs", "sample@test", "http", true) {
		t.Fatalf("应发现 plugin-provided MCP server 配置：%+v", response.MCPServers)
	}
	if got := findMCP(response.MCPServers, "docs", "sample@test"); got == nil || got.Status != "configured" {
		t.Fatalf("HTTP MCP 应标记 configured 且不发起网络探测：%+v", response.MCPServers)
	}
	data, _ := json.Marshal(response)
	if strings.Contains(string(data), "should-not-leak") {
		t.Fatalf("capability 响应不应暴露 env secret：%s", string(data))
	}
}

func TestCapabilityListDoesNotReadRepoConfigAboveAuthorizedWorkspace(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	repoRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(repoRoot, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	workspace := filepath.Join(repoRoot, "packages", "ipad")
	if err := os.MkdirAll(filepath.Join(workspace, ".codex"), 0o755); err != nil {
		t.Fatal(err)
	}
	rootCodex := filepath.Join(repoRoot, ".codex")
	if err := os.MkdirAll(rootCodex, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(rootCodex, "config.toml"), []byte("[mcp_servers.root]\ncommand = \"root-mcp\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, ".codex", "config.toml"), []byte("[mcp_servers.workspace]\ncommand = \"missing-workspace-mcp\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "ipad", Name: "iPad", Path: workspace}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/capabilities/list", capabilityListRequest{Path: workspace})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("capability list 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response capabilityListResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 capabilityListResponse：%v", err)
	}
	if containsMCP(response.MCPServers, "root", "", "stdio", true) || findMCP(response.MCPServers, "root", "") != nil {
		t.Fatalf("不应读取授权 workspace 上层 Git 根的 MCP 配置：%+v", response.MCPServers)
	}
	if findMCP(response.MCPServers, "workspace", "") == nil {
		t.Fatalf("应保留授权 workspace 内的 MCP 配置：%+v", response.MCPServers)
	}
}

func TestCapabilityListRejectsPathOutsideAllowlist(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/capabilities/list", capabilityListRequest{Path: t.TempDir()})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("越界路径应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func requireGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skipf("git 不可用，跳过 Git 状态测试：%v", err)
	}
}

func newCommittedGitRepo(t *testing.T) string {
	t.Helper()
	repo := t.TempDir()
	runGitTestCommand(t, repo, "init")
	runGitTestCommand(t, repo, "config", "user.email", "test@example.invalid")
	runGitTestCommand(t, repo, "config", "user.name", "Test User")
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("before\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, repo, "add", "README.md")
	runGitTestCommand(t, repo, "commit", "-m", "initial")
	return repo
}

func runGitTestCommand(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, string(output))
	}
}

func gitTestOutput(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	output, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %s failed: %v", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(output))
}

func numberedLines(prefix string, count int) []string {
	lines := make([]string, 0, count)
	for i := 1; i <= count; i++ {
		lines = append(lines, fmt.Sprintf("%s %02d", prefix, i))
	}
	return lines
}

func splitGitDiffIntoSingleHunkPatches(t *testing.T, diff string) []string {
	t.Helper()
	if !strings.HasSuffix(diff, "\n") {
		diff += "\n"
	}

	lines := strings.SplitAfter(diff, "\n")
	header := make([]string, 0, 8)
	var hunk []string
	patches := []string{}
	for _, line := range lines {
		if strings.HasPrefix(line, "@@ ") {
			if len(hunk) > 0 {
				patches = append(patches, strings.Join(append(append([]string{}, header...), hunk...), ""))
			}
			hunk = []string{line}
			continue
		}
		if len(hunk) == 0 {
			header = append(header, line)
			continue
		}
		hunk = append(hunk, line)
	}
	if len(hunk) > 0 {
		patches = append(patches, strings.Join(append(append([]string{}, header...), hunk...), ""))
	}
	return patches
}

func readTestFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func canonicalTestPath(t *testing.T, path string) string {
	t.Helper()
	realPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return realPath
}

func TestActiveSessionSnapshotsFiltersByProjectBeforePagination(t *testing.T) {
	now := time.Unix(100, 0)
	list := []*session.Session{
		{ID: "sess_demo", ProjectID: "demo", Title: "demo", Status: "running", UpdatedAt: now},
		{ID: "sess_other", ProjectID: "other", Title: "other", Status: "running", UpdatedAt: now},
	}

	all := activeSessionSnapshots(list, "")
	if len(all) != 2 {
		t.Fatalf("全局列表应保留所有运行会话，got=%v", all)
	}

	demo := activeSessionSnapshots(list, "demo")
	if len(demo) != 1 || demo[0].ID != "sess_demo" {
		t.Fatalf("项目列表应在 snapshot 阶段排除无关运行会话，got=%v", demo)
	}

	missing := activeSessionSnapshots(list, "missing")
	if len(missing) != 0 {
		t.Fatalf("未知项目不应保留运行会话，got=%v", missing)
	}
}

func TestActiveSessionSnapshotWindowUsesCursorAndBoundedTopK(t *testing.T) {
	now := time.UnixMilli(1_780_308_003_000)
	list := []*session.Session{
		{ID: "sess_alpha", ProjectID: "demo", Title: "alpha", Status: "running", UpdatedAt: now},
		{ID: "sess_delta", ProjectID: "demo", Title: "delta", Status: "running", UpdatedAt: now},
		{ID: "sess_beta", ProjectID: "demo", Title: "beta", Status: "running", UpdatedAt: now},
		{ID: "sess_gamma", ProjectID: "demo", Title: "gamma", Status: "running", UpdatedAt: now},
		{ID: "sess_other", ProjectID: "other", Title: "other", Status: "running", UpdatedAt: now.Add(time.Second)},
	}

	firstWindow := activeSessionSnapshotWindow(list, "demo", sessionPageCursor{}, false, 2)
	if got := sessionSnapshotIDs(firstWindow); len(got) != 2 || got[0] != "sess_gamma" || got[1] != "sess_delta" {
		t.Fatalf("active window 应只保留按 updated_at/id 排序后的 top K，got=%v", got)
	}

	cursor := sessionPageCursor{ID: "sess_delta", UpdatedAtMS: now.UnixMilli()}
	secondWindow := activeSessionSnapshotWindow(list, "demo", cursor, true, 2)
	if got := sessionSnapshotIDs(secondWindow); len(got) != 2 || got[0] != "sess_beta" || got[1] != "sess_alpha" {
		t.Fatalf("active window 应在 cursor 后继续并保持稳定 id tie-breaker，got=%v", got)
	}
}

func TestDecodeSessionCursorRejectsMalformedNonEmptyCursor(t *testing.T) {
	if _, hasCursor, err := decodeSessionCursor(""); err != nil || hasCursor {
		t.Fatalf("空 cursor 应被视为未分页，has=%v err=%v", hasCursor, err)
	}

	invalidJSON := base64.RawURLEncoding.EncodeToString([]byte("{"))
	missingFields := base64.RawURLEncoding.EncodeToString([]byte(`{"id":"sess_1"}`))
	for _, raw := range []string{"not-base64!", invalidJSON, missingFields} {
		if _, hasCursor, err := decodeSessionCursor(raw); err == nil || hasCursor {
			t.Fatalf("非空无效 cursor 应返回错误且不启用分页，raw=%q has=%v err=%v", raw, hasCursor, err)
		}
	}
}

func authedRequest(t *testing.T, method, path string, body any) *http.Request {
	t.Helper()

	var reader *bytes.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(data)
	} else {
		reader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Authorization", "Bearer "+testToken)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req
}

func decodeJSON(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()

	var out map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&out); err != nil {
		t.Fatalf("响应不是合法 JSON：%v body=%q", err, rec.Body.String())
	}
	return out
}

func containsSkill(items []skillCapability, name string, scope string) bool {
	for _, item := range items {
		if item.Name == name && item.Scope == scope {
			return true
		}
	}
	return false
}

func containsMCP(items []mcpServerCapability, name string, plugin string, transport string, enabled bool) bool {
	for _, item := range items {
		if item.Name == name && item.Plugin == plugin && item.Transport == transport && item.Enabled == enabled {
			return true
		}
	}
	return false
}

func findMCP(items []mcpServerCapability, name string, plugin string) *mcpServerCapability {
	for i := range items {
		if items[i].Name == name && items[i].Plugin == plugin {
			return &items[i]
		}
	}
	return nil
}

func containsWorktreeBranch(items []worktreeBranchItem, name string, kind string, current bool, def bool) bool {
	for _, item := range items {
		if item.Name == name && item.Kind == kind && item.IsCurrent == current && item.IsDefault == def {
			return true
		}
	}
	return false
}

func sessionSnapshotIDs(items []session.SessionSnapshot) []string {
	ids := make([]string, 0, len(items))
	for _, item := range items {
		ids = append(ids, item.ID)
	}
	return ids
}

func TestHealthzDoesNotRequireAuth(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 healthz 返回 200，实际 %d", rec.Code)
	}
	body := decodeJSON(t, rec)
	if body["ok"] != true || body["version"] != "test" {
		t.Fatalf("healthz 响应异常：%v", body)
	}
}

func TestVersionAndDoctorEndpointsRequireBearerAndKeepMobileResponseContracts(t *testing.T) {
	server := newTestServer(t)

	for _, endpoint := range []string{"/api/version", "/api/doctor"} {
		t.Run(endpoint+" rejects missing bearer", func(t *testing.T) {
			rec := httptest.NewRecorder()
			server.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, endpoint, nil))
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("%s 必须拒绝未认证请求，got=%d body=%s", endpoint, rec.Code, rec.Body.String())
			}
			if rec.Header().Get("WWW-Authenticate") != "Bearer" {
				t.Fatalf("%s 的 401 必须声明 Bearer challenge，got=%q", endpoint, rec.Header().Get("WWW-Authenticate"))
			}
		})
	}

	version := httptest.NewRecorder()
	server.handler.ServeHTTP(version, authedRequest(t, http.MethodGet, "/api/version", nil))
	if version.Code != http.StatusOK {
		t.Fatalf("version 应返回 200，got=%d body=%s", version.Code, version.Body.String())
	}
	versionBody := decodeJSON(t, version)
	if versionBody["name"] != "agentd" || versionBody["version"] != "test" {
		t.Fatalf("version 响应必须保留移动端所需字段：%v", versionBody)
	}

	doctor := httptest.NewRecorder()
	server.handler.ServeHTTP(doctor, authedRequest(t, http.MethodGet, "/api/doctor", nil))
	if doctor.Code != http.StatusOK {
		t.Fatalf("doctor 应返回 200，got=%d body=%s", doctor.Code, doctor.Body.String())
	}
	doctorBody := decodeJSON(t, doctor)
	if doctorBody["version"] != "test" || doctorBody["listen"] == "" {
		t.Fatalf("doctor 响应必须保留版本和监听地址：%v", doctorBody)
	}
	checks, ok := doctorBody["checks"].([]any)
	if !ok || len(checks) == 0 {
		t.Fatalf("doctor 响应必须包含结构化 checks：%v", doctorBody)
	}
}

func TestReadyzRequiresBearerAndReturns503WhenDoctorFails(t *testing.T) {
	server := newTestServer(t)

	unauthorized := httptest.NewRecorder()
	server.handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/readyz", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("readyz 必须保留 Bearer 鉴权，实际 %d", unauthorized.Code)
	}

	ready := httptest.NewRecorder()
	server.handler.ServeHTTP(ready, authedRequest(t, http.MethodGet, "/api/readyz", nil))
	if ready.Code != http.StatusServiceUnavailable {
		t.Fatalf("doctor 失败时 readyz 应返回 503，实际 %d body=%s", ready.Code, ready.Body.String())
	}
	body := decodeJSON(t, ready)
	if body["ok"] != false || body["version"] != "test" {
		t.Fatalf("readyz 503 应保留 doctor 结果：%v", body)
	}

	// readiness 失败不影响 liveness，守护进程仍能确认 HTTP 进程存活。
	live := httptest.NewRecorder()
	server.handler.ServeHTTP(live, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if live.Code != http.StatusOK {
		t.Fatalf("doctor 失败时 healthz 仍应返回 200，实际 %d", live.Code)
	}
}

func TestReadyzReturns200WhenDoctorPasses(t *testing.T) {
	const upstreamToken = "readyz-independent-upstream-token"
	upstreamURL, _, connections := fakeAppServerUpstreamWithAuth(t, upstreamToken, nil)
	tokenFile := testAppServerTokenFile(t, upstreamToken)
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		// readiness 只证明当前已启动的服务可承接请求；缺失的 CLI/Claude bridge
		// 由完整 doctor 报告，不得让高频 readyz 执行外部进程或制造假离线。
		cfg.Codex.Bin = filepath.Join(t.TempDir(), "missing-codex")
		cfg.Claude = config.ClaudeConfig{
			Enabled:   true,
			BridgeBin: filepath.Join(t.TempDir(), "missing-claude-bridge"),
		}
		cfg.Runtime.Type = "codex_app_server"
		cfg.AppServer = config.AppServerConfig{
			Transport:   "ws",
			Managed:     false,
			Listen:      upstreamURL,
			WSTokenFile: tokenFile,
		}
	})

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/readyz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("doctor 通过时 readyz 应返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["ok"] != true || body["version"] != "test" {
		t.Fatalf("readyz 200 应返回 doctor ok=true：%v", body)
	}
	if connections.Load() != 1 {
		t.Fatalf("readyz 必须完成一次带独立 token 的 upstream WebSocket 握手：%d", connections.Load())
	}
}

func TestProjectsRejectsMissingBearerToken(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/projects", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("期望未携带 token 被拒绝，实际 %d", rec.Code)
	}
	if rec.Header().Get("WWW-Authenticate") != "Bearer" {
		t.Fatalf("401 应保留 Bearer challenge，实际 %q", rec.Header().Get("WWW-Authenticate"))
	}
	if !strings.Contains(rec.Header().Get("Content-Type"), "application/json") {
		t.Fatalf("401 应返回 JSON，Content-Type=%q", rec.Header().Get("Content-Type"))
	}
	body := decodeJSON(t, rec)
	if body["error"] != "unauthorized" {
		t.Fatalf("401 JSON body 异常：%v", body)
	}
}

func TestProjectsReturnsConfiguredProjects(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/projects", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("期望项目列表返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	items, ok := body["projects"].([]any)
	if !ok || len(items) != 1 {
		t.Fatalf("项目列表响应异常：%v", body)
	}
	project := items[0].(map[string]any)
	if project["id"] != "demo" || project["name"] != "Demo" {
		t.Fatalf("项目字段异常：%v", project)
	}
	if !filepath.IsAbs(project["path"].(string)) {
		t.Fatalf("项目路径应为绝对路径：%v", project)
	}
}

func TestWorkspaceResolveReturnsCanonicalChildWorkspace(t *testing.T) {
	server := newTestServer(t)

	projectDir := configuredProjectPath(t, server.handler)
	childDir := filepath.Join(projectDir, "ios")
	if err := os.Mkdir(childDir, 0o755); err != nil {
		t.Fatal(err)
	}
	realChildDir, err := filepath.EvalSymlinks(childDir)
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": childDir,
	}))

	if rec.Code != http.StatusOK {
		t.Fatalf("期望 workspace resolve 返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	workspace, ok := body["workspace"].(map[string]any)
	if !ok {
		t.Fatalf("workspace 响应异常：%v", body)
	}
	if workspace["id"] == "" || !strings.HasPrefix(workspace["id"].(string), "ws_") {
		t.Fatalf("workspace id 应由服务端生成稳定 hash：%v", workspace)
	}
	if workspace["name"] != "ios" || workspace["path"] != realChildDir {
		t.Fatalf("workspace 基础字段异常：%v", workspace)
	}
	if workspace["root_project_id"] != "demo" || workspace["trusted"] != true || workspace["can_start_session"] != true {
		t.Fatalf("workspace 应继承 allowlist 根项目能力：%v", workspace)
	}
}

func TestWorkspaceResolveReturnsDeepChildOutsideProjectList(t *testing.T) {
	server := newTestServer(t)

	projectDir := configuredProjectPath(t, server.handler)
	deepDir := filepath.Join(projectDir, "apps", "mobile", "ios")
	if err := os.MkdirAll(deepDir, 0o755); err != nil {
		t.Fatal(err)
	}
	realDeepDir, err := filepath.EvalSymlinks(deepDir)
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": deepDir,
	}))

	if rec.Code != http.StatusOK {
		t.Fatalf("授权根内深层目录应允许 resolve，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	workspace, ok := body["workspace"].(map[string]any)
	if !ok {
		t.Fatalf("workspace 响应异常：%v", body)
	}
	if workspace["path"] != realDeepDir {
		t.Fatalf("workspace 应返回深层目录真实路径，实际 %v", workspace)
	}
	if workspace["root_project_id"] != "demo" || workspace["root_project_path"] != projectDir {
		t.Fatalf("深层目录必须继承根项目授权，实际 %v", workspace)
	}
}

func TestWorkspaceResolveAllowsBrowseRootDirectoryWithSelfBinding(t *testing.T) {
	browseRoot := t.TempDir()
	financeDir := filepath.Join(browseRoot, "finance")
	if err := os.Mkdir(financeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.BrowseRoots = []string{browseRoot}
	})

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": financeDir,
	}))
	if rec.Code != http.StatusOK {
		t.Fatalf("browse root 内目录应可 resolve，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	realFinanceDir, err := filepath.EvalSymlinks(financeDir)
	if err != nil {
		t.Fatal(err)
	}
	body := decodeJSON(t, rec)
	workspace, ok := body["workspace"].(map[string]any)
	if !ok {
		t.Fatalf("workspace 响应异常：%v", body)
	}
	if workspace["path"] != realFinanceDir || workspace["name"] != "finance" {
		t.Fatalf("browse workspace 基础字段异常：%v", workspace)
	}
	// browse workspace 不挂在任何项目下：root 字段自指，gateway 按精确 cwd 绑定。
	if workspace["root_project_id"] != workspace["id"] || workspace["root_project_path"] != realFinanceDir {
		t.Fatalf("browse workspace root 字段应自指：%v", workspace)
	}

	// browse root 不参与项目发现：/api/projects 仍只返回配置项目。
	rec = httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/projects", nil))
	projectsBody := decodeJSON(t, rec)
	items, ok := projectsBody["projects"].([]any)
	if !ok || len(items) != 1 {
		t.Fatalf("browse_roots 不应膨胀项目列表：%v", projectsBody)
	}

	// browse root 外的路径仍被拒。
	outside := t.TempDir()
	rec = httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": outside,
	}))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("browse root 外路径应被拒绝，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestWorkspaceResolveRejectsOutsidePathWithoutLeakingDetails(t *testing.T) {
	server := newTestServer(t)
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.Mkdir(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": outside,
	}))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("allowlist 外路径应被拒绝，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), outside) {
		t.Fatalf("拒绝响应不应泄漏外部路径：%s", rec.Body.String())
	}
}

func TestWorkspaceResolveRejectsFileInsideAllowlist(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	filePath := filepath.Join(projectDir, "README.md")
	if err := os.WriteFile(filePath, []byte("demo"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/workspaces/resolve", map[string]string{
		"path": filePath,
	}))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("allowlist 内文件不能作为 workspace，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}

func configuredProjectPath(t *testing.T, handler http.Handler) string {
	t.Helper()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/projects", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("读取项目列表失败：%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	items, ok := body["projects"].([]any)
	if !ok || len(items) == 0 {
		t.Fatalf("项目列表响应异常：%v", body)
	}
	project := items[0].(map[string]any)
	path, ok := project["path"].(string)
	if !ok || path == "" {
		t.Fatalf("项目 path 异常：%v", project)
	}
	return path
}

func TestLegacySessionsEndpointsAreRemoved(t *testing.T) {
	server := newTestServer(t)
	for _, path := range []string{
		"/api/sessions",
		"/api/sessions/codex_thread-demo",
		"/api/sessions/codex_thread-demo/messages",
		"/api/sessions/codex_thread-demo/trace",
		"/api/sessions/codex_thread-demo/ws",
	} {
		rec := httptest.NewRecorder()
		server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, path, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("%s 应已下线并返回 404，实际 %d body=%s", path, rec.Code, rec.Body.String())
		}
	}
}

func TestWebPWAStaticRootIsRemoved(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("Web/PWA 根页面应已下线并返回 404，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}
