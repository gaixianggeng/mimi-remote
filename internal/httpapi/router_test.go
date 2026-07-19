package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

const testToken = "0123456789abcdef0123456789abcdef"

type testServer struct {
	handler http.Handler
	manager *session.Manager
}

func newTestServer(t *testing.T) testServer {
	t.Helper()
	return newTestServerWithConfig(t, nil)
}

func newTestServerWithConfig(t *testing.T, customize func(*config.Config)) testServer {
	t.Helper()

	projectDir := t.TempDir()
	cfg := config.Config{
		Listen: "127.0.0.1:0",
		Auth:   config.AuthConfig{Token: testToken},
		Codex: config.CodexConfig{
			Bin: "/bin/cat",
			Env: map[string]string{"TERM": "xterm-256color"},
		},
		Session: config.SessionConfig{OutputBufferBytes: 8 * 1024},
		Projects: []config.ProjectConfig{{
			ID:   "demo",
			Name: "Demo",
			Path: projectDir,
		}},
	}
	if customize != nil {
		customize(&cfg)
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	manager := session.NewManager(session.Options{
		CodexBin:     cfg.Codex.Bin,
		DefaultArgs:  cfg.Codex.DefaultArgs,
		Env:          cfg.Codex.Env,
		OutputBuffer: cfg.Session.OutputBufferBytes,
	})
	t.Cleanup(manager.Shutdown)

	checker := doctor.NewChecker("test", cfg, registry)
	return testServer{
		handler: NewRouter(cfg, registry, manager, checker, "test"),
		manager: manager,
	}
}

func TestSameOriginOrNoOrigin(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://agentd.local/api/app-server/ws", nil)
	req.Host = "agentd.local"
	if !sameOriginOrNoOrigin(req) {
		t.Fatal("没有 Origin 的原生客户端/WebSocket 请求应允许")
	}

	req = httptest.NewRequest(http.MethodGet, "http://agentd.local/api/app-server/ws", nil)
	req.Host = "agentd.local"
	req.Header.Set("Origin", "http://agentd.local")
	if !sameOriginOrNoOrigin(req) {
		t.Fatal("同源浏览器 WebSocket 应允许")
	}

	req = httptest.NewRequest(http.MethodGet, "http://agentd.local/api/app-server/ws", nil)
	req.Host = "agentd.local"
	req.Header.Set("Origin", "http://evil.local")
	if sameOriginOrNoOrigin(req) {
		t.Fatal("跨源 WebSocket 不应通过 Origin 校验")
	}
}

func TestLoggingRedactsQueryTokens(t *testing.T) {
	server := newTestServer(t)
	var logs bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() {
		log.SetOutput(previous)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/projects?Token=secret-token&access_token=secret-access&Authorization=secret-auth&pair_sig=secret-pair&limit=1", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("请求应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	text := logs.String()
	for _, secret := range []string{"secret-token", "secret-access", "secret-auth", "secret-pair"} {
		if strings.Contains(text, secret) {
			t.Fatalf("日志不应包含敏感 query 值 %q：%s", secret, text)
		}
	}
	if !strings.Contains(text, "redacted") {
		t.Fatalf("日志应包含脱敏占位：%s", text)
	}
}

func TestPairingClaimExchangesValidTicketWithoutBearerToken(t *testing.T) {
	server := newTestServer(t)
	issuedAt := time.Now().UTC().Add(-time.Minute)
	expiresAt := time.Now().UTC().Add(9 * time.Minute)
	req := authedRequest(t, http.MethodPost, "/api/pair/claim", pairingClaimRequest{
		Endpoint:  "http://100.64.0.1:8787",
		IssuedAt:  issuedAt.Format(time.RFC3339),
		ExpiresAt: expiresAt.Format(time.RFC3339),
		Signature: auth.SignPairingTicket(testToken, "http://100.64.0.1:8787", issuedAt.Format(time.RFC3339), expiresAt.Format(time.RFC3339)),
	})
	req.Header.Del("Authorization")
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("合法配对票据应可无 Bearer 兑换，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response pairingClaimResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 pairingClaimResponse：%v", err)
	}
	if response.Endpoint != "http://100.64.0.1:8787" || response.Token != testToken {
		t.Fatalf("pair claim 响应异常：%+v", response)
	}
}

func TestPairingClaimRejectsExpiredTicket(t *testing.T) {
	server := newTestServer(t)
	issuedAt := time.Now().UTC().Add(-20 * time.Minute)
	expiresAt := time.Now().UTC().Add(-10 * time.Minute)
	req := authedRequest(t, http.MethodPost, "/api/pair/claim", pairingClaimRequest{
		Endpoint:  "http://100.64.0.1:8787",
		IssuedAt:  issuedAt.Format(time.RFC3339),
		ExpiresAt: expiresAt.Format(time.RFC3339),
		Signature: auth.SignPairingTicket(testToken, "http://100.64.0.1:8787", issuedAt.Format(time.RFC3339), expiresAt.Format(time.RFC3339)),
	})
	req.Header.Del("Authorization")
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("过期配对票据应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestCodexHistoryDebugDisabledByDefault(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/debug/codex-history?limit=1", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("debug history 默认应关闭，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "not found") {
		t.Fatalf("debug history 关闭时应给出明确文案：%s", rec.Body.String())
	}
}

func TestCodexHistoryDebugDisabledDoesNotRequireAuth(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/debug/codex-history?limit=1", nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("debug history 默认关闭时不应先暴露 auth challenge，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestCodexHistoryDebugCanBeEnabled(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Debug.EnableCodexHistory = true
	})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/debug/codex-history?limit=1", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("debug history 显式打开后应可用，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "database_path") || !strings.Contains(rec.Body.String(), "rows") {
		t.Fatalf("debug history 响应应包含诊断 payload：%s", rec.Body.String())
	}
}

func TestRelayDiagnosticsRequiresAuthAndReportsHTTPMetrics(t *testing.T) {
	server := newTestServer(t)

	unauthorized := httptest.NewRecorder()
	server.handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/diagnostics/relay", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("relay diagnostics 必须要求 Bearer Token，got=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/projects", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("预置 /api/projects 请求应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}

	diag := httptest.NewRecorder()
	server.handler.ServeHTTP(diag, authedRequest(t, http.MethodGet, "/api/diagnostics/relay", nil))
	if diag.Code != http.StatusOK {
		t.Fatalf("relay diagnostics 应返回 200，got=%d body=%s", diag.Code, diag.Body.String())
	}
	body := decodeJSON(t, diag)
	httpStats, ok := body["http"].(map[string]any)
	if !ok {
		t.Fatalf("diagnostics 应包含 http 指标：%v", body)
	}
	if got := int(httpStats["total_requests"].(float64)); got < 1 {
		t.Fatalf("http total_requests 应记录已完成 API 请求，got=%d body=%v", got, httpStats)
	}
	recent, ok := httpStats["recent"].([]any)
	if !ok || len(recent) == 0 {
		t.Fatalf("http recent 应包含最近请求样本：%v", httpStats)
	}
	if guide, ok := body["guide"].(map[string]any); !ok || guide["bandwidth_signal"] == "" || guide["server_signal"] == "" {
		t.Fatalf("diagnostics 应返回读数说明：%v", body["guide"])
	}
}

func TestGitStatusReturnsReadonlyDiffForAllowedWorkspace(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("after\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/status", gitStatusRequest{Path: repo})

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("git status 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if !response.IsRepository {
		t.Fatalf("Git 仓库应标记为 is_repository=true：%+v", response)
	}
	if !strings.Contains(response.StatusText, "README.md") {
		t.Fatalf("status 应包含变更文件：%+v", response)
	}
	if !strings.Contains(response.UnstagedDiff, "+after") {
		t.Fatalf("diff 应包含未暂存变更：%s", response.UnstagedDiff)
	}
	if len(response.Files) != 1 || response.Files[0].Path != "README.md" || !response.Files[0].Unstaged {
		t.Fatalf("响应应包含结构化文件状态：%+v", response.Files)
	}
}

func TestGitActionStagesAndUnstagesAllowedFile(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("after\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/action", gitActionRequest{
		Path:   repo,
		Action: "stage",
		Files:  []string{"README.md"},
	})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("stage 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var staged gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&staged); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if !strings.Contains(staged.StagedDiff, "+after") || strings.Contains(staged.UnstagedDiff, "+after") {
		t.Fatalf("stage 后应只有 staged diff，got staged=%q unstaged=%q", staged.StagedDiff, staged.UnstagedDiff)
	}
	if len(staged.Files) != 1 || !staged.Files[0].Staged || staged.Files[0].Unstaged {
		t.Fatalf("stage 后文件状态异常：%+v", staged.Files)
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/git/action", gitActionRequest{
		Path:   repo,
		Action: "unstage",
		Files:  []string{"README.md"},
	})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("unstage 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var unstaged gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&unstaged); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if strings.Contains(unstaged.StagedDiff, "+after") || !strings.Contains(unstaged.UnstagedDiff, "+after") {
		t.Fatalf("unstage 后应回到 unstaged diff，got staged=%q unstaged=%q", unstaged.StagedDiff, unstaged.UnstagedDiff)
	}
}

func TestGitPatchActionStagesAndRevertsSingleHunk(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	baseLines := numberedLines("line", 20)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte(strings.Join(baseLines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, repo, "add", "README.md")
	runGitTestCommand(t, repo, "commit", "-m", "baseline lines")

	changedLines := append([]string(nil), baseLines...)
	changedLines[1] = "changed 2"
	changedLines[17] = "changed 18"
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte(strings.Join(changedLines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	patches := splitGitDiffIntoSingleHunkPatches(t, gitTestOutput(t, repo, "diff", "-U0", "--", "README.md"))
	if len(patches) != 2 {
		t.Fatalf("测试 diff 应拆出两个 hunk，got=%d patches=%q", len(patches), patches)
	}

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/action", gitActionRequest{
		Path:   repo,
		Action: "stage_patch",
		Patch:  patches[0],
	})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("stage_patch 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var staged gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&staged); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if !strings.Contains(staged.StagedDiff, "changed 2") || strings.Contains(staged.StagedDiff, "changed 18") {
		t.Fatalf("stage_patch 应只暂存第一个 hunk，staged=%q", staged.StagedDiff)
	}
	if !strings.Contains(staged.UnstagedDiff, "changed 18") {
		t.Fatalf("stage_patch 后第二个 hunk 应仍未暂存，unstaged=%q", staged.UnstagedDiff)
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/git/action", gitActionRequest{
		Path:   repo,
		Action: "revert_patch",
		Patch:  patches[1],
	})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("revert_patch 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	readme := readTestFile(t, filepath.Join(repo, "README.md"))
	if strings.Contains(readme, "changed 18") || !strings.Contains(readme, "changed 2") {
		t.Fatalf("revert_patch 应只撤销第二个 hunk，README=%q", readme)
	}
	var reverted gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&reverted); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if !strings.Contains(reverted.StagedDiff, "changed 2") || strings.Contains(reverted.UnstagedDiff, "changed 18") {
		t.Fatalf("revert_patch 后状态异常，staged=%q unstaged=%q", reverted.StagedDiff, reverted.UnstagedDiff)
	}
}

