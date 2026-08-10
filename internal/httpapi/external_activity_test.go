package httpapi

import (
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
)

func TestRouterExternalActivityUsesConfiguredCodexHome(t *testing.T) {
	cfg, registry, manager, checker, projectDir := appServerGatewayBaseFixture(t)
	codexHome := filepath.Join(t.TempDir(), "custom-codex-home")
	if err := os.MkdirAll(codexHome, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg.Codex.Env["CODEX_HOME"] = codexHome

	rolloutPath := filepath.Join(codexHome, "active-thread.jsonl")
	rollout := fmt.Sprintf(
		"{\"timestamp\":\"2026-08-11T04:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":%q,\"cwd\":%q,\"originator\":\"Codex Desktop\",\"thread_source\":\"user\"}}\n"+
			"{\"timestamp\":\"2026-08-11T04:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-custom-home\"}}\n",
		"thread-custom-home",
		projectDir,
	)
	if err := os.WriteFile(rolloutPath, []byte(rollout), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(rolloutPath, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}

	database, err := sql.Open("sqlite", filepath.Join(codexHome, "state_5.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`
		create table threads (
			id text primary key,
			cwd text not null,
			source text not null,
			thread_source text not null,
			rollout_path text not null,
			updated_at_ms integer not null,
			archived integer not null default 0
		);
		create table thread_spawn_edges (child_thread_id text);
		insert into threads values (?, ?, 'vscode', 'user', ?, 1, 0);
	`, "thread-custom-home", projectDir, rolloutPath); err != nil {
		database.Close()
		t.Fatal(err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}

	_, router := NewRouterWithRuntime(cfg, registry, manager, checker, "test", nil)
	t.Cleanup(router.Shutdown)
	active, err := router.codexDesktopThreadActive("thread-custom-home")
	if err != nil {
		t.Fatal(err)
	}
	if !active {
		t.Fatal("Router 应从配置 CODEX_HOME 的 state_5.sqlite 识别 Desktop active turn")
	}
}

type stubExternalActivitySource struct {
	activities []codexhistory.ExternalActivity
	err        error
}

func (s stubExternalActivitySource) Snapshot() ([]codexhistory.ExternalActivity, error) {
	return s.activities, s.err
}

type recordingExternalActivitySource struct {
	registrations []gatewayTurnStartRegistration
}

type gatewayTurnStartRegistration struct {
	threadID            string
	clientUserMessageID string
}

func (s *recordingExternalActivitySource) Snapshot() ([]codexhistory.ExternalActivity, error) {
	return []codexhistory.ExternalActivity{}, nil
}

func (s *recordingExternalActivitySource) RegisterGatewayTurnStart(threadID string, clientUserMessageID string) {
	s.registrations = append(s.registrations, gatewayTurnStartRegistration{
		threadID:            threadID,
		clientUserMessageID: clientUserMessageID,
	})
}

func TestExternalActivityRequiresAuthAndReturnsSanitizedSnapshot(t *testing.T) {
	handler, router := appServerGatewayRouterFixtureWithRouter(t, "", nil)
	router.externalActivity = stubExternalActivitySource{activities: []codexhistory.ExternalActivity{{
		ThreadID:     "thread-1",
		ProjectID:    "demo",
		Source:       "codex_desktop",
		State:        "running",
		TurnID:       "turn-1",
		Revision:     "revision-1",
		LastActivity: time.Date(2026, 7, 28, 14, 0, 0, 0, time.UTC),
	}}}

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/app-server/external-activity", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("external activity 必须要求 Bearer Token，got=%d", unauthorized.Code)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/external-activity", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("external activity 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	activities, ok := body["activities"].([]any)
	if !ok || len(activities) != 1 {
		t.Fatalf("活动响应异常：%v", body)
	}
	activity := activities[0].(map[string]any)
	allowed := map[string]bool{
		"thread_id": true, "project_id": true, "source": true, "state": true,
		"turn_id": true, "revision": true, "last_activity_at": true,
	}
	for key := range activity {
		if !allowed[key] {
			t.Fatalf("活动响应包含非白名单字段 %q：%v", key, activity)
		}
	}
	text := rec.Body.String()
	if strings.Contains(text, "rollout") || strings.Contains(text, "\"cwd\"") || strings.Contains(text, "\"path\"") {
		t.Fatalf("活动响应不应泄漏本机路径：%s", text)
	}
}

func TestExternalActivityFailureIsRedacted(t *testing.T) {
	handler, router := appServerGatewayRouterFixtureWithRouter(t, "", nil)
	router.externalActivity = stubExternalActivitySource{err: errors.New("/Users/private/.codex/state_5.sqlite: locked")}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/external-activity", nil))
	if rec.Code != http.StatusServiceUnavailable || strings.Contains(rec.Body.String(), "/Users/private") {
		t.Fatalf("错误响应应脱敏：code=%d body=%s", rec.Code, rec.Body.String())
	}
}
