package codexhistory

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestExternalActivityReadsStateDatabaseWithoutSQLiteCLI(t *testing.T) {
	projectDir := filepath.Join(t.TempDir(), "project")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{{
		ID: "demo", Name: "Demo", Path: projectDir,
	}})
	if err != nil {
		t.Fatal(err)
	}

	rolloutPath := filepath.Join(t.TempDir(), "thread-windows.jsonl")
	meta := `{"timestamp":"2026-07-29T11:00:00Z","type":"session_meta","payload":{"id":"thread-windows","cwd":` +
		mustJSONQuote(t, projectDir) + `,"originator":"Codex Desktop","thread_source":"user"}}`
	if err := os.WriteFile(
		rolloutPath,
		[]byte(meta+"\n"+externalEventLine("task_started", "turn-windows")+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	databasePath := filepath.Join(t.TempDir(), "state_5.sqlite")
	database, err := sql.Open("sqlite", databasePath)
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
	`, "thread-windows", projectDir, rolloutPath); err != nil {
		database.Close()
		t.Fatal(err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}

	activities, err := NewExternalActivityTracker(databasePath, registry).Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(activities) != 1 ||
		activities[0].ThreadID != "thread-windows" ||
		activities[0].State != "running" {
		t.Fatalf("unexpected external activities: %+v", activities)
	}
}

func TestExternalActivityDatabasePathUsesConfiguredCodexHome(t *testing.T) {
	configuredHome := filepath.Join(t.TempDir(), "configured-codex-home")
	processHome := filepath.Join(t.TempDir(), "process-codex-home")
	t.Setenv("CODEX_HOME", processHome)

	if got, want := ExternalActivityDatabasePath(map[string]string{"CODEX_HOME": configuredHome}), filepath.Join(configuredHome, "state_5.sqlite"); got != want {
		t.Fatalf("配置 CODEX_HOME 应优先于进程环境：want %q, got %q", want, got)
	}
	if got, want := ExternalActivityDatabasePath(nil), filepath.Join(processHome, "state_5.sqlite"); got != want {
		t.Fatalf("缺少配置时应复用进程 CODEX_HOME：want %q, got %q", want, got)
	}
}

func TestExternalActivityFiltersSourceAndProject(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	valid := fixture.writeRollout("valid", "Codex Desktop", fixture.projectDir,
		externalEventLine("task_started", "turn-valid"))
	// mimi_remote 是 thread 的创建端，不代表这个 active turn 已由 gateway 发起；
	// 没有精确 claim 时仍必须返回 external。
	mimiOrigin := fixture.writeRollout("mimi-remote", "mimi_remote", fixture.projectDir,
		externalEventLine("task_started", "turn-mimi-remote"))
	alternateOrigin := fixture.writeRollout("work-desktop", "codex_work_desktop", fixture.projectDir,
		externalEventLine("task_started", "turn-work"))
	outsideDir := t.TempDir()
	outside := fixture.writeRollout("outside", "Codex Desktop", outsideDir,
		externalEventLine("task_started", "turn-outside"))

	fixture.rows = []externalActivityTestRow{
		{ID: "valid", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: valid},
		{ID: "mimi-remote", CWD: fixture.projectDir, Source: "cli", ThreadSource: "user", RolloutPath: mimiOrigin},
		{ID: "work-desktop", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: alternateOrigin},
		{ID: "outside", CWD: outsideDir, Source: "vscode", ThreadSource: "user", RolloutPath: outside},
		{ID: "subagent", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "subagent", RolloutPath: valid},
		{ID: "unsupported", CWD: fixture.projectDir, Source: "exec", ThreadSource: "user", RolloutPath: valid},
	}

	activities, err := fixture.tracker.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(activities) != 3 || activities[0].ProjectID != "demo" || activities[1].ProjectID != "demo" || activities[2].ProjectID != "demo" {
		t.Fatalf("只应返回白名单项目的交互式顶层活动：%+v", activities)
	}
	ids := map[string]bool{}
	for _, activity := range activities {
		ids[activity.ThreadID] = true
		if activity.Source != "codex_desktop" || activity.State != "running" || activity.Revision == "" {
			t.Fatalf("外部活动字段异常：%+v", activity)
		}
	}
	if !ids["valid"] || !ids["mimi-remote"] || !ids["work-desktop"] {
		t.Fatalf("缺少合法的非 gateway-owned 顶层活动：%+v", activities)
	}
}

func TestExternalActivityTracksStartCompleteAndAbortIncrementally(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
		externalEventLine("task_started", "turn-1"))
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	first := fixture.snapshot(t)
	if len(first) != 1 || first[0].TurnID != "turn-1" {
		t.Fatalf("task_started 应进入活动态：%+v", first)
	}
	firstRevision := first[0].Revision

	fixture.appendLine(path, externalEventLine("task_complete", "turn-1"))
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("task_complete 应退出活动态：%+v", got)
	}

	fixture.appendLine(path, externalEventLine("task_started", "turn-2"))
	second := fixture.snapshot(t)
	if len(second) != 1 || second[0].TurnID != "turn-2" || second[0].Revision == firstRevision {
		t.Fatalf("追加的新 turn 应增量解析并更新 revision：%+v", second)
	}
	// 旧 turn 的迟到 terminal 不能终止新 turn。
	fixture.appendLine(path, externalEventLine("task_complete", "turn-1"))
	if got := fixture.snapshot(t); len(got) != 1 || got[0].TurnID != "turn-2" {
		t.Fatalf("迟到 terminal 不应终止当前 turn：%+v", got)
	}
	fixture.appendLine(path, externalEventLine("turn_aborted", "turn-2"))
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("turn_aborted 应退出活动态：%+v", got)
	}
}

func TestExternalActivitySkipsMalformedJSONLAndReusesCache(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
		"{broken-json",
		externalEventLine("task_started", "turn-1"))
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 1 {
		t.Fatalf("损坏行不应阻断后续 lifecycle：%+v", got)
	}
	before := fixture.tracker.Diagnostics()
	if got := fixture.snapshot(t); len(got) != 1 {
		t.Fatalf("缓存复用后活动态不应变化：%+v", got)
	}
	after := fixture.tracker.Diagnostics()
	if after.CandidateQueries != before.CandidateQueries ||
		after.FileScans != before.FileScans ||
		after.CacheHits <= before.CacheHits ||
		after.MalformedLines != 1 {
		t.Fatalf("未变化的 DB/rollout 应复用缓存：before=%+v after=%+v", before, after)
	}
}

func TestExternalActivitySilentTurnRemainsActiveUntilTerminal(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 28, 15, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
		externalEventLine("task_started", "turn-1"))
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}
	old := now.Add(-31 * time.Minute)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	// rollout 文件静默不等于 turn 结束：正常等待和 abrupt crash 都可能没有新写入。
	// 这里选择保守地继续只读展示，避免误把仍运行的 turn 判为空闲。
	if got := fixture.snapshot(t); len(got) != 1 || got[0].TurnID != "turn-1" {
		t.Fatalf("超过 31 分钟但没有 terminal 的 active turn 仍应保持 external：%+v", got)
	}

	fixture.appendLine(path, externalEventLineAt(now, "task_complete", "turn-1"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("匹配 task_complete 后应移除 external 活动：%+v", got)
	}

	fixture.appendLine(path, externalEventLineAt(now.Add(time.Second), "task_started", "turn-2"))
	if err := os.Chtimes(path, now.Add(time.Second), now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if got := fixture.snapshot(t); len(got) != 1 || got[0].TurnID != "turn-2" {
		t.Fatalf("terminal 后的新 active turn 应重新识别为 external：%+v", got)
	}
}

func TestExternalActivityWithoutStateDatabaseReturnsEmpty(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	if err := os.Remove(fixture.db); err != nil {
		t.Fatal(err)
	}

	activities, err := fixture.tracker.Snapshot()
	if err != nil {
		t.Fatalf("尚未创建 Codex 状态库时不应让活动接口失败：%v", err)
	}
	if len(activities) != 0 {
		t.Fatalf("没有状态库时应返回空活动：%+v", activities)
	}
}

func TestExternalActivityExcludesExactGatewayOwnedTurn(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.SetCodexRuntimeIdentity("managed_websocket", now.Add(-10*time.Minute))
	fixture.tracker.RegisterGatewayTurnStart("thread-ipad", "client-ipad")
	// 即使 originator 是 mimi_remote，精确 Thread+Turn gateway claim 仍应排除该 turn。
	path := fixture.writeRollout("thread-ipad", "mimi_remote", fixture.projectDir,
		externalEventLineAt(now.Add(100*time.Millisecond), "task_started", "turn-ipad"),
		externalUserMessageLine(now.Add(500*time.Millisecond), "client-ipad"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-ipad", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("同线程、同 client_id 且时间相符的 gateway turn 不应被识别为 Desktop 外部活动：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if !entry.active || !entry.gatewayOwned || entry.turnID != "turn-ipad" {
		t.Fatalf("rollout 应保留运行态并标记 gateway 归属：%+v", entry)
	}
}

func TestExternalActivityDelayedUserMessageAfterTaskStartedStillClaimsGatewayTurn(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-ipad", "client-ipad")
	path := fixture.writeRollout(
		"thread-ipad",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(now.Add(time.Second), "task_started", "turn-ipad"),
		// managed app-server 冷启动时真实观察到 user_message 比 task_started
		// 晚约 13 秒落盘；精确 client ID 不能因此被当成 Mac external。
		externalUserMessageLine(now.Add(15*time.Second), "client-ipad"),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-ipad", CWD: fixture.projectDir, Source: "vscode",
		ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("延迟落盘的精确 gateway 消息不应被识别为 Desktop external：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if !entry.active || !entry.gatewayOwned || entry.turnID != "turn-ipad" {
		t.Fatalf("延迟 user_message 应恢复精确 gateway 归属：%+v", entry)
	}
}

func TestExternalActivityExactMessageCannotClaimTurnStartedOutsideGatewayWindow(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-1", "client-ipad")
	path := fixture.writeRollout(
		"thread-1",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(
			now.Add(gatewayTurnStartWindow+time.Second),
			"task_started",
			"turn-desktop",
		),
		externalUserMessageLine(
			now.Add(gatewayTurnStartWindow+2*time.Second),
			"client-ipad",
		),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode",
		ThreadSource: "user", RolloutPath: path,
	}}

	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-desktop" {
		t.Fatalf("登记窗口外的新 turn 必须保持 external 只读：%+v", got)
	}
	if entry := fixture.tracker.files[path]; entry.gatewayOwned || entry.gatewayTurnPending {
		t.Fatalf("登记窗口外的 turn 不得吸收失败 gateway 请求证据：%+v", entry)
	}
}

func TestExternalActivityAlsoSupportsUserMessageBeforeTaskStarted(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.SetCodexRuntimeIdentity("managed_websocket", now.Add(-10*time.Minute))
	fixture.tracker.RegisterGatewayTurnStart("thread-ipad", "client-ipad")
	path := fixture.writeRollout("thread-ipad", "Codex Desktop", fixture.projectDir,
		externalUserMessageLine(now.Add(100*time.Millisecond), "client-ipad"),
		externalEventLineAt(now.Add(500*time.Millisecond), "task_started", "turn-ipad"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-ipad", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("user_message 先落盘时也应把紧随其后的 task_started 识别为 gateway turn：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if !entry.active || !entry.gatewayOwned || entry.turnID != "turn-ipad" {
		t.Fatalf("反向落盘顺序也应保留 gateway 归属：%+v", entry)
	}
	claim := fixture.tracker.ownedGatewayTurns[gatewayOwnedTurnClaimKey("thread-ipad", "turn-ipad")]
	if claim.runtimeKind != "managed_websocket" || !claim.runtimeStartedAt.Equal(now.Add(-10*time.Minute)) {
		t.Fatalf("反向落盘顺序必须保留 runtime identity：%+v", claim)
	}
}

func TestExternalActivityExpiredPendingEvidenceCannotHideLaterDesktopTurn(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-1", "client-ipad")
	path := fixture.writeRollout(
		"thread-1",
		"Codex Desktop",
		fixture.projectDir,
		externalUserMessageLine(now.Add(100*time.Millisecond), "client-ipad"),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("只有 user_message、尚未开始 turn 时不应产生外部活动：%+v", got)
	}
	if !fixture.tracker.files[path].gatewayTurnPending {
		t.Fatal("反向落盘顺序应暂存带时间界限的 gateway 证据")
	}

	now = now.Add(gatewayTurnLifecycleWindow + time.Second)
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("pending 过期时仍没有 active turn，不应产生外部活动：%+v", got)
	}
	if fixture.tracker.files[path].gatewayTurnPending {
		t.Fatal("超过生命周期关联窗口后，pending gateway 证据必须主动失效")
	}

	now = now.Add(gatewayTurnRegistrationTTL + time.Second)
	fixture.appendLine(path, externalEventLineAt(now, "task_started", "turn-desktop"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-desktop" {
		t.Fatalf("过期 pending 证据不能隐藏稍后的 Desktop turn：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if entry.gatewayOwned || entry.gatewayTurnPending {
		t.Fatalf("Desktop turn 不应继承过期 gateway 证据：%+v", entry)
	}
}

func TestExternalActivityMatchingUserMessageCannotClaimOlderActiveDesktopTurn(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-1", "client-ipad")
	path := fixture.writeRollout(
		"thread-1",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(now.Add(-time.Minute), "task_started", "turn-desktop"),
		externalUserMessageLine(now.Add(100*time.Millisecond), "client-ipad"),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}

	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-desktop" {
		t.Fatalf("匹配消息不能把 registration 之前已运行的 Desktop turn 改写为 gateway 所有：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if entry.gatewayOwned || entry.gatewayTurnPending {
		t.Fatalf("旧 Desktop turn 不应吸收新 gateway 消息证据：%+v", entry)
	}
}

func TestExternalActivityGatewayOwnershipRequiresExactEvidence(t *testing.T) {
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	tests := []struct {
		name             string
		registeredThread string
		registeredClient string
		eventClient      string
		eventAt          time.Time
	}{
		{
			name:             "wrong client id",
			registeredThread: "thread-1",
			registeredClient: "client-ipad",
			eventClient:      "client-desktop",
			eventAt:          now.Add(time.Second),
		},
		{
			name:             "wrong thread",
			registeredThread: "thread-other",
			registeredClient: "client-ipad",
			eventClient:      "client-ipad",
			eventAt:          now.Add(time.Second),
		},
		{
			name:             "old rollout timestamp",
			registeredThread: "thread-1",
			registeredClient: "client-ipad",
			eventClient:      "client-ipad",
			eventAt:          now.Add(-gatewayTurnRegistrationTTL),
		},
		{
			name:             "missing client id",
			registeredThread: "thread-1",
			registeredClient: "client-ipad",
			eventClient:      "",
			eventAt:          now.Add(time.Second),
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fixture := newExternalActivityTrackerFixture(t)
			fixture.tracker.now = func() time.Time { return now }
			fixture.tracker.RegisterGatewayTurnStart(tc.registeredThread, tc.registeredClient)
			path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
				externalUserMessageLine(tc.eventAt, tc.eventClient),
				externalEventLine("task_started", "turn-desktop"))
			if err := os.Chtimes(path, now, now); err != nil {
				t.Fatal(err)
			}
			fixture.rows = []externalActivityTestRow{{
				ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
			}}

			got := fixture.snapshot(t)
			if len(got) != 1 || got[0].ThreadID != "thread-1" || got[0].TurnID != "turn-desktop" {
				t.Fatalf("证据不完整时必须 fail-safe 保留 Desktop 外部活动：%+v", got)
			}
		})
	}
}

func TestExternalActivityNewDesktopTurnResetsGatewayOwnership(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	fixture.tracker.RegisterGatewayTurnStart("thread-1", "client-ipad")
	path := fixture.writeRollout("thread-1", "Codex Desktop", fixture.projectDir,
		externalUserMessageLine(now.Add(100*time.Millisecond), "client-ipad"),
		externalEventLineAt(now.Add(500*time.Millisecond), "task_started", "turn-ipad"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-1", CWD: fixture.projectDir, Source: "vscode", ThreadSource: "user", RolloutPath: path,
	}}
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("第一轮 iPad turn 不应显示为外部活动：%+v", got)
	}

	// 后续没有匹配 user_message 的新 task_started 是真正的 Desktop turn，
	// 必须覆盖上一轮 gateway 归属，重新进入“仅观察”保护。
	fixture.appendLine(path, externalEventLineAt(now.Add(time.Second), "task_started", "turn-desktop"))
	if err := os.Chtimes(path, now.Add(time.Second), now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-desktop" {
		t.Fatalf("新的 Desktop task_started 应恢复外部活动：%+v", got)
	}

	fixture.appendLine(path, externalEventLineAt(now.Add(2*time.Second), "task_complete", "turn-desktop"))
	if err := os.Chtimes(path, now.Add(2*time.Second), now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("terminal 应清除活动与归属状态：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if entry.active || entry.gatewayOwned || entry.gatewayTurnPending {
		t.Fatalf("terminal 后不应残留 gateway 状态：%+v", entry)
	}
}

func TestExternalActivityPersistentClaimSurvivesTrackerRestartAndCandidateGap(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 31, 1, 0, 0, 0, time.UTC)
	claimPath := filepath.Join(t.TempDir(), "private-state", "gateway-turn-claims.json")
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })
	fixture.tracker.RegisterGatewayTurnStart("thread-restart", "client-restart")
	path := fixture.writeRollout(
		"thread-restart",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(now.Add(-time.Minute), "task_started", "turn-history"),
		externalEventLineAt(now.Add(-50*time.Second), "task_complete", "turn-history"),
		externalEventLineAt(now.Add(100*time.Millisecond), "task_started", "turn-ipad"),
		externalUserMessageLine(now.Add(500*time.Millisecond), "client-restart"),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	row := externalActivityTestRow{
		ID: "thread-restart", CWD: fixture.projectDir, Source: "vscode",
		ThreadSource: "user", RolloutPath: path,
	}
	fixture.rows = []externalActivityTestRow{row}

	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("首个 Tracker 应确认 iPad-owned turn：%+v", got)
	}
	if len(fixture.tracker.ownedGatewayTurns) != 1 {
		t.Fatalf("精确 Thread+Turn claim 应提升并落盘：%+v", fixture.tracker.ownedGatewayTurns)
	}
	if runtime.GOOS != "windows" {
		dirInfo, err := os.Stat(filepath.Dir(claimPath))
		if err != nil {
			t.Fatal(err)
		}
		fileInfo, err := os.Stat(claimPath)
		if err != nil {
			t.Fatal(err)
		}
		if got := dirInfo.Mode().Perm(); got != 0o700 {
			t.Fatalf("claim 目录权限必须是 0700，got=%o", got)
		}
		if got := fileInfo.Mode().Perm(); got != 0o600 {
			t.Fatalf("claim 文件权限必须是 0600，got=%o", got)
		}
	}

	// 模拟第二个 Router/Tracker 启动时列表短暂缺页。缺页不能删除 claim。
	fixture.rows = nil
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now.Add(time.Second) })
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("候选缺页不应制造外部活动：%+v", got)
	}
	storedAfterGap, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if len(storedAfterGap.Owned) != 1 ||
		storedAfterGap.Owned[0].ThreadID != "thread-restart" ||
		storedAfterGap.Owned[0].TurnID != "turn-ipad" {
		t.Fatalf("候选缺页必须保留精确 claim：%+v", storedAfterGap)
	}

	// 列表恢复后，新 Tracker 从包含历史旧 turn 的同一 rollout 全量重扫。
	// 历史 task_started 不能提前删除时间更晚的持久化 claim。
	fixture.rows = []externalActivityTestRow{row}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now.Add(2 * time.Second) })
	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("重启后的 Tracker 应恢复 gateway-owned 证据：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if !entry.active || !entry.gatewayOwned || entry.turnID != "turn-ipad" {
		t.Fatalf("重建 rollout cache 后归属异常：%+v", entry)
	}

	// 同一 Thread 后续出现没有 gateway 证据的新 Mac turn，必须立即清旧 claim，
	// 恢复仅观察保护；再重启一次也不能被旧 claim 隐藏。
	now = now.Add(3 * time.Second)
	fixture.appendLine(path, externalEventLineAt(now, "task_started", "turn-mac-next"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-mac-next" {
		t.Fatalf("真正的新 Mac turn 必须保持 external 只读：%+v", got)
	}
	now = now.Add(time.Second)
	fixture.appendLine(path, externalEventLineAt(now, "task_complete", "turn-ipad"))
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	got = fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-mac-next" {
		t.Fatalf("旧 gateway turn 的迟到 terminal 不能结束或隐藏新 Mac turn：%+v", got)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now.Add(time.Second) })
	got = fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-mac-next" {
		t.Fatalf("清理旧 claim 后再次重启仍应识别新 Mac turn：%+v", got)
	}
	storedAfterMacTurn, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if len(storedAfterMacTurn.Owned) != 0 {
		t.Fatalf("不同的新 turn 必须清理旧 owned claim：%+v", storedAfterMacTurn.Owned)
	}
}

func TestExternalActivityManagedRuntimeRestartProjectsOwnedTurnAsInterrupted(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	claimPath := filepath.Join(t.TempDir(), "state", "gateway-turn-claims.json")
	registeredAt := now.Add(-2 * time.Minute)
	lastEvidenceAt := now.Add(-time.Minute)
	oldRuntimeStartedAt := now.Add(-10 * time.Minute)
	if err := newGatewayTurnClaimStore(claimPath).save(gatewayTurnClaimStoreFile{
		Owned: []gatewayTurnOwnedClaimStoreEntry{{
			ThreadID:         "thread-restarted",
			TurnID:           "turn-restarted",
			RegisteredAt:     registeredAt,
			LastEvidenceAt:   lastEvidenceAt,
			RuntimeKind:      "managed_websocket",
			RuntimeStartedAt: oldRuntimeStartedAt,
		}},
	}); err != nil {
		t.Fatal(err)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })

	fixture.tracker.SetCodexRuntimeIdentity("managed_websocket", now)
	interrupted := fixture.tracker.GatewayInterruptedTurns("thread-restarted")
	if got := interrupted["turn-restarted"]; !got.Equal(now) {
		t.Fatalf("managed runtime 重启后应记录精确中断 Turn：%+v", interrupted)
	}
	if len(fixture.tracker.ownedGatewayTurns) != 0 {
		t.Fatalf("已被上一代进程终止的 owned claim 不应继续 active：%+v", fixture.tracker.ownedGatewayTurns)
	}
	stored, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if stored.Version != gatewayTurnClaimStoreVersion || len(stored.Owned) != 0 || len(stored.Interrupted) != 1 {
		t.Fatalf("重启中断账本应原子持久化为 v2：%+v", stored)
	}
}

func TestExternalActivityGatewayOwnedClaimPersistsRuntimeIdentity(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	runtimeStartedAt := now.Add(-10 * time.Minute)
	claimPath := filepath.Join(t.TempDir(), "state", "gateway-turn-claims.json")
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })
	fixture.tracker.SetCodexRuntimeIdentity("managed_websocket", runtimeStartedAt)
	fixture.tracker.RegisterGatewayTurnStart("thread-runtime-identity", "client-runtime-identity")
	path := fixture.writeRollout(
		"thread-runtime-identity",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(now.Add(100*time.Millisecond), "task_started", "turn-runtime-identity"),
		externalUserMessageLine(now.Add(500*time.Millisecond), "client-runtime-identity"),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-runtime-identity", CWD: fixture.projectDir, Source: "vscode",
		ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("当前 runtime 的 gateway Turn 不应成为 external：%+v", got)
	}
	stored, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if len(stored.Owned) != 1 ||
		stored.Owned[0].RuntimeKind != "managed_websocket" ||
		!stored.Owned[0].RuntimeStartedAt.Equal(runtimeStartedAt) {
		t.Fatalf("精确 claim 必须绑定产生它的 runtime 类型与代际：%+v", stored.Owned)
	}
}

func TestExternalActivitySharedRuntimeDoesNotInterruptNewerOwnedTurn(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	claimPath := filepath.Join(t.TempDir(), "state", "gateway-turn-claims.json")
	sharedRuntimeStartedAt := now.Add(-time.Hour)
	if err := newGatewayTurnClaimStore(claimPath).save(gatewayTurnClaimStoreFile{
		Owned: []gatewayTurnOwnedClaimStoreEntry{{
			ThreadID:         "thread-shared",
			TurnID:           "turn-shared",
			RegisteredAt:     now.Add(-2 * time.Minute),
			LastEvidenceAt:   now.Add(-time.Minute),
			RuntimeKind:      "local_daemon",
			RuntimeStartedAt: sharedRuntimeStartedAt,
		}},
	}); err != nil {
		t.Fatal(err)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })

	// shared daemon 比 Turn 更早启动；agentd 自身重启不代表 runtime 里的 Turn 消失。
	fixture.tracker.SetCodexRuntimeIdentity("local_daemon", sharedRuntimeStartedAt)
	if got := fixture.tracker.GatewayInterruptedTurns("thread-shared"); len(got) != 0 {
		t.Fatalf("仍存活的 shared runtime Turn 不得被误标中断：%+v", got)
	}
	if len(fixture.tracker.ownedGatewayTurns) != 1 {
		t.Fatalf("shared runtime 的精确 owned claim 应保留：%+v", fixture.tracker.ownedGatewayTurns)
	}
}

func TestExternalActivityVersionOneClaimDoesNotGuessRestartInterruption(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	claimPath := filepath.Join(t.TempDir(), "state", "gateway-turn-claims.json")
	if err := os.MkdirAll(filepath.Dir(claimPath), 0o700); err != nil {
		t.Fatal(err)
	}
	v1 := fmt.Sprintf(
		`{"version":1,"owned":[{"thread_id":"thread-v1","turn_id":"turn-v1","last_evidence_at":%q}]}`,
		now.Add(-time.Hour).Format(time.RFC3339Nano),
	)
	if err := os.WriteFile(claimPath, []byte(v1), 0o600); err != nil {
		t.Fatal(err)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })

	fixture.tracker.SetCodexRuntimeIdentity("managed_websocket", now)
	if got := fixture.tracker.GatewayInterruptedTurns("thread-v1"); len(got) != 0 {
		t.Fatalf("v1 claim 来源未知，不得猜测为重启中断：%+v", got)
	}
	stored, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if stored.Version != 2 || len(stored.Owned) != 0 || len(stored.Interrupted) != 0 {
		t.Fatalf("v1 claim 应升级并安全撤销未知写归属：%+v", stored)
	}
}

func TestExternalActivityRuntimeKindChangeDoesNotGuessInterruption(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	claimPath := filepath.Join(t.TempDir(), "state", "gateway-turn-claims.json")
	if err := newGatewayTurnClaimStore(claimPath).save(gatewayTurnClaimStoreFile{
		Owned: []gatewayTurnOwnedClaimStoreEntry{{
			ThreadID: "thread-kind-change", TurnID: "turn-kind-change",
			RegisteredAt: now.Add(-2 * time.Minute), LastEvidenceAt: now.Add(-time.Minute),
			RuntimeKind: "local_daemon", RuntimeStartedAt: now.Add(-time.Hour),
		}},
	}); err != nil {
		t.Fatal(err)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })

	fixture.tracker.SetCodexRuntimeIdentity("managed_websocket", now)
	if got := fixture.tracker.GatewayInterruptedTurns("thread-kind-change"); len(got) != 0 {
		t.Fatalf("runtime 类型变化时旧进程可能仍存活，不得伪造中断：%+v", got)
	}
	if len(fixture.tracker.ownedGatewayTurns) != 0 {
		t.Fatalf("当前 gateway 也不能沿用其他 runtime 的写归属：%+v", fixture.tracker.ownedGatewayTurns)
	}
}

func TestExternalActivityConflictingOwnedAndInterruptedTurnFailsClosed(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	runtimeStartedAt := now.Add(-time.Hour)
	claimPath := filepath.Join(t.TempDir(), "state", "gateway-turn-claims.json")
	if err := newGatewayTurnClaimStore(claimPath).save(gatewayTurnClaimStoreFile{
		Owned: []gatewayTurnOwnedClaimStoreEntry{{
			ThreadID: "thread-conflict", TurnID: "turn-conflict",
			RegisteredAt: now.Add(-2 * time.Minute), LastEvidenceAt: now.Add(-time.Minute),
			RuntimeKind: "local_daemon", RuntimeStartedAt: runtimeStartedAt,
		}},
		Interrupted: []gatewayTurnInterruptedStoreEntry{{
			ThreadID: "thread-conflict", TurnID: "turn-conflict", InterruptedAt: now.Add(-30 * time.Second),
		}},
	}); err != nil {
		t.Fatal(err)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })

	fixture.tracker.SetCodexRuntimeIdentity("local_daemon", runtimeStartedAt)
	if len(fixture.tracker.ownedGatewayTurns) != 0 {
		t.Fatalf("矛盾状态不得保留写归属：%+v", fixture.tracker.ownedGatewayTurns)
	}
	if got := fixture.tracker.GatewayInterruptedTurns("thread-conflict"); len(got) != 0 {
		t.Fatalf("矛盾状态不得伪造中断投影：%+v", got)
	}
	stored, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if len(stored.Owned) != 0 || len(stored.Interrupted) != 0 {
		t.Fatalf("矛盾状态应从私有账本清除：%+v", stored)
	}
}

func TestExternalActivityLateTerminalClearsRestartInterruption(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	claimPath := filepath.Join(t.TempDir(), "state", "gateway-turn-claims.json")
	if err := newGatewayTurnClaimStore(claimPath).save(gatewayTurnClaimStoreFile{
		Interrupted: []gatewayTurnInterruptedStoreEntry{{
			ThreadID: "thread-late-terminal", TurnID: "turn-late-terminal", InterruptedAt: now.Add(-time.Minute),
		}},
	}); err != nil {
		t.Fatal(err)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })
	path := fixture.writeRollout(
		"thread-late-terminal",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(now.Add(-2*time.Minute), "task_started", "turn-late-terminal"),
		externalEventLineAt(now.Add(-30*time.Second), "task_complete", "turn-late-terminal"),
	)
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-late-terminal", CWD: fixture.projectDir, Source: "vscode",
		ThreadSource: "user", RolloutPath: path,
	}}

	if got := fixture.snapshot(t); len(got) != 0 {
		t.Fatalf("迟到 terminal 后不应残留 external activity：%+v", got)
	}
	if got := fixture.tracker.GatewayInterruptedTurns("thread-late-terminal"); len(got) != 0 {
		t.Fatalf("上游已有真实 terminal 时应清理中断投影：%+v", got)
	}
	stored, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if len(stored.Interrupted) != 0 {
		t.Fatalf("迟到 terminal 应同步清理落盘账本：%+v", stored.Interrupted)
	}
}

func TestGatewayTurnClaimStoreMaximumValidEntriesFitSizeLimit(t *testing.T) {
	now := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	stored := gatewayTurnClaimStoreFile{
		Owned:       make([]gatewayTurnOwnedClaimStoreEntry, 0, gatewayTurnClaimStoreLimit),
		Interrupted: make([]gatewayTurnInterruptedStoreEntry, 0, gatewayInterruptedTurnStoreLimit),
	}
	for index := 0; index < gatewayTurnClaimStoreLimit; index++ {
		threadID := strings.Repeat("t", gatewayTurnRegistrationIDMax-6) + fmt.Sprintf("%06d", index)
		turnID := strings.Repeat("u", gatewayTurnRegistrationIDMax-6) + fmt.Sprintf("%06d", index)
		stored.Owned = append(stored.Owned, gatewayTurnOwnedClaimStoreEntry{
			ThreadID: threadID, TurnID: turnID, RegisteredAt: now, LastEvidenceAt: now,
			RuntimeKind: "managed_websocket", RuntimeStartedAt: now.Add(-time.Hour),
		})
	}
	for index := 0; index < gatewayInterruptedTurnStoreLimit; index++ {
		threadID := strings.Repeat("i", gatewayTurnRegistrationIDMax-6) + fmt.Sprintf("%06d", index)
		turnID := strings.Repeat("v", gatewayTurnRegistrationIDMax-6) + fmt.Sprintf("%06d", index)
		stored.Interrupted = append(stored.Interrupted, gatewayTurnInterruptedStoreEntry{
			ThreadID: threadID, TurnID: turnID, InterruptedAt: now,
		})
	}
	claimPath := filepath.Join(t.TempDir(), "state", "gateway-turn-claims.json")
	if err := newGatewayTurnClaimStore(claimPath).save(stored); err != nil {
		t.Fatalf("全部合法容量不应超过文件大小上限：%v", err)
	}
	info, err := os.Stat(claimPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() > gatewayTurnClaimStoreMaxBytes {
		t.Fatalf("claim store 超过大小上限：%d", info.Size())
	}
	loaded, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.Owned) != gatewayTurnClaimStoreLimit ||
		len(loaded.Interrupted) != gatewayInterruptedTurnStoreLimit {
		t.Fatalf("最大合法条目未完整保存：owned=%d interrupted=%d", len(loaded.Owned), len(loaded.Interrupted))
	}
}

func TestExternalActivityPersistentClaimClearsOnTerminalAndExpiresToExternal(t *testing.T) {
	tests := []struct {
		name             string
		finishTurn       func(*externalActivityTrackerFixture, string, *time.Time)
		wantExternalTurn bool
	}{
		{
			name:             "matching terminal",
			wantExternalTurn: false,
			finishTurn: func(fixture *externalActivityTrackerFixture, path string, now *time.Time) {
				*now = now.Add(time.Second)
				fixture.appendLine(path, externalEventLineAt(*now, "turn_aborted", "turn-ipad"))
				if err := os.Chtimes(path, *now, *now); err != nil {
					fixture.t.Fatal(err)
				}
			},
		},
		{
			name:             "claim ttl expires while turn stays active",
			wantExternalTurn: true,
			finishTurn: func(_ *externalActivityTrackerFixture, _ string, now *time.Time) {
				*now = now.Add(gatewayOwnedTurnClaimTTL + time.Second)
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fixture := newExternalActivityTrackerFixture(t)
			now := time.Date(2026, 7, 31, 2, 0, 0, 0, time.UTC)
			claimPath := filepath.Join(t.TempDir(), "state", "claims.json")
			fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })
			fixture.tracker.RegisterGatewayTurnStart("thread-ipad", "client-ipad")
			path := fixture.writeRollout(
				"thread-ipad",
				"Codex Desktop",
				fixture.projectDir,
				externalEventLineAt(now.Add(100*time.Millisecond), "task_started", "turn-ipad"),
				externalUserMessageLine(now.Add(500*time.Millisecond), "client-ipad"),
			)
			if err := os.Chtimes(path, now, now); err != nil {
				t.Fatal(err)
			}
			fixture.rows = []externalActivityTestRow{{
				ID: "thread-ipad", CWD: fixture.projectDir, Source: "vscode",
				ThreadSource: "user", RolloutPath: path,
			}}
			if got := fixture.snapshot(t); len(got) != 0 {
				t.Fatalf("iPad turn 不应是 external：%+v", got)
			}

			tc.finishTurn(fixture, path, &now)
			got := fixture.snapshot(t)
			if tc.wantExternalTurn {
				if len(got) != 1 || got[0].TurnID != "turn-ipad" {
					t.Fatalf("claim TTL 过期但没有 terminal 时应安全降级为 external：%+v", got)
				}
			} else if len(got) != 0 {
				t.Fatalf("匹配 terminal 后不应返回 external：%+v", got)
			}
			if len(fixture.tracker.ownedGatewayTurns) != 0 {
				t.Fatalf("terminal/TTL 后必须清理内存 claim：%+v", fixture.tracker.ownedGatewayTurns)
			}
			stored, err := newGatewayTurnClaimStore(claimPath).load()
			if err != nil {
				t.Fatal(err)
			}
			if len(stored.Owned) != 0 {
				t.Fatalf("terminal/TTL 后必须清理落盘 claim：%+v", stored.Owned)
			}
		})
	}
}

func TestExternalActivityExpiredClaimWithFreshRolloutFailsClosedAsExternal(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 31, 3, 0, 0, 0, time.UTC)
	claimPath := filepath.Join(t.TempDir(), "state", "claims.json")
	expiredEvidenceAt := now.Add(-gatewayOwnedTurnClaimTTL - time.Second)
	if err := newGatewayTurnClaimStore(claimPath).save(gatewayTurnClaimStoreFile{
		Owned: []gatewayTurnOwnedClaimStoreEntry{{
			ThreadID:       "thread-expired",
			TurnID:         "turn-expired",
			LastEvidenceAt: expiredEvidenceAt,
		}},
	}); err != nil {
		t.Fatal(err)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })
	path := fixture.writeRollout(
		"thread-expired",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(expiredEvidenceAt, "task_started", "turn-expired"),
	)
	// 即使 rollout 因其他落盘动作仍处于 fresh 窗口，过期 claim 也不能继续
	// 放宽控制；必须 fail-closed 恢复为真正的 external 只读活动。
	if err := os.Chtimes(path, now.Add(-5*time.Minute), now.Add(-5*time.Minute)); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-expired", CWD: fixture.projectDir, Source: "vscode",
		ThreadSource: "user", RolloutPath: path,
	}}

	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-expired" {
		t.Fatalf("过期 claim + fresh rollout 必须保持 external 只读：%+v", got)
	}
	entry := fixture.tracker.files[path]
	if entry.gatewayOwned {
		t.Fatalf("过期 claim 不得恢复 gateway ownership：%+v", entry)
	}
	stored, err := newGatewayTurnClaimStore(claimPath).load()
	if err != nil {
		t.Fatal(err)
	}
	if len(stored.Owned) != 0 {
		t.Fatalf("过期 claim 应从落盘状态清理：%+v", stored.Owned)
	}
}

func TestExternalActivityCorruptClaimStoreFailsClosed(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 31, 3, 0, 0, 0, time.UTC)
	claimPath := filepath.Join(t.TempDir(), "state", "claims.json")
	if err := os.MkdirAll(filepath.Dir(claimPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(claimPath, []byte(`{"version":1,"owned":[`), 0o600); err != nil {
		t.Fatal(err)
	}
	fixture.replaceTrackerWithClaimStore(claimPath, func() time.Time { return now })
	path := fixture.writeRollout(
		"thread-desktop",
		"Codex Desktop",
		fixture.projectDir,
		externalEventLineAt(now, "task_started", "turn-desktop"),
	)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	fixture.rows = []externalActivityTestRow{{
		ID: "thread-desktop", CWD: fixture.projectDir, Source: "vscode",
		ThreadSource: "user", RolloutPath: path,
	}}

	got := fixture.snapshot(t)
	if len(got) != 1 || got[0].TurnID != "turn-desktop" {
		t.Fatalf("损坏 claim store 必须 fail-closed 保留 external：%+v", got)
	}
	if fixture.tracker.Diagnostics().ClaimStoreErrors != 1 {
		t.Fatalf("损坏 claim store 应记录一次脱敏诊断：%+v", fixture.tracker.Diagnostics())
	}
}

func TestGatewayTurnRegistrationsAreBoundedAndExpire(t *testing.T) {
	fixture := newExternalActivityTrackerFixture(t)
	now := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	fixture.tracker.now = func() time.Time { return now }
	for index := 0; index < gatewayTurnRegistrationLimit+7; index++ {
		fixture.tracker.RegisterGatewayTurnStart("thread-1", fmt.Sprintf("client-%d", index))
		now = now.Add(time.Microsecond)
	}
	if got := len(fixture.tracker.gatewayTurns); got != gatewayTurnRegistrationLimit {
		t.Fatalf("gateway 登记表必须有容量上限：got=%d want=%d", got, gatewayTurnRegistrationLimit)
	}

	now = now.Add(gatewayTurnRegistrationTTL + time.Second)
	fixture.tracker.RegisterGatewayTurnStart("thread-fresh", "client-fresh")
	if got := len(fixture.tracker.gatewayTurns); got != 1 {
		t.Fatalf("过期 gateway 登记应在新写入时被裁剪：got=%d entries=%+v", got, fixture.tracker.gatewayTurns)
	}
	if _, ok := fixture.tracker.gatewayTurns[gatewayTurnRegistrationKey("thread-fresh", "client-fresh")]; !ok {
		t.Fatal("最新 gateway 登记不应被裁剪")
	}
}

type externalActivityTestRow struct {
	ID           string `json:"id"`
	CWD          string `json:"cwd"`
	Source       string `json:"source"`
	ThreadSource string `json:"thread_source"`
	RolloutPath  string `json:"rollout_path"`
}

type externalActivityTrackerFixture struct {
	t          *testing.T
	projectDir string
	db         string
	tracker    *ExternalActivityTracker
	rows       []externalActivityTestRow
}

func newExternalActivityTrackerFixture(t *testing.T) *externalActivityTrackerFixture {
	t.Helper()
	projectDir := filepath.Join(t.TempDir(), "project")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{{
		ID: "demo", Name: "Demo", Path: projectDir,
	}})
	if err != nil {
		t.Fatal(err)
	}
	db := filepath.Join(t.TempDir(), "state_5.sqlite")
	if err := os.WriteFile(db, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	fixture := &externalActivityTrackerFixture{
		t:          t,
		projectDir: projectDir,
		db:         db,
		tracker:    NewExternalActivityTracker(db, registry),
	}
	fixture.tracker.query = func(_ string, query string) ([]byte, error) {
		if strings.Contains(query, "pragma_table_info") {
			return []byte(`[
				{"table_name":"threads","name":"id"},
				{"table_name":"threads","name":"cwd"},
				{"table_name":"threads","name":"source"},
				{"table_name":"threads","name":"thread_source"},
				{"table_name":"threads","name":"rollout_path"},
				{"table_name":"threads","name":"updated_at_ms"},
				{"table_name":"threads","name":"archived"},
				{"table_name":"thread_spawn_edges","name":"child_thread_id"}
			]`), nil
		}
		return json.Marshal(fixture.rows)
	}
	return fixture
}

func (f *externalActivityTrackerFixture) replaceTrackerWithClaimStore(
	claimStorePath string,
	now func() time.Time,
) {
	f.t.Helper()
	query := f.tracker.query
	f.tracker = NewExternalActivityTrackerWithClaimStore(
		f.db,
		f.tracker.registry,
		claimStorePath,
	)
	f.tracker.query = query
	f.tracker.now = now
}

func (f *externalActivityTrackerFixture) writeRollout(threadID, originator, cwd string, lines ...string) string {
	f.t.Helper()
	path := filepath.Join(f.t.TempDir(), threadID+".jsonl")
	meta := `{"timestamp":"2026-07-28T14:00:00Z","type":"session_meta","payload":{"id":` +
		mustJSONQuote(f.t, threadID) + `,"cwd":` + mustJSONQuote(f.t, cwd) +
		`,"originator":` + mustJSONQuote(f.t, originator) + `,"thread_source":"user"}}`
	all := append([]string{meta}, lines...)
	if err := os.WriteFile(path, []byte(strings.Join(all, "\n")+"\n"), 0o600); err != nil {
		f.t.Fatal(err)
	}
	return path
}

func (f *externalActivityTrackerFixture) appendLine(path, line string) {
	f.t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		f.t.Fatal(err)
	}
	if _, err := file.WriteString(line + "\n"); err != nil {
		file.Close()
		f.t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		f.t.Fatal(err)
	}
}

func (f *externalActivityTrackerFixture) snapshot(t *testing.T) []ExternalActivity {
	t.Helper()
	activities, err := f.tracker.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	return activities
}

func externalEventLine(eventType, turnID string) string {
	return externalEventLineAt(
		time.Date(2026, 7, 28, 14, 0, 1, 0, time.UTC),
		eventType,
		turnID,
	)
}

func externalEventLineAt(timestamp time.Time, eventType, turnID string) string {
	return `{"timestamp":` + strconvQuote(timestamp.UTC().Format(time.RFC3339Nano)) +
		`,"type":"event_msg","payload":{"type":` +
		strconvQuote(eventType) + `,"turn_id":` + strconvQuote(turnID) + `}}`
}

func externalUserMessageLine(timestamp time.Time, clientID string) string {
	payload := map[string]any{"type": "user_message"}
	if strings.TrimSpace(clientID) != "" {
		payload["client_id"] = clientID
	}
	record := map[string]any{
		"timestamp": timestamp.UTC().Format(time.RFC3339Nano),
		"type":      "event_msg",
		"payload":   payload,
	}
	data, _ := json.Marshal(record)
	return string(data)
}

func mustJSONQuote(t *testing.T, value string) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func strconvQuote(value string) string {
	data, _ := json.Marshal(value)
	return string(data)
}