func TestGitActionRevertsTrackedWorktreeChangeWithoutDeletingUntrackedFile(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("after\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	untrackedPath := filepath.Join(repo, "NOTES.md")
	if err := os.WriteFile(untrackedPath, []byte("draft\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/action", gitActionRequest{
		Path:   repo,
		Action: "revert",
		Files:  []string{"README.md"},
	})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("revert 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}

	readme, err := os.ReadFile(filepath.Join(repo, "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	if string(readme) != "before\n" {
		t.Fatalf("revert 应恢复已跟踪文件，got=%q", string(readme))
	}
	if _, err := os.Stat(untrackedPath); err != nil {
		t.Fatalf("revert 不应删除未跟踪文件：%v", err)
	}
	var status gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&status); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if !strings.Contains(status.StatusText, "NOTES.md") || strings.Contains(status.StatusText, "README.md") {
		t.Fatalf("revert 后只应剩未跟踪文件，status=%q", status.StatusText)
	}
}

func TestGitActionRejectsUnsafeFilePath(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/action", gitActionRequest{
		Path:   repo,
		Action: "stage",
		Files:  []string{"../outside.txt"},
	})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("越界文件路径应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestGitPatchActionRejectsUnsafePatchPath(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/action", gitActionRequest{
		Path:   repo,
		Action: "stage_patch",
		Patch:  "diff --git a/../secret b/../secret\n--- a/../secret\n+++ b/../secret\n@@ -1 +1 @@\n-old\n+new\n",
	})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("越界 patch 路径应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestGitCommitCreatesLocalCommitFromStagedFiles(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	previousHead := gitTestOutput(t, repo, "rev-parse", "HEAD")
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("after\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, repo, "add", "README.md")

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/commit", gitCommitRequest{
		Path:    repo,
		Message: "update readme",
	})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("commit 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	nextHead := gitTestOutput(t, repo, "rev-parse", "HEAD")
	if nextHead == previousHead {
		t.Fatalf("commit 后 HEAD 应变化，仍为 %s", nextHead)
	}
	var status gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&status); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if status.StatusText != "" || status.StagedDiff != "" || status.UnstagedDiff != "" || len(status.Files) != 0 {
		t.Fatalf("commit 后工作区应干净：%+v", status)
	}
}

func TestGitCommitRejectsStagedFilesOutsideWorkspaceScope(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	appDir := filepath.Join(repo, "app")
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(appDir, "main.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("outside scope\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, repo, "add", "app/main.go", "README.md")

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "app", Name: "App", Path: appDir}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/commit", gitCommitRequest{
		Path:    appDir,
		Message: "update app",
	})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("scope 外暂存文件应拒绝提交，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "不在当前工作区范围内") {
		t.Fatalf("错误应解释 scope 外暂存文件，body=%s", rec.Body.String())
	}
	if head := gitTestOutput(t, repo, "rev-parse", "--short", "HEAD"); head == "" {
		t.Fatal("拒绝提交后仓库 HEAD 应仍可读取")
	}
}

func TestGitCommitRejectsBlankMessage(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/commit", gitCommitRequest{
		Path:    repo,
		Message: " ",
	})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("空 commit message 应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestGitPushPushesCurrentBranchToRemote(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	remote := filepath.Join(t.TempDir(), "origin.git")
	runGitTestCommand(t, t.TempDir(), "init", "--bare", remote)
	runGitTestCommand(t, repo, "remote", "add", "origin", remote)
	branch := gitTestOutput(t, repo, "branch", "--show-current")
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/push", gitPushRequest{Path: repo})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("push 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response gitPushResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 gitPushResponse：%v", err)
	}
	if response.Remote != "origin" || response.Branch != branch || !response.Status.IsRepository {
		t.Fatalf("push 响应异常：%+v", response)
	}
	remoteHead := gitTestOutput(t, remote, "rev-parse", branch)
	localHead := gitTestOutput(t, repo, "rev-parse", branch)
	if remoteHead != localHead {
		t.Fatalf("remote 分支应指向本地 HEAD，remote=%s local=%s", remoteHead, localHead)
	}
}

func TestGitPushRejectsUnsafeRemote(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/push", gitPushRequest{
		Path:   repo,
		Remote: "-origin",
	})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("不安全 remote 应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestGitQuickPublishStagesCommitsAndPushesAfterConfirmation(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	remote := filepath.Join(t.TempDir(), "origin.git")
	runGitTestCommand(t, t.TempDir(), "init", "--bare", remote)
	runGitTestCommand(t, repo, "remote", "add", "origin", remote)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("quick publish\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "NEW.md"), []byte("new file\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rejected := httptest.NewRecorder()
	server.handler.ServeHTTP(rejected, authedRequest(t, http.MethodPost, "/api/git/quick-publish", gitQuickPublishRequest{
		Path:    repo,
		Message: "feat: quick publish",
	}))
	if rejected.Code != http.StatusForbidden {
		t.Fatalf("未确认的快捷发布应拒绝，got=%d body=%s", rejected.Code, rejected.Body.String())
	}

	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/git/quick-publish", gitQuickPublishRequest{
		Path:      repo,
		Message:   "feat: quick publish",
		Confirmed: true,
	}))
	if rec.Code != http.StatusOK {
		t.Fatalf("快捷发布应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response gitQuickPublishResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 gitQuickPublishResponse：%v", err)
	}
	if !response.Committed || response.Message != "feat: quick publish" || len(response.Status.Files) != 0 {
		t.Fatalf("快捷发布响应异常：%+v", response)
	}
	if subject := gitTestOutput(t, repo, "log", "-1", "--format=%s"); subject != "feat: quick publish" {
		t.Fatalf("commit message 不正确：%q", subject)
	}
	branch := gitTestOutput(t, repo, "branch", "--show-current")
	if local, remoteHead := gitTestOutput(t, repo, "rev-parse", "HEAD"), gitTestOutput(t, remote, "rev-parse", branch); local != remoteHead {
		t.Fatalf("快捷发布后远端应指向本地 HEAD，local=%s remote=%s", local, remoteHead)
	}
}

func TestGitTestFlightRequiresHostPreflightAndRunsAsBackgroundJob(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	iosDir := filepath.Join(repo, "ios", "Example")
	if err := os.MkdirAll(iosDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(iosDir, "project.yml"), []byte("name: Example\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, repo, "add", "ios/Example/project.yml")
	runGitTestCommand(t, repo, "commit", "-m", "add ios project")

	fakeBin := t.TempDir()
	argsFile := filepath.Join(t.TempDir(), "testflight.args")
	readyFile := filepath.Join(t.TempDir(), "testflight.ready")
	fakeCommand := fmt.Sprintf(`#!/bin/sh
if [ "$1" = "--check" ]; then
	if [ ! -f %q ]; then
		echo "missing local TestFlight config" >&2
		exit 1
	fi
  echo "preflight ok"
  exit 0
fi
printf '%%s\n' "$@" > %q
echo "upload started"
sleep 0.05
echo "upload completed"
`, readyFile, argsFile)
	if err := os.WriteFile(filepath.Join(fakeBin, "git-testflight-push"), []byte(fakeCommand), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	unavailableRecorder := httptest.NewRecorder()
	server.handler.ServeHTTP(unavailableRecorder, authedRequest(t, http.MethodPost, "/api/git/testflight/status", gitTestFlightStatusRequest{Path: repo}))
	if unavailableRecorder.Code != http.StatusOK {
		t.Fatalf("TestFlight 状态应成功，got=%d body=%s", unavailableRecorder.Code, unavailableRecorder.Body.String())
	}
	var unavailable gitTestFlightStatusResponse
	if err := json.NewDecoder(unavailableRecorder.Body).Decode(&unavailable); err != nil {
		t.Fatal(err)
	}
	if !unavailable.Capability.IsIOSProject || unavailable.Capability.Available || !strings.Contains(unavailable.Capability.Reason, "missing local TestFlight config") {
		t.Fatalf("主机预检失败时必须禁用 TestFlight：%+v", unavailable)
	}

	rejectedRecorder := httptest.NewRecorder()
	server.handler.ServeHTTP(rejectedRecorder, authedRequest(t, http.MethodPost, "/api/git/testflight/run", gitTestFlightRunRequest{
		Path:      repo,
		Confirmed: true,
	}))
	if rejectedRecorder.Code != http.StatusPreconditionFailed {
		t.Fatalf("主机预检失败时必须拒绝发布，got=%d body=%s", rejectedRecorder.Code, rejectedRecorder.Body.String())
	}

	if err := os.WriteFile(readyFile, []byte("ready\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	statusRecorder := httptest.NewRecorder()
	server.handler.ServeHTTP(statusRecorder, authedRequest(t, http.MethodPost, "/api/git/testflight/status", gitTestFlightStatusRequest{Path: repo}))
	var initial gitTestFlightStatusResponse
	if err := json.NewDecoder(statusRecorder.Body).Decode(&initial); err != nil {
		t.Fatal(err)
	}
	if !initial.Capability.IsIOSProject || !initial.Capability.Available || initial.Job != nil {
		t.Fatalf("本机预检通过后应开放 TestFlight：%+v", initial)
	}

	runRecorder := httptest.NewRecorder()
	server.handler.ServeHTTP(runRecorder, authedRequest(t, http.MethodPost, "/api/git/testflight/run", gitTestFlightRunRequest{
		Path:       repo,
		WhatToTest: "验证快捷发布",
		Confirmed:  true,
	}))
	if runRecorder.Code != http.StatusAccepted {
		t.Fatalf("TestFlight 后台任务应被接受，got=%d body=%s", runRecorder.Code, runRecorder.Body.String())
	}

	deadline := time.Now().Add(3 * time.Second)
	var completed gitTestFlightStatusResponse
	for time.Now().Before(deadline) {
		rec := httptest.NewRecorder()
		server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/git/testflight/status", gitTestFlightStatusRequest{Path: repo}))
		if rec.Code != http.StatusOK {
			t.Fatalf("轮询 TestFlight 状态失败，got=%d body=%s", rec.Code, rec.Body.String())
		}
		if err := json.NewDecoder(rec.Body).Decode(&completed); err != nil {
			t.Fatal(err)
		}
		if completed.Job != nil && completed.Job.State != "running" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if completed.Job == nil || completed.Job.State != "succeeded" || !strings.Contains(completed.Job.Output, "upload completed") {
		t.Fatalf("TestFlight 后台任务未成功完成：%+v", completed.Job)
	}
	if args := strings.Split(strings.TrimSpace(readTestFile(t, argsFile)), "\n"); strings.Join(args, " ") != "--what-to-test 验证快捷发布" {
		t.Fatalf("TestFlight 参数异常：%q", args)
	}
}

func TestGitPullRequestCreatesDraftWithGH(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	fakeBin := t.TempDir()
	argsFile := filepath.Join(t.TempDir(), "gh.args")
	pwdFile := filepath.Join(t.TempDir(), "gh.pwd")
	ghScript := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$PWD\" > %q\nprintf '%%s\\n' \"$@\" > %q\necho 'https://github.com/example/repo/pull/1'\n", pwdFile, argsFile)
	if err := os.WriteFile(filepath.Join(fakeBin, "gh"), []byte(ghScript), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/pull-request", gitPullRequestRequest{
		Path:  repo,
		Title: "Add review changes",
		Body:  "Summary",
		Draft: true,
	})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("PR 创建应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response gitPullRequestResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 gitPullRequestResponse：%v", err)
	}
	if response.URL != "https://github.com/example/repo/pull/1" || response.Branch == "" {
		t.Fatalf("PR 响应异常：%+v", response)
	}
	gotPWD := canonicalTestPath(t, strings.TrimSpace(readTestFile(t, pwdFile)))
	wantPWD := canonicalTestPath(t, repo)
	if gotPWD != wantPWD {
		t.Fatalf("gh 应在仓库目录执行，got=%s want=%s", gotPWD, wantPWD)
	}
	args := strings.Split(strings.TrimSpace(readTestFile(t, argsFile)), "\n")
	if strings.Join(args, " ") != "pr create --title Add review changes --body Summary --draft" {
		t.Fatalf("gh 参数异常：%q", args)
	}
}

func TestGitPullRequestStatusReadsCurrentBranchPR(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	fakeBin := t.TempDir()
	argsFile := filepath.Join(t.TempDir(), "gh.status.args")
	ghScript := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$@\" > %q\ncat <<'JSON'\n{\"number\":42,\"title\":\"Review changes\",\"state\":\"OPEN\",\"url\":\"https://github.com/example/repo/pull/42\",\"isDraft\":true,\"reviewDecision\":\"REVIEW_REQUIRED\",\"mergeStateStatus\":\"CLEAN\",\"headRefName\":\"feature/mobile\",\"baseRefName\":\"main\"}\nJSON\n", argsFile)
	if err := os.WriteFile(filepath.Join(fakeBin, "gh"), []byte(ghScript), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/pull-request/status", gitPullRequestStatusRequest{Path: repo})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("PR 状态应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response gitPullRequestStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 gitPullRequestStatusResponse：%v", err)
	}
	if !response.Exists || response.Number != 42 || response.URL != "https://github.com/example/repo/pull/42" || !response.IsDraft {
		t.Fatalf("PR 状态响应异常：%+v", response)
	}
	args := strings.Split(strings.TrimSpace(readTestFile(t, argsFile)), "\n")
	want := "pr view --json number,title,state,url,isDraft,reviewDecision,mergeStateStatus,headRefName,baseRefName"
	if strings.Join(args, " ") != want {
		t.Fatalf("gh 参数异常：%q want=%q", args, want)
	}
}

func TestGitPullRequestStatusReturnsEmptyWhenCurrentBranchHasNoPR(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	fakeBin := t.TempDir()
	ghScript := "#!/bin/sh\necho 'no pull requests found for branch' >&2\nexit 1\n"
	if err := os.WriteFile(filepath.Join(fakeBin, "gh"), []byte(ghScript), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/git/pull-request/status", gitPullRequestStatusRequest{Path: repo})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("无 PR 应返回空状态而不是失败，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response gitPullRequestStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 gitPullRequestStatusResponse：%v", err)
	}
	if response.Exists || response.URL != "" {
		t.Fatalf("无 PR 响应异常：%+v", response)
	}
}

func TestWorktreeCreateReturnsOpenableWorkspace(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	worktreesRoot := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/worktrees/create", worktreeCreateRequest{
		Path:   repo,
		Name:   "Review Branch",
		Branch: "mimi/review-branch",
	})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("worktree create 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response worktreeCreateResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 worktreeCreateResponse：%v", err)
	}
	if response.Workspace.ID == "" || !strings.HasPrefix(response.Workspace.ID, "ws_") {
		t.Fatalf("worktree workspace 应有稳定 id：%+v", response.Workspace)
	}
	if response.Workspace.RootProjectID != "repo" || response.Workspace.RootProjectPath != repo {
		t.Fatalf("worktree workspace 应保留根项目信息：%+v", response.Workspace)
	}
	if _, err := os.Stat(filepath.Join(response.Workspace.Path, "README.md")); err != nil {
		t.Fatalf("worktree 应包含仓库文件：%v", err)
	}
	if response.Worktree.Branch != "mimi/review-branch" {
		t.Fatalf("worktree 应返回本地分支名：%+v", response.Worktree)
	}
	if response.Worktree.GitState != worktreeGitStateClean || response.Worktree.Dirty {
		t.Fatalf("新建 worktree 应有明确 clean 状态：%+v", response.Worktree)
	}
	if branch := gitTestOutput(t, response.Workspace.Path, "branch", "--show-current"); branch != response.Worktree.Branch {
		t.Fatalf("worktree 应 checkout 到响应分支，got=%q want=%q", branch, response.Worktree.Branch)
	}
	registryFile := filepath.Join(worktreesRoot, "registry", workspaceIDForRealPath(response.Workspace.Path)+".json")
	registryData, err := os.ReadFile(registryFile)
	if err != nil {
		t.Fatalf("新建 worktree 应持久化 registry：%v", err)
	}
	var registered managedWorktree
	if err := json.Unmarshal(registryData, &registered); err != nil {
		t.Fatalf("registry 不是合法 managedWorktree：%v", err)
	}
	if registered.Version != managedWorktreeRegistryVersion || registered.CheckoutPath != response.Workspace.Path {
		t.Fatalf("registry 应保存版本和 checkout 根：%+v", registered)
	}
	if registered.CreatedAt.IsZero() || registered.LastUsedAt.IsZero() || registered.LastUsedAt.Before(registered.CreatedAt) {
		t.Fatalf("registry 应保存保守的生命周期时间：%+v", registered)
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/workspaces/resolve", workspaceResolveRequest{Path: response.Workspace.Path})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("刚创建的 worktree 应可作为 workspace resolve，got=%d body=%s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/git/status", gitStatusRequest{Path: response.Workspace.Path})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("刚创建的 worktree 应可读取 Git 状态，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var status gitStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&status); err != nil {
		t.Fatalf("响应不是 gitStatusResponse：%v", err)
	}
	if !status.IsRepository {
		t.Fatalf("worktree 应是 Git 仓库：%+v", status)
	}
}

func TestWorktreeBranchListReturnsLocalAndRemoteBranches(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	current := gitTestOutput(t, repo, "branch", "--show-current")
	runGitTestCommand(t, repo, "checkout", "-b", "feature/demo")
	runGitTestCommand(t, repo, "checkout", current)
	remote := filepath.Join(t.TempDir(), "origin.git")
	runGitTestCommand(t, t.TempDir(), "init", "--bare", remote)
	runGitTestCommand(t, repo, "remote", "add", "origin", remote)
	runGitTestCommand(t, repo, "push", "-u", "origin", current)
	runGitTestCommand(t, repo, "push", "origin", "feature/demo")

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/worktrees/branches", worktreeBranchListRequest{Path: repo})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("worktree branches 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response worktreeBranchListResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 worktreeBranchListResponse：%v", err)
	}
	if response.Path != canonicalTestPath(t, repo) || response.CurrentBranch != current || response.DefaultBase != current {
		t.Fatalf("分支默认值异常：%+v current=%s repo=%s", response, current, repo)
	}
	if !containsWorktreeBranch(response.Branches, current, "local", true, true) {
		t.Fatalf("应返回当前本地分支并标记默认：%+v current=%s", response.Branches, current)
	}
	if !containsWorktreeBranch(response.Branches, "feature/demo", "local", false, false) {
		t.Fatalf("应返回本地 feature 分支：%+v", response.Branches)
	}
	if !containsWorktreeBranch(response.Branches, "origin/feature/demo", "remote", false, false) {
		t.Fatalf("应返回远端 feature 分支：%+v", response.Branches)
	}
}

func TestWorktreeBranchListReturnsEmptyForAllowedNonRepository(t *testing.T) {
	requireGit(t)
	projectDir := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "plain", Name: "Plain", Path: projectDir}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/worktrees/branches", worktreeBranchListRequest{Path: projectDir})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("非 Git 授权目录应返回空列表，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response worktreeBranchListResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 worktreeBranchListResponse：%v", err)
	}
	if response.DefaultBase != "" || response.CurrentBranch != "" || len(response.Branches) != 0 {
		t.Fatalf("非 Git 目录不应伪造分支：%+v", response)
	}
}

func TestWorktreeBranchListRejectsOutsidePathWithoutLeakingDetails(t *testing.T) {
	requireGit(t)
	server := newTestServer(t)
	outside := t.TempDir()
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/worktrees/branches", worktreeBranchListRequest{Path: outside})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("越界路径应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), outside) {
		t.Fatalf("拒绝响应不应泄漏外部路径：%s", rec.Body.String())
	}
}

func TestWorktreeCreatePreservesSubdirectoryWorkspacePath(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	appDir := filepath.Join(repo, "app")
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(appDir, "main.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, repo, "add", "app/main.go")
	runGitTestCommand(t, repo, "commit", "-m", "add app")

	worktreesRoot := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "app", Name: "App", Path: appDir}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/worktrees/create", worktreeCreateRequest{
		Path: appDir,
		Name: "App Review",
	})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("子目录项目创建 worktree 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response worktreeCreateResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 worktreeCreateResponse：%v", err)
	}
	if filepath.Base(response.Workspace.Path) != "app" {
		t.Fatalf("workspace 应指向仓库内的项目子目录，got=%s", response.Workspace.Path)
	}
	if _, err := os.Stat(filepath.Join(response.Workspace.Path, "main.go")); err != nil {
		t.Fatalf("worktree 子目录应包含项目文件：%v", err)
	}
	checkoutRoot := gitTestOutput(t, response.Workspace.Path, "rev-parse", "--show-toplevel")
	if err := os.WriteFile(filepath.Join(checkoutRoot, "outside-app.txt"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodGet, "/api/worktrees/list", nil)
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("读取子目录 worktree 列表应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var listed worktreeListResponse
	if err := json.NewDecoder(rec.Body).Decode(&listed); err != nil {
		t.Fatalf("响应不是 worktreeListResponse：%v", err)
	}
	if len(listed.Worktrees) != 1 || listed.Worktrees[0].Worktree.GitState != worktreeGitStateDirty || !listed.Worktrees[0].Worktree.Dirty {
		t.Fatalf("Git 状态必须覆盖完整 checkout，而不是只检查项目子目录：%+v", listed.Worktrees)
	}
	if err := os.Remove(filepath.Join(checkoutRoot, "outside-app.txt")); err != nil {
		t.Fatal(err)
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/worktrees/create", worktreeCreateRequest{
		Path: response.Workspace.Path,
		Name: "Nested Review",
	})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("从 managed worktree 再创建 worktree 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestWorktreeListAndDeleteManagedWorktree(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	worktreesRoot := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/worktrees/create", worktreeCreateRequest{
		Path: repo,
		Name: "Cleanup Review",
	})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("worktree create 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var created worktreeCreateResponse
	if err := json.NewDecoder(rec.Body).Decode(&created); err != nil {
		t.Fatalf("响应不是 worktreeCreateResponse：%v", err)
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodGet, "/api/worktrees/list", nil)
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("worktree list 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var listed worktreeListResponse
	if err := json.NewDecoder(rec.Body).Decode(&listed); err != nil {
		t.Fatalf("响应不是 worktreeListResponse：%v", err)
	}
	if len(listed.Worktrees) != 1 || listed.Worktrees[0].Workspace.Path != created.Workspace.Path {
		t.Fatalf("list 应返回刚创建的 worktree，got=%+v created=%+v", listed.Worktrees, created.Workspace)
	}
	if listed.Worktrees[0].Worktree.Branch != created.Worktree.Branch {
		t.Fatalf("list 应保留 worktree 分支名，got=%+v created=%+v", listed.Worktrees[0].Worktree, created.Worktree)
	}
	remoteRoot := t.TempDir()
	remote := filepath.Join(remoteRoot, "origin.git")
	runGitTestCommand(t, remoteRoot, "init", "--bare", remote)
	runGitTestCommand(t, repo, "remote", "add", "origin", remote)
	runGitTestCommand(t, repo, "push", "origin", "HEAD:main")
	runGitTestCommand(t, repo, "fetch", "origin", "main")
	runGitTestCommand(t, created.Workspace.Path, "branch", "--set-upstream-to=origin/main")
	if err := os.WriteFile(filepath.Join(created.Workspace.Path, "README.md"), []byte("ahead\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, created.Workspace.Path, "add", "README.md")
	runGitTestCommand(t, created.Workspace.Path, "commit", "-m", "ahead")
	if err := os.WriteFile(filepath.Join(created.Workspace.Path, "README.md"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodGet, "/api/worktrees/list", nil)
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("worktree list 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if err := json.NewDecoder(rec.Body).Decode(&listed); err != nil {
		t.Fatalf("响应不是 worktreeListResponse：%v", err)
	}
	if len(listed.Worktrees) != 1 || listed.Worktrees[0].Worktree.GitState != worktreeGitStateDirty || !listed.Worktrees[0].Worktree.Dirty || listed.Worktrees[0].Worktree.Ahead+listed.Worktrees[0].Worktree.Behind != 1 || listed.Worktrees[0].Worktree.Upstream != "origin/main" {
		t.Fatalf("list 应返回 worktree 动态 Git 状态：%+v", listed.Worktrees)
	}
	registryFile := filepath.Join(worktreesRoot, "registry", workspaceIDForRealPath(created.Workspace.Path)+".json")
	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/worktrees/delete", worktreeDeleteRequest{Path: created.Workspace.Path, Force: true})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("force=true 必须被 API 明确拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if data, err := os.ReadFile(filepath.Join(created.Workspace.Path, "README.md")); err != nil || string(data) != "dirty\n" {
		t.Fatalf("拒绝 force 后脏 checkout 内容必须原样保留：data=%q err=%v", data, err)
	}
	if _, err := os.Stat(registryFile); err != nil {
		t.Fatalf("拒绝 force 后 registry 必须保留：%v", err)
	}
	runGitTestCommand(t, created.Workspace.Path, "checkout", "--", "README.md")

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/worktrees/delete", worktreeDeleteRequest{Path: created.Workspace.Path})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("worktree delete 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var deleted worktreeDeleteResponse
	if err := json.NewDecoder(rec.Body).Decode(&deleted); err != nil {
		t.Fatalf("响应不是 worktreeDeleteResponse：%v", err)
	}
	if deleted.DeletedPath != created.Workspace.Path || len(deleted.Worktrees) != 0 {
		t.Fatalf("delete 响应应返回空列表，got=%+v", deleted)
	}
	if _, err := os.Stat(created.Workspace.Path); !os.IsNotExist(err) {
		t.Fatalf("worktree checkout 应被删除，stat err=%v", err)
	}

	rec = httptest.NewRecorder()
	req = authedRequest(t, http.MethodPost, "/api/workspaces/resolve", workspaceResolveRequest{Path: created.Workspace.Path})
	server.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("删除后 workspace 不应继续 resolve，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestWorktreeDeleteRejectsUnmanagedPath(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/worktrees/delete", worktreeDeleteRequest{Path: repo})
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("非 managed worktree 不允许删除，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestWorktreePruneRemovesMissingRegistryEntries(t *testing.T) {
	worktreesRoot := t.TempDir()
	projectDir := t.TempDir()
	missingPath := filepath.Join(t.TempDir(), "missing-worktree")
	registryDir := filepath.Join(worktreesRoot, "registry")
	if err := os.MkdirAll(registryDir, 0o755); err != nil {
		t.Fatalf("创建 registry 目录失败：%v", err)
	}

	entry := managedWorktree{
		Version:        managedWorktreeRegistryVersion,
		Path:           missingPath,
		CheckoutPath:   missingPath,
		RepositoryPath: projectDir,
		Base:           "main",
		Branch:         "mimi/missing",
		CreatedAt:      time.Now().UTC(),
		LastUsedAt:     time.Now().UTC(),
		RootProject:    projects.Project{ID: "repo", Name: "Repo", Path: projectDir},
	}
	data, err := json.Marshal(entry)
	if err != nil {
		t.Fatalf("编码 registry 失败：%v", err)
	}
	registryFile := filepath.Join(registryDir, workspaceIDForRealPath(missingPath)+".json")
	if err := os.WriteFile(registryFile, data, 0o600); err != nil {
		t.Fatalf("写入 registry 失败：%v", err)
	}

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
	})
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodPost, "/api/worktrees/prune", nil)
	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("prune 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response worktreePruneResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 worktreePruneResponse：%v", err)
	}
	if len(response.PrunedPaths) != 1 || response.PrunedPaths[0] != missingPath {
		t.Fatalf("清理路径不符合预期：got=%v want=%v", response.PrunedPaths, []string{missingPath})
	}
	if len(response.Worktrees) != 0 {
		t.Fatalf("缺失 worktree 清理后不应继续返回列表：%+v", response.Worktrees)
	}
	if _, err := os.Stat(registryFile); !os.IsNotExist(err) {
		t.Fatalf("registry 文件应被移除，err=%v", err)
	}
}

func TestWorktreePruneKeepsExistingCheckoutWhenRootProjectRemoved(t *testing.T) {
	worktreesRoot := t.TempDir()
	checkoutPath := t.TempDir()
	missingWorkspace := filepath.Join(checkoutPath, "app")
	entry := managedWorktree{
		Version:        managedWorktreeRegistryVersion,
		Path:           missingWorkspace,
		CheckoutPath:   checkoutPath,
		RepositoryPath: checkoutPath,
		Base:           "main",
		Branch:         "mimi/kept",
		CreatedAt:      time.Now().UTC(),
		LastUsedAt:     time.Now().UTC(),
		RootProject:    projects.Project{ID: "removed", Name: "Removed", Path: checkoutPath},
	}
	registryFile := writeManagedWorktreeRegistryForTest(t, worktreesRoot, entry)

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "other", Name: "Other", Path: t.TempDir()}}
	})
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/worktrees/prune", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("prune 应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var response worktreePruneResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 worktreePruneResponse：%v", err)
	}
	if len(response.PrunedPaths) != 0 {
		t.Fatalf("根项目移除但 checkout 存在时绝不能 prune：%v", response.PrunedPaths)
	}
	if _, err := os.Stat(registryFile); err != nil {
		t.Fatalf("根项目移除后 registry 应继续保留：%v", err)
	}
}

func TestWorktreePruneKeepsExistingCheckoutWhenWorkspaceSubdirectoryMissing(t *testing.T) {
	worktreesRoot := t.TempDir()
	projectDir := t.TempDir()
	checkoutPath := t.TempDir()
	entry := managedWorktree{
		Version:        managedWorktreeRegistryVersion,
		Path:           filepath.Join(checkoutPath, "deleted-project-subdirectory"),
		CheckoutPath:   checkoutPath,
		RepositoryPath: projectDir,
		Base:           "main",
		Branch:         "mimi/subdirectory",
		CreatedAt:      time.Now().UTC(),
		LastUsedAt:     time.Now().UTC(),
		RootProject:    projects.Project{ID: "repo", Name: "Repo", Path: projectDir},
	}
	registryFile := writeManagedWorktreeRegistryForTest(t, worktreesRoot, entry)

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
	})
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/worktrees/prune", nil))

	var response worktreePruneResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 worktreePruneResponse：%v", err)
	}
	if len(response.PrunedPaths) != 0 {
		t.Fatalf("项目子目录消失但 checkout 根存在时绝不能 prune：%v", response.PrunedPaths)
	}
	if _, err := os.Stat(registryFile); err != nil {
		t.Fatalf("checkout 仍存在时 registry 应继续保留：%v", err)
	}
}

func TestWorktreePruneKeepsUnresolvableLegacyRegistry(t *testing.T) {
	worktreesRoot := t.TempDir()
	projectDir := t.TempDir()
	entry := managedWorktree{
		Path:           filepath.Join(t.TempDir(), "missing-legacy-workspace"),
		RepositoryPath: projectDir,
		Base:           "main",
		Branch:         "mimi/legacy",
		RootProject:    projects.Project{ID: "repo", Name: "Repo", Path: projectDir},
	}
	registryFile := writeManagedWorktreeRegistryForTest(t, worktreesRoot, entry)

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
	})
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/worktrees/prune", nil))

	var response worktreePruneResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是 worktreePruneResponse：%v", err)
	}
	if len(response.PrunedPaths) != 0 {
		t.Fatalf("无法解析 checkout 根的 legacy registry 必须保留：%v", response.PrunedPaths)
	}
	data, err := os.ReadFile(registryFile)
	if err != nil {
		t.Fatalf("legacy registry 应继续存在：%v", err)
	}
	var kept managedWorktree
	if err := json.Unmarshal(data, &kept); err != nil {
		t.Fatalf("legacy registry 应保持可解析：%v", err)
	}
	if kept.Version != 0 || kept.CheckoutPath != "" {
		t.Fatalf("无法可靠迁移时必须保持 legacy/unknown：%+v", kept)
	}
}

func TestWorktreeRegistryMigratesLegacyEntryFromExistingWorkspace(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	checkoutPath := filepath.Join(t.TempDir(), "legacy-checkout")
	runGitTestCommand(t, repo, "worktree", "add", "-b", "mimi/legacy-migration", checkoutPath, "HEAD")
	t.Cleanup(func() {
		_ = exec.Command("git", "-C", repo, "worktree", "remove", "--force", checkoutPath).Run()
	})

	worktreesRoot := t.TempDir()
	entry := managedWorktree{
		Path:           checkoutPath,
		RepositoryPath: repo,
		Base:           "HEAD",
		Branch:         "mimi/legacy-migration",
		RootProject:    projects.Project{ID: "repo", Name: "Repo", Path: repo},
	}
	registryFile := writeManagedWorktreeRegistryForTest(t, worktreesRoot, entry)
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})

	migrationStartedAt := time.Now().UTC()
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/worktrees/list", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("legacy registry 列表读取应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	data, err := os.ReadFile(registryFile)
	if err != nil {
		t.Fatalf("迁移后的 registry 应存在：%v", err)
	}
	var migrated managedWorktree
	if err := json.Unmarshal(data, &migrated); err != nil {
		t.Fatalf("迁移后的 registry 不是合法 JSON：%v", err)
	}
	if migrated.Version != managedWorktreeRegistryVersion || migrated.CheckoutPath != canonicalTestPath(t, checkoutPath) {
		t.Fatalf("legacy registry 应补齐版本和 checkout 根：%+v", migrated)
	}
	if migrated.CreatedAt.IsZero() || migrated.LastUsedAt.IsZero() {
		t.Fatalf("legacy registry 应保守补齐生命周期时间：%+v", migrated)
	}
	if migrated.CreatedAt.Before(migrationStartedAt) || migrated.LastUsedAt.Before(migrationStartedAt) {
		t.Fatalf("legacy 生命周期必须从迁移时重新起算，不能复用 registry mtime：%+v", migrated)
	}
}

func TestManagedWorktreeGitStateIsUnknownWhenCheckoutCannotBeRead(t *testing.T) {
	worktree := managedWorktree{
		Version:      managedWorktreeRegistryVersion,
		Path:         filepath.Join(t.TempDir(), "missing-workspace"),
		CheckoutPath: filepath.Join(t.TempDir(), "missing-checkout"),
		RootProject:  projects.Project{ID: "repo", Name: "Repo", Path: t.TempDir()},
	}
	descriptor := worktreeDescriptorForManagedWorktree(context.Background(), worktree)
	if descriptor.GitState != worktreeGitStateUnknown || descriptor.Dirty {
		t.Fatalf("Git 状态检查失败必须显式返回 unknown：%+v", descriptor)
	}
}

func TestRegisterManagedWorktreeDoesNotPublishMemoryBeforeRegistryCommit(t *testing.T) {
	worktreesRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(worktreesRoot, "registry"), []byte("not-a-directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:              config.Config{WorktreesRoot: worktreesRoot},
		managedWorktrees: map[string]managedWorktree{},
	}
	entry := managedWorktree{
		Version:      managedWorktreeRegistryVersion,
		Path:         filepath.Join(worktreesRoot, "checkout"),
		CheckoutPath: filepath.Join(worktreesRoot, "checkout"),
		CreatedAt:    time.Now().UTC(),
		LastUsedAt:   time.Now().UTC(),
		RootProject:  projects.Project{ID: "repo", Name: "Repo", Path: worktreesRoot},
	}
	if err := router.registerManagedWorktree(entry); err == nil {
		t.Fatal("registry 无法提交时 register 应失败")
	}
	if len(router.managedWorktrees) != 0 {
		t.Fatalf("registry 提交失败前不能写入内存 allowlist：%+v", router.managedWorktrees)
	}
}

func TestManagedWorktreeActualAccessTouchesLastUsedAtWithThrottle(t *testing.T) {
	worktreesRoot := t.TempDir()
	checkoutPath := filepath.Join(worktreesRoot, "checkouts", "repo", "touch")
	if err := os.MkdirAll(checkoutPath, 0o755); err != nil {
		t.Fatal(err)
	}
	baseTime := time.Now().UTC().Add(-2 * time.Hour)
	entry := managedWorktree{
		Version:        managedWorktreeRegistryVersion,
		Path:           checkoutPath,
		CheckoutPath:   checkoutPath,
		RepositoryPath: checkoutPath,
		CreatedAt:      baseTime.Add(-24 * time.Hour),
		LastUsedAt:     baseTime,
		RootProject:    projects.Project{ID: "repo", Name: "Repo", Path: checkoutPath},
	}
	router := &Router{
		cfg:              config.Config{WorktreesRoot: worktreesRoot},
		managedWorktrees: map[string]managedWorktree{},
	}
	if err := router.registerManagedWorktree(entry); err != nil {
		t.Fatalf("注册测试 worktree 失败：%v", err)
	}

	beforeAccess := time.Now().UTC()
	touched, ok := router.managedWorktreeForPath(checkoutPath)
	if !ok {
		t.Fatal("实际解析 managed worktree 应成功")
	}
	if touched.LastUsedAt.Before(beforeAccess) || touched.LastUsedPersistFailed {
		t.Fatalf("实际访问应更新并持久化 last_used_at：%+v", touched)
	}
	registryFile, err := router.managedWorktreeRegistryFile(checkoutPath)
	if err != nil {
		t.Fatal(err)
	}
	registered := readManagedWorktreeRegistryForTest(t, registryFile)
	if !registered.LastUsedAt.Equal(touched.LastUsedAt) {
		t.Fatalf("内存与持久化 last_used_at 应一致：memory=%s registry=%s", touched.LastUsedAt, registered.LastUsedAt)
	}

	throttledAt := touched.LastUsedAt.Add(30 * time.Minute)
	throttled := router.touchManagedWorktreeAt(touched, throttledAt)
	if !throttled.LastUsedAt.Equal(throttledAt) || !throttled.LastUsedPersistedAt.Equal(touched.LastUsedAt) {
		t.Fatalf("一小时内重复访问应推进内存时间但不高频写盘：before=%s after=%+v", touched.LastUsedAt, throttled)
	}
	registered = readManagedWorktreeRegistryForTest(t, registryFile)
	if !registered.LastUsedAt.Equal(touched.LastUsedAt) {
		t.Fatalf("节流访问不应修改 registry：%+v", registered)
	}

	persistAt := touched.LastUsedAt.Add(61 * time.Minute)
	persisted := router.touchManagedWorktreeAt(throttled, persistAt)
	if !persisted.LastUsedAt.Equal(persistAt) || !persisted.LastUsedPersistedAt.Equal(persistAt) {
		t.Fatalf("连续访问跨过原持久化时间一小时后必须落盘：%+v", persisted)
	}
	registered = readManagedWorktreeRegistryForTest(t, registryFile)
	if !registered.LastUsedAt.Equal(persistAt) {
		t.Fatalf("一小时节流基线不能被中间内存访问滑动推迟：%+v", registered)
	}
}

func TestManagedWorktreeTouchFailureKeepsConservativeMemoryValue(t *testing.T) {
	worktreesRoot := t.TempDir()
	checkoutPath := filepath.Join(worktreesRoot, "checkouts", "repo", "touch-failure")
	if err := os.MkdirAll(checkoutPath, 0o755); err != nil {
		t.Fatal(err)
	}
	baseTime := time.Now().UTC().Add(-3 * time.Hour)
	entry := managedWorktree{
		Version:        managedWorktreeRegistryVersion,
		Path:           checkoutPath,
		CheckoutPath:   checkoutPath,
		RepositoryPath: checkoutPath,
		CreatedAt:      baseTime.Add(-24 * time.Hour),
		LastUsedAt:     baseTime,
		RootProject:    projects.Project{ID: "repo", Name: "Repo", Path: checkoutPath},
	}
	router := &Router{cfg: config.Config{WorktreesRoot: worktreesRoot}, managedWorktrees: map[string]managedWorktree{}}
	if err := router.registerManagedWorktree(entry); err != nil {
		t.Fatal(err)
	}
	registryDir := filepath.Join(worktreesRoot, "registry")
	backupDir := filepath.Join(worktreesRoot, "registry-backup")
	if err := os.Rename(registryDir, backupDir); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(registryDir, []byte("block registry writes"), 0o600); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC()
	failed := router.touchManagedWorktreeAt(entry, now)
	if !failed.LastUsedPersistFailed || !failed.LastUsedAt.Equal(now) {
		t.Fatalf("写盘失败仍应在内存保守记录最近使用时间：%+v", failed)
	}
	// 持久化失败标记会绕过正常一小时节流，让下一次实际访问立即重试。
	retryAt := now.Add(time.Minute)
	retried := router.touchManagedWorktreeAt(failed, retryAt)
	if !retried.LastUsedPersistFailed || !retried.LastUsedAt.Equal(retryAt) {
		t.Fatalf("持久化失败后的访问应立即重试并继续推进内存时间：%+v", retried)
	}
}

func TestWorktreeCreateRollsBackNewCheckoutAndBranchWhenRegistryFails(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	worktreesRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(worktreesRoot, "registry"), []byte("not-a-directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})
	branch := "mimi/rollback-registry-failure"
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/worktrees/create", worktreeCreateRequest{
		Path: repo, Name: "rollback", Branch: branch,
	}))

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("registry 失败时创建应返回 502，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "回滚成功") {
		t.Fatalf("错误应包含原失败和回滚结果：%s", rec.Body.String())
	}
	if worktreeBranchExists(context.Background(), repo, branch) {
		t.Fatalf("回滚不得保留本次新分支：%s", branch)
	}
	entries, err := os.ReadDir(filepath.Join(worktreesRoot, "checkouts", "repo"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("回滚不得保留本次 checkout：%v", entries)
	}
}

func TestWorktreeCreateRollbackRemovesNewBranchFromUnmergedBase(t *testing.T) {
	requireGit(t)
	repo := newCommittedGitRepo(t)
	mainBranch := gitTestOutput(t, repo, "branch", "--show-current")
	runGitTestCommand(t, repo, "checkout", "-b", "unmerged-base")
	if err := os.WriteFile(filepath.Join(repo, "unmerged.txt"), []byte("unmerged\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, repo, "add", "unmerged.txt")
	runGitTestCommand(t, repo, "commit", "-m", "unmerged base")
	baseCommit := gitTestOutput(t, repo, "rev-parse", "HEAD")
	runGitTestCommand(t, repo, "checkout", mainBranch)

	worktreesRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(worktreesRoot, "registry"), []byte("not-a-directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: repo}}
	})
	createdBranch := "mimi/rollback-unmerged-base"
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/worktrees/create", worktreeCreateRequest{
		Path: repo, Name: "rollback-unmerged", Base: "unmerged-base", Branch: createdBranch,
	}))

	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "回滚成功") {
		t.Fatalf("未合并 base 的后处理失败也应安全回滚，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if worktreeBranchExists(context.Background(), repo, createdBranch) {
		t.Fatalf("未合并 base 上新建的临时分支应被删除：%s", createdBranch)
	}
	if got := gitTestOutput(t, repo, "rev-parse", "unmerged-base"); got != baseCommit {
		t.Fatalf("回滚不得删除或改写用户的 base 分支：got=%s want=%s", got, baseCommit)
	}
}

func TestWorktreeCleanupDryRunAndExecuteCandidateSubset(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	if preview.Code != http.StatusOK {
		t.Fatalf("cleanup dry-run 应成功，got=%d body=%s", preview.Code, preview.Body.String())
	}
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatalf("dry-run 响应不是 worktreeCleanupResponse：%v", err)
	}
	if !plan.DryRun || plan.PlanID == "" || plan.Policy.AutoDelete || plan.Policy.CandidateAfterDays != 30 || plan.Policy.KeepLatestPerProject != 3 {
		t.Fatalf("cleanup 固定安全策略异常：%+v", plan)
	}
	if len(plan.Worktrees) != 4 || len(plan.CandidatePaths) != 1 || plan.CandidatePaths[0] != fixture.worktrees[0].Path {
		t.Fatalf("每项目最近 3 个应保留，只返回最旧候选：%+v", plan)
	}
	for _, item := range plan.Worktrees {
		if item.Workspace.Path == fixture.worktrees[0].Path && (!item.Eligible || len(item.Blockers) != 0) {
			t.Fatalf("最旧 clean worktree 应可清理：%+v", item)
		}
		if item.Workspace.Path != fixture.worktrees[0].Path && !containsString(item.Blockers, worktreeCleanupBlockerKeepLatest) {
			t.Fatalf("最近三个 worktree 应有 keep_latest blocker：%+v", item)
		}
	}

	dryRunFalse := false
	execute := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun:  &dryRunFalse,
		Confirm: true,
		PlanID:  plan.PlanID,
		Paths:   []string{fixture.worktrees[0].Path},
	})
	if execute.Code != http.StatusOK {
		t.Fatalf("cleanup execute 应成功，got=%d body=%s", execute.Code, execute.Body.String())
	}
	var result worktreeCleanupResponse
	if err := json.NewDecoder(execute.Body).Decode(&result); err != nil {
		t.Fatalf("execute 响应不是 worktreeCleanupResponse：%v", err)
	}
	if result.DryRun || len(result.DeletedPaths) != 1 || result.DeletedPaths[0] != fixture.worktrees[0].Path || result.FailedPath != "" || result.Error != "" {
		t.Fatalf("execute 删除结果异常：%+v", result)
	}
	if _, err := os.Stat(fixture.worktrees[0].CheckoutPath); !os.IsNotExist(err) {
		t.Fatalf("候选 checkout 应被删除：%v", err)
	}
	if !worktreeBranchExists(context.Background(), fixture.repo, fixture.worktrees[0].Branch) {
		t.Fatalf("cleanup 只删除 checkout，不应删除分支：%s", fixture.worktrees[0].Branch)
	}
}

func TestWorktreeCleanupReturnsStructuredPartialFailure(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 5)
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	if len(plan.CandidatePaths) != 2 {
		t.Fatalf("fixture 应产生两个候选：%+v", plan.CandidatePaths)
	}
	firstPath, secondPath := plan.CandidatePaths[0], plan.CandidatePaths[1]
	fixture.router.managedWorktreeCleanupDelete = func(ctx context.Context, path string, force bool, expected worktreeCleanupInstanceIdentity) (managedWorktree, error) {
		if path == secondPath {
			return managedWorktree{}, fmt.Errorf("模拟第二个 checkout 删除失败")
		}
		return fixture.router.deleteManagedWorktreeWithExpectedIdentityLocked(ctx, path, force, expected)
	}

	dryRunFalse := false
	execute := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun: &dryRunFalse, Confirm: true, PlanID: plan.PlanID, Paths: plan.CandidatePaths,
	})
	if execute.Code != http.StatusOK {
		t.Fatalf("运行时部分失败必须返回 200 保留结构化 body，got=%d body=%s", execute.Code, execute.Body.String())
	}
	var result worktreeCleanupResponse
	if err := json.NewDecoder(execute.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if len(result.DeletedPaths) != 1 || result.DeletedPaths[0] != firstPath || result.FailedPath != secondPath || !strings.Contains(result.Error, "模拟第二个") {
		t.Fatalf("部分失败必须精确返回已删除项和失败项：%+v", result)
	}
	if _, err := os.Stat(firstPath); !os.IsNotExist(err) {
		t.Fatalf("第一个 checkout 应已删除：%v", err)
	}
	firstRegistry := filepath.Join(fixture.worktreesRoot, "registry", workspaceIDForRealPath(firstPath)+".json")
	if _, err := os.Stat(firstRegistry); !os.IsNotExist(err) {
		t.Fatalf("已删除 checkout 的 registry 应同步移除：%v", err)
	}
	if _, err := os.Stat(secondPath); err != nil {
		t.Fatalf("失败项 checkout 必须保留：%v", err)
	}
	secondRegistry := filepath.Join(fixture.worktreesRoot, "registry", workspaceIDForRealPath(secondPath)+".json")
	if _, err := os.Stat(secondRegistry); err != nil {
		t.Fatalf("失败项 registry 必须保留：%v", err)
	}
}

func TestWorktreeCleanupReportsRegistryUnlinkAfterCheckoutDeletion(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	if len(plan.CandidatePaths) != 1 {
		t.Fatalf("fixture 应产生一个候选：%+v", plan.CandidatePaths)
	}
	target := fixture.worktrees[0]
	registryFile := filepath.Join(fixture.worktreesRoot, "registry", workspaceIDForRealPath(target.Path)+".json")
	fixture.router.managedWorktreeRegistryRemove = func(path string) error {
		if path != registryFile {
			t.Fatalf("registry remove 路径异常：got=%s want=%s", path, registryFile)
		}
		return fmt.Errorf("模拟 registry unlink 失败")
	}

	dryRunFalse := false
	execute := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun: &dryRunFalse, Confirm: true, PlanID: plan.PlanID, Paths: plan.CandidatePaths,
	})
	if execute.Code != http.StatusOK {
		t.Fatalf("checkout 已删后的 registry 失败应返回结构化 200，got=%d body=%s", execute.Code, execute.Body.String())
	}
	var result worktreeCleanupResponse
	if err := json.NewDecoder(execute.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if len(result.DeletedPaths) != 1 || result.DeletedPaths[0] != target.Path || result.FailedPath != target.Path || !strings.Contains(result.Error, "registry") {
		t.Fatalf("registry 失败必须同时表达真实删除和登记失败：%+v", result)
	}
	if _, err := os.Stat(target.CheckoutPath); !os.IsNotExist(err) {
		t.Fatalf("Git checkout 应已删除：%v", err)
	}
	if _, err := os.Stat(registryFile); err != nil {
		t.Fatalf("unlink 失败后的 registry 应保留供重试：%v", err)
	}
}

func TestManualWorktreeDeleteAndPruneExposeRegistryUnlinkFailure(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	target := fixture.worktrees[0]
	registryFile := filepath.Join(fixture.worktreesRoot, "registry", workspaceIDForRealPath(target.Path)+".json")
	fixture.router.managedWorktreeRegistryRemove = func(path string) error {
		if path != registryFile {
			t.Fatalf("registry remove 路径异常：got=%s want=%s", path, registryFile)
		}
		return fmt.Errorf("模拟 registry unlink 失败")
	}

	deleted := httptest.NewRecorder()
	fixture.router.worktreeDeleteHandler(deleted, authedRequest(t, http.MethodPost, "/api/worktrees/delete", worktreeDeleteRequest{Path: target.Path}))
	if deleted.Code != http.StatusOK {
		t.Fatalf("checkout 已删后的 registry 失败应保留 200 body，got=%d body=%s", deleted.Code, deleted.Body.String())
	}
	var deleteResult worktreeDeleteResponse
	if err := json.NewDecoder(deleted.Body).Decode(&deleteResult); err != nil {
		t.Fatal(err)
	}
	if deleteResult.DeletedPath != target.Path || !strings.Contains(deleteResult.RegistryCleanupError, "registry") || len(deleteResult.Worktrees) != len(fixture.worktrees)-1 {
		t.Fatalf("普通 delete 必须返回真实删除路径、警告和可重试登记：%+v", deleteResult)
	}
	if _, err := os.Stat(target.CheckoutPath); !os.IsNotExist(err) {
		t.Fatalf("Git checkout 应已删除：%v", err)
	}
	if _, err := os.Stat(registryFile); err != nil {
		t.Fatalf("unlink 失败后的 registry 应保留供 prune 重试：%v", err)
	}

	pruneFailed := httptest.NewRecorder()
	fixture.router.worktreePruneHandler(pruneFailed, httptest.NewRequest(http.MethodPost, "/api/worktrees/prune", nil))
	var failedResult worktreePruneResponse
	if err := json.NewDecoder(pruneFailed.Body).Decode(&failedResult); err != nil {
		t.Fatal(err)
	}
	if len(failedResult.PrunedPaths) != 0 || !strings.Contains(failedResult.FailedPaths[target.Path], "registry") || len(failedResult.Worktrees) != len(fixture.worktrees)-1 {
		t.Fatalf("prune 必须暴露失败且不能误报成功：%+v", failedResult)
	}

	fixture.router.managedWorktreeRegistryRemove = nil
	pruneRetried := httptest.NewRecorder()
	fixture.router.worktreePruneHandler(pruneRetried, httptest.NewRequest(http.MethodPost, "/api/worktrees/prune", nil))
	var retriedResult worktreePruneResponse
	if err := json.NewDecoder(pruneRetried.Body).Decode(&retriedResult); err != nil {
		t.Fatal(err)
	}
	if len(retriedResult.PrunedPaths) != 1 || retriedResult.PrunedPaths[0] != target.Path || len(retriedResult.FailedPaths) != 0 || len(retriedResult.Worktrees) != len(fixture.worktrees)-1 {
		t.Fatalf("unlink 恢复后 prune 应可完成：%+v", retriedResult)
	}
}

func TestWorktreeCleanupRejectsAllBeforeDeletionWhenSelectedStateChanges(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 5)
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	if len(plan.CandidatePaths) != 2 {
		t.Fatalf("fixture 应产生两个候选：%+v", plan.CandidatePaths)
	}
	changedPath := plan.CandidatePaths[1]
	if err := os.WriteFile(filepath.Join(changedPath, "changed.txt"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, changedPath, "add", "changed.txt")
	runGitTestCommand(t, changedPath, "commit", "-m", "change after preview")

	dryRunFalse := false
	execute := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun: &dryRunFalse, Confirm: true, PlanID: plan.PlanID, Paths: plan.CandidatePaths,
	})
	if execute.Code != http.StatusConflict {
		t.Fatalf("选中项 HEAD 变化应整体返回 409，got=%d body=%s", execute.Code, execute.Body.String())
	}
	for _, path := range plan.CandidatePaths {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("整体拒绝前不能删除任何候选：path=%s err=%v", path, err)
		}
	}
}

func TestWorktreeCleanupRejectsSameHEADCheckoutReplacement(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	if len(plan.CandidatePaths) != 1 {
		t.Fatalf("fixture 应产生一个候选：%+v", plan.CandidatePaths)
	}
	target := fixture.worktrees[0]
	oldInfo, err := os.Lstat(target.CheckoutPath)
	if err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, fixture.repo, "worktree", "remove", target.CheckoutPath)
	runGitTestCommand(t, fixture.repo, "worktree", "add", target.CheckoutPath, target.Branch)
	newInfo, err := os.Lstat(target.CheckoutPath)
	if err != nil {
		t.Fatal(err)
	}
	if os.SameFile(oldInfo, newInfo) {
		t.Fatal("测试前提失效：checkout 应已被同路径、同 branch/HEAD 的新实例替换")
	}

	dryRunFalse := false
	execute := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun: &dryRunFalse, Confirm: true, PlanID: plan.PlanID, Paths: plan.CandidatePaths,
	})
	if execute.Code != http.StatusConflict {
		t.Fatalf("同路径、同 branch/HEAD 的 checkout 实例替换也必须返回 409，got=%d body=%s", execute.Code, execute.Body.String())
	}
	if _, err := os.Stat(target.CheckoutPath); err != nil {
		t.Fatalf("预览后重建的新 checkout 不得被删除：%v", err)
	}
}

func TestWorktreeCleanupKeepsReplacementCreatedBeforeNthRemove(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 5)
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	if len(plan.CandidatePaths) != 2 {
		t.Fatalf("fixture 应产生两个候选：%+v", plan.CandidatePaths)
	}
	firstPath, secondPath := plan.CandidatePaths[0], plan.CandidatePaths[1]
	second := fixture.worktrees[1]
	if second.Path != secondPath {
		t.Fatalf("测试 fixture 候选顺序异常：second=%s candidates=%v", second.Path, plan.CandidatePaths)
	}
	fixture.router.managedWorktreeCleanupDelete = func(ctx context.Context, path string, force bool, expected worktreeCleanupInstanceIdentity) (managedWorktree, error) {
		if path == secondPath {
			// 模拟外部 Git 在全量预检已通过、第一项已删除后，
			// 用同路径、同 branch/HEAD 重建第二个 checkout。
			runGitTestCommand(t, fixture.repo, "worktree", "remove", secondPath)
			runGitTestCommand(t, fixture.repo, "worktree", "add", secondPath, second.Branch)
		}
		return fixture.router.deleteManagedWorktreeWithExpectedIdentityLocked(ctx, path, force, expected)
	}

	dryRunFalse := false
	execute := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun: &dryRunFalse, Confirm: true, PlanID: plan.PlanID, Paths: plan.CandidatePaths,
	})
	if execute.Code != http.StatusOK {
		t.Fatalf("第 N 项紧前实例替换应返回结构化 partial，got=%d body=%s", execute.Code, execute.Body.String())
	}
	var result worktreeCleanupResponse
	if err := json.NewDecoder(execute.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if len(result.DeletedPaths) != 1 || result.DeletedPaths[0] != firstPath || result.FailedPath != secondPath || result.Error == "" {
		t.Fatalf("第 N 项实例变化必须精确返回 partial 结果：%+v", result)
	}
	if _, err := os.Stat(firstPath); !os.IsNotExist(err) {
		t.Fatalf("第一个已确认候选应已删除：%v", err)
	}
	if _, err := os.Stat(secondPath); err != nil {
		t.Fatalf("第二个新 checkout 实例必须保留：%v", err)
	}
}

func TestWorktreeCleanupRejectsActualAccessAfterPreview(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	target := fixture.worktrees[0]
	if _, ok := fixture.router.gatewayScopeForPath(target.Path); !ok {
		t.Fatal("预览后的真实 gateway scope 访问应仍可解析")
	}

	dryRunFalse := false
	execute := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun: &dryRunFalse, Confirm: true, PlanID: plan.PlanID, Paths: plan.CandidatePaths,
	})
	if execute.Code != http.StatusConflict {
		t.Fatalf("预览后实际访问必须推进 LastUsedAt 并使执行返回 409，got=%d body=%s", execute.Code, execute.Body.String())
	}
	if _, err := os.Stat(target.CheckoutPath); err != nil {
		t.Fatalf("预览后使用过的 checkout 不得被删除：%v", err)
	}
}

func TestManagedWorktreeLookupWaitsForCleanupCriticalSection(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	target := fixture.worktrees[0]
	fixture.router.managedWorktreeCleanupMu.Lock()
	finished := make(chan bool, 1)
	go func() {
		_, ok := fixture.router.managedWorktreeForPath(target.Path)
		finished <- ok
	}()

	select {
	case <-finished:
		fixture.router.managedWorktreeCleanupMu.Unlock()
		t.Fatal("cleanup 临界区内新 managed worktree lookup 不得穿透")
	case <-time.After(100 * time.Millisecond):
		// 按预期被 cleanup 锁阻塞。
	}
	fixture.router.managedWorktreeCleanupMu.Unlock()
	select {
	case ok := <-finished:
		if !ok {
			t.Fatal("cleanup 临界区结束后未删除 checkout 应恢复解析")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cleanup 锁释放后 managed worktree lookup 未继续")
	}
}

func TestManualWorktreeDeleteUsesCleanupCriticalSection(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	target := fixture.worktrees[0]
	type deleteResult struct {
		worktree managedWorktree
		err      error
	}
	fixture.router.managedWorktreeCleanupMu.Lock()
	finished := make(chan deleteResult, 1)
	go func() {
		worktree, err := fixture.router.deleteManagedWorktree(context.Background(), target.Path, false)
		finished <- deleteResult{worktree: worktree, err: err}
	}()
	select {
	case result := <-finished:
		fixture.router.managedWorktreeCleanupMu.Unlock()
		t.Fatalf("普通 delete 必须与 cleanup/scope lookup 共用临界区，不得穿透：%+v", result)
	case <-time.After(100 * time.Millisecond):
		// 按预期被同一把锁阻塞。
	}
	fixture.router.managedWorktreeCleanupMu.Unlock()
	select {
	case result := <-finished:
		if result.err != nil || result.worktree.Path != target.Path {
			t.Fatalf("锁释放后普通 delete 应完成：%+v", result)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("锁释放后普通 delete 未继续")
	}
}

func TestWorktreeCleanupRechecksSessionImmediatelyBeforeDelete(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	target := fixture.worktrees[0]
	var running *session.Session
	fixture.router.managedWorktreeCleanupDelete = func(ctx context.Context, path string, force bool, expected worktreeCleanupInstanceIdentity) (managedWorktree, error) {
		var err error
		running, err = fixture.server.manager.Create(session.CreateRequest{
			Project: projects.Project{
				ID: workspaceIDForRealPath(target.Path), Name: "Late Running Worktree", Path: target.Path, RealPath: target.Path,
			},
			Title: "late-running",
		})
		if err != nil {
			return managedWorktree{}, err
		}
		return fixture.router.deleteManagedWorktreeWithExpectedIdentityLocked(ctx, path, force, expected)
	}
	t.Cleanup(func() {
		if running != nil {
			_ = running.Stop()
		}
	})

	dryRunFalse := false
	execute := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun: &dryRunFalse, Confirm: true, PlanID: plan.PlanID, Paths: plan.CandidatePaths,
	})
	if execute.Code != http.StatusOK {
		t.Fatalf("预检后出现的运行态阻断应保留结构化失败 body，got=%d body=%s", execute.Code, execute.Body.String())
	}
	var result worktreeCleanupResponse
	if err := json.NewDecoder(execute.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if len(result.DeletedPaths) != 0 || result.FailedPath != target.Path || result.Error == "" {
		t.Fatalf("删除紧前新 session 必须阻止删除：%+v", result)
	}
	if _, err := os.Stat(target.CheckoutPath); err != nil {
		t.Fatalf("有新运行 session 的 checkout 必须保留：%v", err)
	}
}

func TestPendingGatewayThreadUseBlocksDeleteUntilFailureReleasesLease(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	target := fixture.worktrees[0]
	policy := newManagedWorktreeGatewayPolicyForTest(fixture.router)
	leaseReady := make(chan struct{})
	releaseResponse := make(chan struct{})
	finished := make(chan error, 1)
	go func() {
		request := []byte(fmt.Sprintf(`{"id":901,"method":"thread/start","params":{"cwd":%q}}`, target.Path))
		if _, policyErr := policy.validateClientFrame(websocket.TextMessage, request); policyErr != nil {
			finished <- fmt.Errorf("thread/start 策略校验失败：%s", policyErr.message)
			return
		}
		close(leaseReady)
		<-releaseResponse
		response := []byte(`{"id":901,"error":{"code":-32000,"message":"upstream failed"}}`)
		if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, response); !forward || policyErr != nil {
			finished <- fmt.Errorf("上游失败响应应释放 lease：forward=%v err=%+v", forward, policyErr)
			return
		}
		finished <- nil
	}()

	select {
	case <-leaseReady:
	case err := <-finished:
		t.Fatalf("pending-use barrier 建立前失败：%v", err)
	case <-time.After(3 * time.Second):
		t.Fatal("thread/start 未建立 pending-use lease")
	}

	// pending 时 cleanup dry-run 必须显式呈现 blocker，不得把该 checkout
	// 继续作为候选交给客户端。
	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	item := cleanupItemForPath(t, plan.Worktrees, target.Path)
	if item.Eligible || !containsString(item.Blockers, worktreeCleanupBlockerSessionRunning) {
		t.Fatalf("pending gateway thread 必须阻止 cleanup：%+v", item)
	}

	registryFile := filepath.Join(fixture.worktreesRoot, "registry", workspaceIDForRealPath(target.Path)+".json")
	deleteWhilePending := httptest.NewRecorder()
	fixture.router.worktreeDeleteHandler(deleteWhilePending, authedRequest(t, http.MethodPost, "/api/worktrees/delete", worktreeDeleteRequest{Path: target.Path}))
	if deleteWhilePending.Code != http.StatusBadGateway {
		t.Fatalf("pending-use 期间普通 delete 必须拒绝，got=%d body=%s", deleteWhilePending.Code, deleteWhilePending.Body.String())
	}
	if _, err := os.Stat(target.CheckoutPath); err != nil {
		t.Fatalf("pending-use 期间 checkout 必须保留：%v", err)
	}
	if _, err := os.Stat(registryFile); err != nil {
		t.Fatalf("pending-use 期间 registry 必须保留：%v", err)
	}

	close(releaseResponse)
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("上游失败后 pending-use lease 未释放")
	}

	deleteAfterRelease := httptest.NewRecorder()
	fixture.router.worktreeDeleteHandler(deleteAfterRelease, authedRequest(t, http.MethodPost, "/api/worktrees/delete", worktreeDeleteRequest{Path: target.Path}))
	if deleteAfterRelease.Code != http.StatusOK {
		t.Fatalf("lease 释放后 clean checkout 应可删除，got=%d body=%s", deleteAfterRelease.Code, deleteAfterRelease.Body.String())
	}
	if _, err := os.Stat(target.CheckoutPath); !os.IsNotExist(err) {
		t.Fatalf("lease 释放后 checkout 应已删除：%v", err)
	}
}

func TestPendingGatewayThreadUseTransitionsToRegisteredThreadBeforeRelease(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	target := fixture.worktrees[0]
	policy := newManagedWorktreeGatewayPolicyForTest(fixture.router)
	request := []byte(fmt.Sprintf(`{"id":902,"method":"thread/start","params":{"cwd":%q}}`, target.Path))
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, request); policyErr != nil {
		t.Fatalf("thread/start 策略校验失败：%s", policyErr.message)
	}
	completeReady := make(chan struct{})
	allowComplete := make(chan struct{})
	policy.beforeManagedComplete = func() {
		close(completeReady)
		<-allowComplete
	}
	response := []byte(fmt.Sprintf(`{"id":902,"result":{"thread":{"id":"thread-managed-pending","cwd":%q}}}`, target.Path))
	observeDone := make(chan error, 1)
	go func() {
		_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, response)
		if !forward || policyErr != nil {
			observeDone <- fmt.Errorf("thread/start 成功响应应登记 thread：forward=%v err=%+v", forward, policyErr)
			return
		}
		observeDone <- nil
	}()
	select {
	case <-completeReady:
	case <-time.After(3 * time.Second):
		t.Fatal("成功响应未进入全局 thread/lease 原子转移临界区")
	}
	deleteDone := make(chan error, 1)
	go func() {
		_, err := fixture.router.deleteManagedWorktree(context.Background(), target.Path, false)
		deleteDone <- err
	}()
	select {
	case err := <-deleteDone:
		t.Fatalf("全局 thread 登记与 lease 释放的 cleanup 临界区不得被 delete 穿透：%v", err)
	case <-time.After(100 * time.Millisecond):
		// delete 正确等待原子转移完成。
	}
	close(allowComplete)
	if err := <-observeDone; err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-deleteDone:
		if err == nil || !strings.Contains(err.Error(), "gateway thread") {
			t.Fatalf("lease 释放后 delete 必须立即看到已登记 gateway thread：%v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("原子转移完成后 delete 未继续")
	}
	fixture.router.managedWorktreeCleanupMu.Lock()
	pendingCount := fixture.router.managedWorktreePendingUses[target.Path]
	fixture.router.managedWorktreeCleanupMu.Unlock()
	if pendingCount != 0 {
		t.Fatalf("成功响应登记 thread 后应释放 pending-use，count=%d", pendingCount)
	}
	if _, ok := fixture.router.gatewayThread("codex", "thread-managed-pending"); !ok {
		t.Fatal("释放 pending-use 之前必须先登记全局 gateway thread")
	}
	if _, err := os.Stat(target.CheckoutPath); err != nil {
		t.Fatalf("原子转移期间 checkout 不得被删除：%v", err)
	}
}

func TestPendingGatewayThreadLeaseLifecycleGuards(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	target := fixture.worktrees[0]
	request := func(id int) []byte {
		return []byte(fmt.Sprintf(`{"id":%d,"method":"thread/start","params":{"cwd":%q}}`, id, target.Path))
	}
	pendingCount := func() int {
		fixture.router.managedWorktreeCleanupMu.Lock()
		defer fixture.router.managedWorktreeCleanupMu.Unlock()
		return fixture.router.managedWorktreePendingUses[target.Path]
	}

	policy := newManagedWorktreeGatewayPolicyForTest(fixture.router)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, request(903)); policyErr != nil {
		t.Fatalf("首个 thread/start 应建立 lease：%s", policyErr.message)
	}
	if got := pendingCount(); got != 1 {
		t.Fatalf("首个 pending 应只占用一个 lease，got=%d", got)
	}
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, request(903)); policyErr == nil || !strings.Contains(policyErr.message, "id 重复") {
		t.Fatalf("重复 JSON-RPC id 必须拒绝：%+v", policyErr)
	}
	if got := pendingCount(); got != 1 {
		t.Fatalf("重复 id 的新 lease 必须回收，不得影响原 pending，got=%d", got)
	}

	policy.mu.Lock()
	pending := policy.pendingThreads["903"]
	pending.createdAt = time.Now().Add(-appServerGatewayPendingThreadTTL - time.Minute)
	policy.pendingThreads["903"] = pending
	policy.mu.Unlock()
	if !policy.hasPendingThreadResponses() || pendingCount() != 1 {
		t.Fatal("managed pending-use 不得因 30s TTL 自动释放")
	}
	policy.close()
	if got := pendingCount(); got != 0 {
		t.Fatalf("policy.close 必须释放断连时所有 pending lease，got=%d", got)
	}

	claudePolicy := newManagedWorktreeGatewayPolicyForTest(fixture.router)
	claudePolicy.runtimeID = "claude"
	if _, policyErr := claudePolicy.validateClientFrame(websocket.TextMessage, request(904)); policyErr != nil {
		t.Fatalf("Claude bridge 应复用同一 pending-use 链路：%s", policyErr.message)
	}
	if got := pendingCount(); got != 1 {
		t.Fatalf("Claude pending thread 应建立 lease，got=%d", got)
	}
	claudePolicy.close()
	if got := pendingCount(); got != 0 {
		t.Fatalf("Claude policy.close 必须释放 lease，got=%d", got)
	}

	latePolicy := newManagedWorktreeGatewayPolicyForTest(fixture.router)
	latePolicy.beforePendingRemember = latePolicy.close
	if _, policyErr := latePolicy.validateClientFrame(websocket.TextMessage, request(905)); policyErr == nil || !strings.Contains(policyErr.message, "连接已关闭") {
		t.Fatalf("close 后晚到的 remember 必须失败：%+v", policyErr)
	}
	if got := pendingCount(); got != 0 {
		t.Fatalf("close/remember 竞态不得留下 lease，got=%d", got)
	}
}

func TestWorktreeCleanupRejectsInvalidExecutionContract(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	dryRunFalse := false

	unauthorized := httptest.NewRecorder()
	requestBody, _ := json.Marshal(worktreeCleanupRequest{})
	fixture.server.handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodPost, "/api/worktrees/cleanup", bytes.NewReader(requestBody)))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("cleanup 必须要求 Bearer，got=%d", unauthorized.Code)
	}

	withoutConfirm := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{DryRun: &dryRunFalse})
	if withoutConfirm.Code != http.StatusBadRequest {
		t.Fatalf("execute 缺 confirm 应返回 400：%d %s", withoutConfirm.Code, withoutConfirm.Body.String())
	}
	withoutPaths := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{DryRun: &dryRunFalse, Confirm: true, PlanID: "wtc_missing"})
	if withoutPaths.Code != http.StatusBadRequest {
		t.Fatalf("execute 缺 paths 应返回 400：%d %s", withoutPaths.Code, withoutPaths.Body.String())
	}
	unknownPlan := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{
		DryRun: &dryRunFalse, Confirm: true, PlanID: "wtc_missing", Paths: []string{fixture.worktrees[0].Path},
	})
	if unknownPlan.Code != http.StatusConflict {
		t.Fatalf("未知 plan_id 应返回 409：%d %s", unknownPlan.Code, unknownPlan.Body.String())
	}
}

func TestWorktreeCleanupBlocksRunningSession(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	target := fixture.worktrees[0]
	running, err := fixture.server.manager.Create(session.CreateRequest{
		Project: projects.Project{
			ID:       workspaceIDForRealPath(target.Path),
			Name:     "Running Worktree",
			Path:     target.Path,
			RealPath: target.Path,
		},
		Title: "running",
	})
	if err != nil {
		t.Fatalf("创建运行会话失败：%v", err)
	}
	t.Cleanup(func() { _ = running.Stop() })

	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	item := cleanupItemForPath(t, plan.Worktrees, target.Path)
	if item.Eligible || !containsString(item.Blockers, worktreeCleanupBlockerSessionRunning) {
		t.Fatalf("运行中的 session 必须阻止 cleanup：%+v", item)
	}
}

func TestWorktreeCleanupBlocksRepositoryMismatch(t *testing.T) {
	fixture := newWorktreeCleanupFixture(t, 4)
	target := fixture.worktrees[0]
	otherRepo := newCommittedGitRepo(t)
	target.RepositoryPath = otherRepo
	writeManagedWorktreeRegistryForTest(t, fixture.worktreesRoot, target)

	preview := requestWorktreeCleanup(t, fixture.server, worktreeCleanupRequest{})
	var plan worktreeCleanupResponse
	if err := json.NewDecoder(preview.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	item := cleanupItemForPath(t, plan.Worktrees, target.Path)
	if item.Eligible || !containsString(item.Blockers, worktreeCleanupBlockerRepositoryMismatch) {
		t.Fatalf("repository common-dir 不一致必须阻止 cleanup：%+v", item)
	}
}

func TestWorktreeCleanupBlockerCodesAreStable(t *testing.T) {
	got := []string{
		worktreeCleanupBlockerMetadataIncomplete,
		worktreeCleanupBlockerOutsideManagedRoot,
		worktreeCleanupBlockerCheckoutMissing,
		worktreeCleanupBlockerRepositoryMismatch,
		worktreeCleanupBlockerRecent,
		worktreeCleanupBlockerKeepLatest,
		worktreeCleanupBlockerGitDirty,
		worktreeCleanupBlockerGitStateUnknown,
		worktreeCleanupBlockerSessionRunning,
		worktreeCleanupBlockerRootProjectMissing,
		worktreeCleanupBlockerLastUsedUnpersisted,
	}
	want := []string{
		"metadata_incomplete", "outside_managed_root", "checkout_missing", "repository_mismatch",
		"recent", "keep_latest", "git_dirty", "git_state_unknown", "session_running",
		"root_project_missing", "last_used_unpersisted",
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("cleanup blocker code 属于 API 契约，不得漂移：got=%v want=%v", got, want)
	}
}

type worktreeCleanupFixture struct {
	server        testServer
	router        *Router
	repo          string
	worktreesRoot string
	worktrees     []managedWorktree
}
