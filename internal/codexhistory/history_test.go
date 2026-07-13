package codexhistory

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestMessagesFromReaderHandlesHugeJSONLLine(t *testing.T) {
	var builder strings.Builder
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":"`)
	builder.WriteString(strings.Repeat("x", 9*1024*1024))
	builder.WriteString(`"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"hello from history"}}` + "\n")

	// 大型 Codex rollout 常见于工具输出或图片上下文；解析器应跳过这些非消息行，而不是让整段历史为空。
	messages, err := messagesFromReader(strings.NewReader(builder.String()), 0)
	if err != nil {
		t.Fatalf("大行 JSONL 不应导致历史读取失败：%v", err)
	}
	if len(messages) != 2 {
		t.Fatalf("期望解析出 2 条消息，实际 %d：%+v", len(messages), messages)
	}
	if messages[0].Role != "user" || messages[0].Content != "hi" {
		t.Fatalf("第一条消息异常：%+v", messages[0])
	}
	if messages[1].Role != "assistant" || messages[1].Content != "hello from history" {
		t.Fatalf("第二条消息异常：%+v", messages[1])
	}
}

func TestParseMessageLineHandlesEscapedMessage(t *testing.T) {
	line := []byte(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":" hello \"quoted\"\n\u4f60\u597d "}}`)

	message, ok := parseMessageLine(line)
	if !ok {
		t.Fatal("带转义字符的消息应能被解析")
	}
	if message.Role != "assistant" {
		t.Fatalf("角色异常：%+v", message)
	}
	if message.Content != "hello \"quoted\"\n你好" {
		t.Fatalf("消息内容应完成 JSON 反转义和首尾裁剪：%q", message.Content)
	}
	if message.CreatedAt.IsZero() {
		t.Fatalf("消息时间不应为空：%+v", message)
	}
}

func TestMessagesFromReaderReturnsLatestLimitedMessages(t *testing.T) {
	input := strings.Join([]string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}`,
		`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"three"}}`,
		"",
	}, "\n")

	messages, err := messagesFromReader(strings.NewReader(input), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("期望只保留最近 2 条消息，实际 %d：%+v", len(messages), messages)
	}
	if messages[0].Content != "two" || messages[1].Content != "three" {
		t.Fatalf("limit 应返回最新消息窗口：%+v", messages)
	}
}

func TestMessagesFromTailSkipsHugeTrailingRecords(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "rollout-*.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	var builder strings.Builder
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":"`)
	builder.WriteString(strings.Repeat("x", tailReadChunkSize+1024))
	builder.WriteString(`"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"three"}}`)
	if _, err := file.WriteString(builder.String()); err != nil {
		t.Fatal(err)
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}

	// limit 模式从文件尾部倒读，遇到跨 chunk 的大行也应跳过并继续向前找最近消息。
	messages, err := messagesFromTail(file, info.Size(), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("期望倒读出最近 2 条消息，实际 %d：%+v", len(messages), messages)
	}
	if messages[0].Content != "two" || messages[1].Content != "three" {
		t.Fatalf("倒读 limit 应返回最新消息窗口：%+v", messages)
	}
}

func TestMessagesFromTailDropsOversizedUnterminatedTrailingRecord(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "rollout-unterminated-*.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	var builder strings.Builder
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}` + "\n")
	builder.WriteString(`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":"`)
	builder.WriteString(strings.Repeat("x", maxTailPendingLineBytes+tailReadChunkSize+1024))
	if _, err := file.WriteString(builder.String()); err != nil {
		t.Fatal(err)
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}

	// 倒读遇到没有换行结尾的超大非消息行时，应丢弃这条行的半行缓存，
	// 继续向前找到真实历史消息，避免为了无用行拼出巨大的临时 buffer。
	messages, err := messagesFromTail(file, info.Size(), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("期望倒读出前面的 2 条消息，实际 %d：%+v", len(messages), messages)
	}
	if messages[0].Content != "one" || messages[1].Content != "two" {
		t.Fatalf("超大尾部半行不应遮挡更早消息：%+v", messages)
	}
}

func TestStoreTailPendingLineBoundsOversizedHalfLine(t *testing.T) {
	if pending := storeTailPendingLine(nil, []byte(strings.Repeat("x", maxTailPendingLineBytes+1))); pending != nil {
		t.Fatalf("超过上限的半行应直接丢弃，实际 len=%d cap=%d", len(pending), cap(pending))
	}

	halfLine := []byte("partial")
	pending := storeTailPendingLine(nil, halfLine)
	halfLine[0] = 'X'
	if string(pending) != "partial" {
		t.Fatalf("保留的半行应复制到独立缓存，实际 %q", string(pending))
	}
}

func TestMessagesPageFromTailUsesCursorForOlderWindow(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "rollout-page-*.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	lines := []string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}`,
		`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"three"}}`,
		`{"timestamp":"2026-06-01T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"four"}}`,
	}
	if _, err := file.WriteString(strings.Join(lines, "\n")); err != nil {
		t.Fatal(err)
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}

	first, err := messagesPageFromTail(file, info.Size(), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Messages) != 2 || first.Messages[0].Content != "three" || first.Messages[1].Content != "four" {
		t.Fatalf("第一页应返回最新 2 条消息：%+v", first)
	}
	if !first.HasMoreBefore || first.PreviousCursor == "" {
		t.Fatalf("第一页应带更早消息 cursor：%+v", first)
	}
	if first.Messages[0].ID == "" || first.Messages[0].ID == first.Messages[1].ID {
		t.Fatalf("消息页应带稳定 id：%+v", first.Messages)
	}

	offset, ok := decodeMessageCursor(first.PreviousCursor)
	if !ok {
		t.Fatalf("previous_cursor 应可解码：%q", first.PreviousCursor)
	}
	second, err := messagesPageFromTail(file, offset, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Messages) != 2 || second.Messages[0].Content != "one" || second.Messages[1].Content != "two" {
		t.Fatalf("第二页应返回 cursor 之前的 2 条消息：%+v", second)
	}
	if second.HasMoreBefore || second.PreviousCursor != "" {
		t.Fatalf("第二页已到开头，不应继续标记更多：%+v", second)
	}
}

func TestIndexedMessagePageMatchesTailPagination(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "rollout-index-*.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	lines := []string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}`,
		`{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":"noise"}}`,
		`{"timestamp":"2026-06-01T10:00:03Z","type":"event_msg","payload":{"type":"user_message","message":"three"}}`,
		`{"timestamp":"2026-06-01T10:00:04Z","type":"event_msg","payload":{"type":"agent_message","message":"four"}}`,
		`{"timestamp":"2026-06-01T10:00:05Z","type":"event_msg","payload":{"type":"user_message","message":"five"}}`,
	}
	if _, err := file.WriteString(strings.Join(lines, "\n")); err != nil {
		t.Fatal(err)
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}

	indexed, err := indexedMessagesFromFile(file)
	if err != nil {
		t.Fatal(err)
	}
	firstTail, err := messagesPageFromTail(file, info.Size(), 2)
	if err != nil {
		t.Fatal(err)
	}
	firstIndexed := pageFromIndexedMessages(indexed, info.Size(), 2)
	assertMessagePageEqual(t, firstIndexed, firstTail)

	offset, ok := decodeMessageCursor(firstTail.PreviousCursor)
	if !ok {
		t.Fatalf("previous_cursor 应可解码：%q", firstTail.PreviousCursor)
	}
	secondTail, err := messagesPageFromTail(file, offset, 2)
	if err != nil {
		t.Fatal(err)
	}
	secondIndexed := pageFromIndexedMessages(indexed, offset, 2)
	assertMessagePageEqual(t, secondIndexed, secondTail)
}

func BenchmarkMessagesPageFromTailLargeRollout(b *testing.B) {
	file, err := os.CreateTemp(b.TempDir(), "rollout-large-*.jsonl")
	if err != nil {
		b.Fatal(err)
	}
	defer file.Close()

	for i := 0; i < 6000; i++ {
		if i%500 == 0 {
			_, _ = file.WriteString(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":"`)
			_, _ = file.WriteString(strings.Repeat("x", 256*1024))
			_, _ = file.WriteString(`"}}` + "\n")
		}
		role := "user_message"
		if i%2 == 1 {
			role = "agent_message"
		}
		_, _ = file.WriteString(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"` + role + `","message":"message ` + strconv.Itoa(i) + `"}}` + "\n")
	}
	info, err := file.Stat()
	if err != nil {
		b.Fatal(err)
	}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		page, err := messagesPageFromTail(file, info.Size(), 120)
		if err != nil {
			b.Fatal(err)
		}
		if len(page.Messages) != 120 {
			b.Fatalf("期望返回 120 条消息，实际 %d", len(page.Messages))
		}
	}
}

func assertMessagePageEqual(t *testing.T, got MessagePage, want MessagePage) {
	t.Helper()
	if got.PreviousCursor != want.PreviousCursor || got.HasMoreBefore != want.HasMoreBefore {
		t.Fatalf("分页元数据不一致：got=%+v want=%+v", got, want)
	}
	if len(got.Messages) != len(want.Messages) {
		t.Fatalf("消息数量不一致：got=%+v want=%+v", got.Messages, want.Messages)
	}
	for index := range got.Messages {
		if got.Messages[index].ID != want.Messages[index].ID ||
			got.Messages[index].Role != want.Messages[index].Role ||
			got.Messages[index].Content != want.Messages[index].Content ||
			!got.Messages[index].CreatedAt.Equal(want.Messages[index].CreatedAt) {
			t.Fatalf("第 %d 条消息不一致：got=%+v want=%+v", index, got.Messages[index], want.Messages[index])
		}
	}
}

func TestRowsToSessionsFiltersSubagentThreads(t *testing.T) {
	dir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}})
	if err != nil {
		t.Fatal(err)
	}

	rows := []row{
		{ID: "main", Title: "主会话", CWD: dir, Source: "vscode", ThreadSource: "user"},
		{ID: "child_thread_source", Title: "子会话", CWD: dir, Source: "vscode", ThreadSource: "subagent"},
		{ID: "child_json_source", Title: "旧格式子会话", CWD: dir, Source: `{"subagent":{"thread_spawn":{"parent_thread_id":"main"}}}`},
	}

	// 子 Agent 仍会写入 Codex threads 表；iPad 侧栏应只展示和 Codex 主界面一致的顶层会话。
	childThreadIDs := map[string]bool{"child_edge": true}
	rows = append(rows, row{ID: "child_edge", Title: "edge 子会话", CWD: dir, Source: "vscode"})
	sessions, diagnostics := rowsToSessions(rows, registry, nil, "demo", childThreadIDs)
	if len(sessions) != 1 {
		t.Fatalf("期望只保留 1 条顶层会话，实际 %d：%+v", len(sessions), sessions)
	}
	if sessions[0].ID != "codex_main" {
		t.Fatalf("顶层会话 ID 异常：%q", sessions[0].ID)
	}

	reasons := map[string]string{}
	for _, item := range diagnostics {
		reasons[item.ThreadID] = item.Reason
	}
	if reasons["child_thread_source"] != "subagent" || reasons["child_json_source"] != "subagent" || reasons["child_edge"] != "subagent" {
		t.Fatalf("子会话诊断原因异常：%+v", reasons)
	}
}

func TestRowsToSessionsFiltersNonInteractiveSources(t *testing.T) {
	dir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}})
	if err != nil {
		t.Fatal(err)
	}

	rows := []row{
		{ID: "cli", Title: "CLI 会话", CWD: dir, Source: "cli"},
		{ID: "vscode", Title: "VS Code 会话", CWD: dir, Source: "vscode"},
		{ID: "atlas", Title: "Atlas 会话", CWD: dir, Source: `{"custom":"atlas"}`},
		{ID: "exec", Title: "Exec 后台任务", CWD: dir, Source: "exec"},
	}
	sessions, diagnostics := rowsToSessions(rows, registry, nil, "demo", nil)
	if len(sessions) != 3 {
		t.Fatalf("期望只保留交互来源会话，实际 %d：%+v", len(sessions), sessions)
	}

	reasons := map[string]string{}
	for _, item := range diagnostics {
		reasons[item.ThreadID] = item.Reason
	}
	if reasons["exec"] != "unsupported_source" {
		t.Fatalf("exec 来源应被排除，诊断原因异常：%+v", reasons)
	}
}

func TestCachedProjectForCWDReusesPositiveAndNegativeMatches(t *testing.T) {
	dir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}})
	if err != nil {
		t.Fatal(err)
	}
	cache := map[string]projectPathMatch{}

	project, ok := cachedProjectForCWD(registry, dir, cache)
	if !ok || project.ID != "demo" {
		t.Fatalf("首次匹配项目异常：project=%+v ok=%v", project, ok)
	}
	if len(cache) != 1 {
		t.Fatalf("首次匹配后应缓存 cwd，实际 cache=%+v", cache)
	}

	cache[dir] = projectPathMatch{project: projects.Project{ID: "cached"}, ok: true}
	project, ok = cachedProjectForCWD(registry, dir, cache)
	if !ok || project.ID != "cached" {
		t.Fatalf("第二次应直接复用缓存命中值：project=%+v ok=%v", project, ok)
	}

	missing := filepath.Join(t.TempDir(), "missing")
	_, ok = cachedProjectForCWD(registry, missing, cache)
	if ok {
		t.Fatal("未归属任何项目的 cwd 应返回 false")
	}
	cache[missing] = projectPathMatch{ok: false}
	_, ok = cachedProjectForCWD(registry, missing, cache)
	if ok {
		t.Fatal("负匹配也应从缓存复用")
	}
}

func TestRowsToSessionsFiltersMissingRolloutWhenColumnKnown(t *testing.T) {
	dir := t.TempDir()
	rolloutPath := filepath.Join(t.TempDir(), "rollout.jsonl")
	if err := os.WriteFile(rolloutPath, []byte(`{"type":"event_msg"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}})
	if err != nil {
		t.Fatal(err)
	}

	rows := []row{
		{ID: "valid", Title: "有文件", CWD: dir, Source: "cli", RolloutPath: rolloutPath, HasRolloutPath: 1},
		{ID: "missing", Title: "文件缺失", CWD: dir, Source: "cli", RolloutPath: filepath.Join(t.TempDir(), "missing.jsonl"), HasRolloutPath: 1},
		{ID: "empty", Title: "空路径", CWD: dir, Source: "cli", HasRolloutPath: 1},
		{ID: "legacy", Title: "旧 schema", CWD: dir, Source: "cli"},
	}

	sessions, diagnostics := rowsToSessions(rows, registry, nil, "demo", nil)
	if len(sessions) != 2 {
		t.Fatalf("期望只保留存在 rollout 和旧 schema 兼容会话，实际 %d：%+v", len(sessions), sessions)
	}
	if sessions[0].ID != "codex_valid" || sessions[1].ID != "codex_legacy" {
		t.Fatalf("保留会话异常：%+v", sessions)
	}

	reasons := map[string]string{}
	for _, item := range diagnostics {
		reasons[item.ThreadID] = item.Reason
	}
	if reasons["missing"] != "missing_rollout" || reasons["empty"] != "missing_rollout" {
		t.Fatalf("缺失 rollout 的诊断原因异常：%+v", reasons)
	}
}

func TestRolloutPathExistenceCacheAvoidsRepeatedStatAndExpires(t *testing.T) {
	rolloutPathCache.Lock()
	rolloutPathCache.items = map[string]rolloutPathCacheEntry{}
	rolloutPathCache.access.reset()
	rolloutPathCache.Unlock()

	oldStatFileFunc := statFileFunc
	defer func() { statFileFunc = oldStatFileFunc }()

	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	statCalls := 0
	statFileFunc = func(name string) (os.FileInfo, error) {
		statCalls++
		return nil, os.ErrNotExist
	}

	if cachedRolloutPathExists(path) {
		t.Fatal("第一次 stat 缺失应返回 false")
	}
	if cachedRolloutPathExists(path) {
		t.Fatal("缓存的缺失结果应继续返回 false")
	}
	if statCalls != 1 {
		t.Fatalf("短时间重复检查应只 stat 一次，实际 %d", statCalls)
	}

	rolloutPathCache.Lock()
	entry := rolloutPathCache.items[path]
	entry.checkedAt = time.Now().Add(-rolloutPathCacheTTL - time.Millisecond)
	rolloutPathCache.items[path] = entry
	rolloutPathCache.Unlock()

	statFileFunc = func(name string) (os.FileInfo, error) {
		statCalls++
		return nil, nil
	}
	if !cachedRolloutPathExists(path) {
		t.Fatal("缓存过期后应重新 stat 并看到文件存在")
	}
	if statCalls != 2 {
		t.Fatalf("缓存过期后应只额外 stat 一次，实际 %d", statCalls)
	}
}

func TestRolloutPathCachesDBLookupAndInvalidatesOnSignatureChange(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 not available")
	}
	rolloutPathCache.Lock()
	rolloutPathCache.items = map[string]rolloutPathCacheEntry{}
	rolloutPathCache.access.reset()
	rolloutPathCache.Unlock()
	rolloutDBPathCache.Lock()
	rolloutDBPathCache.items = map[string]rolloutDBPathCacheEntry{}
	rolloutDBPathCache.access.reset()
	rolloutDBPathCache.Unlock()

	home := t.TempDir()
	codexDir := filepath.Join(home, ".codex")
	if err := os.MkdirAll(codexDir, 0o755); err != nil {
		t.Fatal(err)
	}
	oldHomeDirFunc := homeDirFunc
	homeDirFunc = func() (string, error) { return home, nil }
	defer func() { homeDirFunc = oldHomeDirFunc }()

	rolloutFile := filepath.Join(t.TempDir(), "rollout.jsonl")
	if err := os.WriteFile(rolloutFile, []byte(`{"type":"event_msg"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	db := filepath.Join(codexDir, "state_5.sqlite")
	sql := `
create table threads (
	id text primary key,
	rollout_path text
);
insert into threads values ('thread-1', ` + sqlQuote(rolloutFile) + `);
`
	if out, err := exec.Command("sqlite3", db, sql).CombinedOutput(); err != nil {
		t.Fatalf("初始化测试 sqlite 失败：%v\n%s", err, out)
	}

	oldSQLiteQueryFunc := sqliteQueryFunc
	queryCalls := 0
	sqliteQueryFunc = func(db string, query string) ([]byte, error) {
		queryCalls++
		return oldSQLiteQueryFunc(db, query)
	}
	defer func() { sqliteQueryFunc = oldSQLiteQueryFunc }()

	path, err := rolloutPath("thread-1")
	if err != nil {
		t.Fatal(err)
	}
	if path != rolloutFile {
		t.Fatalf("rollout 路径异常：%q", path)
	}
	if queryCalls != 1 {
		t.Fatalf("第一次读取应查询 DB 一次，实际 %d", queryCalls)
	}

	path, err = rolloutPath("thread-1")
	if err != nil {
		t.Fatal(err)
	}
	if path != rolloutFile {
		t.Fatalf("缓存路径异常：%q", path)
	}
	if queryCalls != 1 {
		t.Fatalf("相同 DB 签名应命中路径缓存，实际查询 %d 次", queryCalls)
	}

	if out, err := exec.Command("sqlite3", db, "insert into threads values ('thread-2', "+sqlQuote(filepath.Join(t.TempDir(), "other.jsonl"))+");").CombinedOutput(); err != nil {
		t.Fatalf("更新测试 sqlite 失败：%v\n%s", err, out)
	}
	now := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(db, now, now); err != nil {
		t.Fatal(err)
	}

	path, err = rolloutPath("thread-1")
	if err != nil {
		t.Fatal(err)
	}
	if path != rolloutFile {
		t.Fatalf("DB 变更后的路径异常：%q", path)
	}
	if queryCalls != 2 {
		t.Fatalf("DB 签名变化后应重新查询，实际查询 %d 次", queryCalls)
	}
}

func TestThreadStoreListsThreadsAndReadsMessagesPage(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 not available")
	}
	historyCache.Lock()
	historyCache.items = map[string]historyCacheEntry{}
	historyCache.access.reset()
	historyCache.Unlock()
	schemaCache.Lock()
	schemaCache.items = map[string]schemaCacheEntry{}
	schemaCache.Unlock()
	rolloutDBPathCache.Lock()
	rolloutDBPathCache.items = map[string]rolloutDBPathCacheEntry{}
	rolloutDBPathCache.access.reset()
	rolloutDBPathCache.Unlock()

	rolloutFile := filepath.Join(t.TempDir(), "rollout.jsonl")
	if err := os.WriteFile(rolloutFile, []byte(strings.Join([]string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}`,
		"",
	}, "\n")), 0o644); err != nil {
		t.Fatal(err)
	}
	db := filepath.Join(t.TempDir(), "state.sqlite")
	sql := `
create table threads (
	id text primary key,
	title text,
	cwd text,
	source text,
	thread_source text,
	preview text,
	rollout_path text,
	archived integer,
	created_at_ms integer,
	updated_at_ms integer
);
insert into threads values ('thread-1', 'Thread One', '/tmp/demo', 'cli', '', 'Thread One', ` + sqlQuote(rolloutFile) + `, 0, 1, 20);
`
	if out, err := exec.Command("sqlite3", db, sql).CombinedOutput(); err != nil {
		t.Fatalf("初始化测试 sqlite 失败：%v\n%s", err, out)
	}

	store := NewThreadStore(db)
	rows, childIDs, err := store.ListThreads(nil, 10, false, PageCursor{})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != "thread-1" || rows[0].RolloutPath != rolloutFile {
		t.Fatalf("ThreadStore 列表结果异常：%+v", rows)
	}
	if len(childIDs) != 0 {
		t.Fatalf("普通列表不应返回 child id 映射：%+v", childIDs)
	}

	page, err := store.ReadMessagesPage("thread-1", "", 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Messages) != 1 || page.Messages[0].Content != "two" {
		t.Fatalf("ThreadStore 消息页应返回最新一条：%+v", page)
	}
	if !page.HasMoreBefore || page.PreviousCursor == "" {
		t.Fatalf("ThreadStore 消息页应暴露更早 cursor：%+v", page)
	}
}

func TestCacheAccessTrackerKeepsTouchedKeyHot(t *testing.T) {
	items := map[string]int{
		"old":     1,
		"touched": 2,
	}
	access := newCacheAccessTracker()
	access.touch("old")
	access.touch("touched")
	access.touch("touched")

	items["new"] = 3
	access.touch("new")
	trimCacheLRU(items, &access, 2)

	if _, ok := items["touched"]; !ok {
		t.Fatal("刚 touch 的缓存 key 不应被 LRU 淘汰")
	}
	if _, ok := items["new"]; !ok {
		t.Fatal("新写入的缓存 key 应保留")
	}
	if _, ok := items["old"]; ok {
		t.Fatal("最久未访问的缓存 key 应被淘汰")
	}
	if _, ok := access.ticks["old"]; ok {
		t.Fatal("淘汰缓存时应同步清理 tracker，避免陈旧 key 堆积")
	}
}

func TestHistorySnapshotCacheReturnsClonesAndInvalidatesOnSignatureChange(t *testing.T) {
	historyCache.Lock()
	historyCache.items = map[string]historyCacheEntry{}
	historyCache.access.reset()
	historyCache.Unlock()

	signature := dbSignature{size: 10, modTime: time.Unix(1, 0), walSize: 20, walModTime: time.Unix(2, 0)}
	storeHistorySnapshot(
		"demo",
		signature,
		[]row{{ID: "main", Title: "主会话"}},
		map[string]bool{"child": true},
		HistoryScanStats{RequestedLimit: 20, RowScanLimit: 20, RowsReturned: 1},
	)

	rows, childIDs, stats, ok := cachedHistorySnapshot("demo", signature)
	if !ok {
		t.Fatal("刚写入的快照应命中缓存")
	}
	if stats.RowsReturned != 1 || stats.RowScanLimit != 20 {
		t.Fatalf("缓存应保留扫描统计：%+v", stats)
	}
	rows[0].ID = "mutated"
	childIDs["new_child"] = true

	// 缓存内部必须和调用方隔离，否则一次列表渲染的局部修改会污染后续刷新。
	rows, childIDs, _, ok = cachedHistorySnapshot("demo", signature)
	if !ok {
		t.Fatal("相同 DB 签名应继续命中缓存")
	}
	if rows[0].ID != "main" {
		t.Fatalf("缓存 rows 不应被调用方修改污染：%+v", rows)
	}
	if childIDs["new_child"] {
		t.Fatalf("缓存 childThreadIDs 不应被调用方修改污染：%+v", childIDs)
	}

	changedSignature := dbSignature{size: 10, modTime: time.Unix(1, 0), walSize: 21, walModTime: time.Unix(3, 0)}
	if _, _, _, ok := cachedHistorySnapshot("demo", changedSignature); ok {
		t.Fatal("WAL 签名变化后不应命中旧缓存")
	}
}

func TestHistorySnapshotCacheEvictsLeastRecentlyUsedEntry(t *testing.T) {
	historyCache.Lock()
	historyCache.items = map[string]historyCacheEntry{}
	historyCache.access.reset()
	historyCache.Unlock()

	signature := dbSignature{size: 10, modTime: time.Unix(1, 0)}
	for index := 0; index < maxHistoryCaches; index++ {
		key := "history-" + strconv.Itoa(index)
		storeHistorySnapshot(
			key,
			signature,
			[]row{{ID: key}},
			nil,
			HistoryScanStats{RowsReturned: 1},
		)
	}
	if _, _, _, ok := cachedHistorySnapshot("history-0", signature); !ok {
		t.Fatal("刚访问过的历史快照应命中")
	}
	storeHistorySnapshot(
		"history-new",
		signature,
		[]row{{ID: "history-new"}},
		nil,
		HistoryScanStats{RowsReturned: 1},
	)

	if _, _, _, ok := cachedHistorySnapshot("history-0", signature); !ok {
		t.Fatal("LRU 淘汰不应清掉刚命中的历史快照")
	}
	if _, _, _, ok := cachedHistorySnapshot("history-1", signature); ok {
		t.Fatal("最久未访问的历史快照应被淘汰")
	}
	historyCache.Lock()
	cacheSize := len(historyCache.items)
	historyCache.Unlock()
	if cacheSize != maxHistoryCaches {
		t.Fatalf("历史快照缓存应保持容量上限，实际 %d", cacheSize)
	}
}

func TestMessagePageCacheReturnsClonesAndInvalidatesOnFileChange(t *testing.T) {
	messagePageCache.Lock()
	messagePageCache.items = map[string]messagePageCacheEntry{}
	messagePageCache.access.reset()
	messagePageCache.Unlock()

	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	if err := os.WriteFile(path, []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	page := MessagePage{
		Messages:       []Message{{ID: "rollout:0", Role: "user", Content: "one", CreatedAt: time.Unix(1, 0)}},
		PreviousCursor: "cursor",
		HasMoreBefore:  true,
	}
	storeCachedMessagePage(path, info, info.Size(), 120, page)

	cached, ok := cachedMessagePage(path, info, info.Size(), 120)
	if !ok {
		t.Fatal("刚写入的消息页缓存应命中")
	}
	cached.Messages[0].Content = "mutated"

	cached, ok = cachedMessagePage(path, info, info.Size(), 120)
	if !ok {
		t.Fatal("相同文件签名应继续命中")
	}
	if cached.Messages[0].Content != "one" {
		t.Fatalf("消息页缓存不应被调用方修改污染：%+v", cached.Messages)
	}

	if err := os.WriteFile(path, []byte("one\ntwo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	changedInfo, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cachedMessagePage(path, changedInfo, changedInfo.Size(), 120); ok {
		t.Fatal("rollout 文件变化后不应命中旧消息页缓存")
	}
}

func TestMessagePageCacheReusesStablePrefixAfterAppend(t *testing.T) {
	messagePageCache.Lock()
	messagePageCache.items = map[string]messagePageCacheEntry{}
	messagePageCache.access.reset()
	messagePageCache.Unlock()

	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	if err := os.WriteFile(path, []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	page := MessagePage{
		Messages: []Message{{ID: "rollout:0", Role: "user", Content: "one", CreatedAt: time.Unix(1, 0)}},
	}
	oldTailOffset := info.Size()
	storeCachedMessagePage(path, info, oldTailOffset, 120, page)

	if err := os.WriteFile(path, []byte("one\ntwo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	changedInfo, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	cached, ok := cachedMessagePage(path, changedInfo, oldTailOffset, 120)
	if !ok {
		t.Fatal("append-only rollout 的旧 before offset 页应继续命中缓存")
	}
	if len(cached.Messages) != 1 || cached.Messages[0].Content != "one" {
		t.Fatalf("旧前缀页内容异常：%+v", cached.Messages)
	}
	if _, ok := cachedMessagePage(path, changedInfo, changedInfo.Size(), 120); ok {
		t.Fatal("最新尾页必须按新文件 size 重新读取，不能复用旧窗口")
	}
}

func TestMessagePageCacheEvictsLeastRecentlyUsedEntry(t *testing.T) {
	messagePageCache.Lock()
	messagePageCache.items = map[string]messagePageCacheEntry{}
	messagePageCache.access.reset()
	messagePageCache.Unlock()

	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	if err := os.WriteFile(path, []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	for index := 0; index < maxMessagePageCaches; index++ {
		storeCachedMessagePage(path, info, int64(index), 120, MessagePage{
			Messages: []Message{{ID: "rollout:" + strconv.Itoa(index), Role: "user", Content: "msg " + strconv.Itoa(index)}},
		})
	}
	if _, ok := cachedMessagePage(path, info, 0, 120); !ok {
		t.Fatal("刚访问过的消息页应命中")
	}
	storeCachedMessagePage(path, info, int64(maxMessagePageCaches), 120, MessagePage{
		Messages: []Message{{ID: "rollout:new", Role: "assistant", Content: "new"}},
	})

	if _, ok := cachedMessagePage(path, info, 0, 120); !ok {
		t.Fatal("LRU 淘汰不应清掉刚命中的消息页")
	}
	if _, ok := cachedMessagePage(path, info, 1, 120); ok {
		t.Fatal("最久未访问的消息页应被淘汰")
	}
	messagePageCache.Lock()
	cacheSize := len(messagePageCache.items)
	messagePageCache.Unlock()
	if cacheSize != maxMessagePageCaches {
		t.Fatalf("消息页缓存应保持容量上限，实际 %d", cacheSize)
	}
}

func TestMessageIndexCacheReturnsClonesInvalidatesAndEvicts(t *testing.T) {
	messageIndexCache.Lock()
	messageIndexCache.items = map[string]messageIndexCacheEntry{}
	messageIndexCache.access.reset()
	messageIndexCache.Unlock()

	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	if err := os.WriteFile(path, []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	indexed := []parsedMessage{{
		message:   Message{ID: "rollout:0", Role: "user", Content: "one", CreatedAt: time.Unix(1, 0)},
		lineStart: 0,
	}}
	storeCachedMessageIndex(path, info, indexed)

	cached, ok := cachedMessageIndex(path, info)
	if !ok {
		t.Fatal("刚写入的消息索引应命中")
	}
	cached[0].message.Content = "mutated"
	cached, ok = cachedMessageIndex(path, info)
	if !ok {
		t.Fatal("相同文件签名应继续命中")
	}
	if cached[0].message.Content != "one" {
		t.Fatalf("消息索引缓存不应被调用方污染：%+v", cached)
	}

	if err := os.WriteFile(path, []byte("one\ntwo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	changedInfo, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cachedMessageIndex(path, changedInfo); ok {
		t.Fatal("rollout 文件变化后不应命中旧消息索引")
	}

	for index := 0; index < maxMessageIndexCaches; index++ {
		storeCachedMessageIndex("rollout-index-"+strconv.Itoa(index), info, indexed)
	}
	if _, ok := cachedMessageIndex("rollout-index-0", info); !ok {
		t.Fatal("刚访问过的消息索引应命中")
	}
	storeCachedMessageIndex("rollout-index-new", info, indexed)
	if _, ok := cachedMessageIndex("rollout-index-0", info); !ok {
		t.Fatal("LRU 淘汰不应清掉刚命中的消息索引")
	}
	if _, ok := cachedMessageIndex("rollout-index-1", info); ok {
		t.Fatal("最久未访问的消息索引应被淘汰")
	}
	messageIndexCache.Lock()
	cacheSize := len(messageIndexCache.items)
	messageIndexCache.Unlock()
	if cacheSize != maxMessageIndexCaches {
		t.Fatalf("消息索引缓存应保持容量上限，实际 %d", cacheSize)
	}
}

func TestMessageIndexCacheExtendsAppendOnlyPrefix(t *testing.T) {
	messageIndexCache.Lock()
	messageIndexCache.items = map[string]messageIndexCacheEntry{}
	messageIndexCache.access.reset()
	messageIndexCache.Unlock()

	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	initial := strings.Join([]string{
		`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}`,
		`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}`,
		"",
	}, "\n")
	if err := os.WriteFile(path, []byte(initial), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	indexed, err := indexedMessagesFromFile(file)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	storeCachedMessageIndex(path, info, indexed)

	appended := `{"timestamp":"2026-06-01T10:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"three"}}` + "\n"
	handle, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := handle.WriteString(appended); err != nil {
		_ = handle.Close()
		t.Fatal(err)
	}
	if err := handle.Close(); err != nil {
		t.Fatal(err)
	}
	changedInfo, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	file, err = os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	extended, ok, err := extendCachedMessageIndex(path, changedInfo, file)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("append-only rollout 应复用旧消息索引并只补新增尾段")
	}
	if len(extended) != 3 {
		t.Fatalf("期望扩展到 3 条消息，实际 %d：%+v", len(extended), extended)
	}
	if extended[2].lineStart != info.Size() || extended[2].message.Content != "three" {
		t.Fatalf("新增消息 offset/content 异常：%+v oldSize=%d", extended[2], info.Size())
	}
	if cached, ok := cachedMessageIndex(path, changedInfo); !ok || len(cached) != 3 {
		t.Fatalf("扩展后的索引应写回精确缓存，ok=%v cached=%+v", ok, cached)
	}
}

func TestMessageIndexCacheDoesNotExtendNonLineBoundaryPrefix(t *testing.T) {
	messageIndexCache.Lock()
	messageIndexCache.items = map[string]messageIndexCacheEntry{}
	messageIndexCache.access.reset()
	messageIndexCache.Unlock()

	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	first := `{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}`
	if err := os.WriteFile(path, []byte(first), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	indexed, err := indexedMessagesFromFile(file)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	storeCachedMessageIndex(path, info, indexed)

	handle, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := handle.WriteString(`{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}`); err != nil {
		_ = handle.Close()
		t.Fatal(err)
	}
	if err := handle.Close(); err != nil {
		t.Fatal(err)
	}
	changedInfo, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	file, err = os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	_, ok, err := extendCachedMessageIndex(path, changedInfo, file)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("旧索引不在行边界时不应增量扩展，避免把半行当作新 JSONL 行解析")
	}
}

func TestLoadHistorySnapshotOnlyLoadsChildIDsForDiagnostics(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 not available")
	}
	historyCache.Lock()
	historyCache.items = map[string]historyCacheEntry{}
	historyCache.access.reset()
	historyCache.Unlock()

	db := filepath.Join(t.TempDir(), "state.sqlite")
	sql := `
create table threads (
	id text primary key,
	title text,
	cwd text,
	source text,
	thread_source text,
	preview text,
	archived integer,
	created_at_ms integer,
	updated_at_ms integer
);
create table thread_spawn_edges (child_thread_id text);
insert into threads values ('main', '主会话', '/tmp/demo', 'cli', '', '主会话', 0, 1, 20);
insert into threads values ('child', '子会话', '/tmp/demo', 'cli', '', '子会话', 0, 2, 10);
insert into thread_spawn_edges values ('child');
`
	if out, err := exec.Command("sqlite3", db, sql).CombinedOutput(); err != nil {
		t.Fatalf("初始化测试 sqlite 失败：%v\n%s", err, out)
	}

	rows, childIDs, err := loadHistorySnapshot(db, nil, 20, false, PageCursor{})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != "main" {
		t.Fatalf("普通列表应只返回顶层会话：%+v", rows)
	}
	if len(childIDs) != 0 {
		t.Fatalf("普通列表不应额外加载 child id 映射：%+v", childIDs)
	}

	rows, childIDs, err = loadHistorySnapshot(db, nil, 20, true, PageCursor{})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("诊断模式应保留原始扫描结果用于解释过滤原因：%+v", rows)
	}
	if !childIDs["child"] {
		t.Fatalf("诊断模式应加载 child id 映射：%+v", childIDs)
	}
}

func TestLoadHistorySnapshotReportsScanStatsAndCacheHit(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 not available")
	}
	historyCache.Lock()
	historyCache.items = map[string]historyCacheEntry{}
	historyCache.access.reset()
	historyCache.Unlock()
	schemaCache.Lock()
	schemaCache.items = map[string]schemaCacheEntry{}
	schemaCache.Unlock()

	db := filepath.Join(t.TempDir(), "state.sqlite")
	sql := `
create table threads (
	id text primary key,
	title text,
	cwd text,
	source text,
	thread_source text,
	preview text,
	archived integer,
	created_at_ms integer,
	updated_at_ms integer
);
insert into threads values ('one', 'One', '/tmp/demo', 'cli', '', 'One', 0, 1, 30);
insert into threads values ('two', 'Two', '/tmp/demo', 'cli', '', 'Two', 0, 1, 20);
insert into threads values ('three', 'Three', '/tmp/demo', 'cli', '', 'Three', 0, 1, 10);
`
	if out, err := exec.Command("sqlite3", db, sql).CombinedOutput(); err != nil {
		t.Fatalf("初始化测试 sqlite 失败：%v\n%s", err, out)
	}

	rows, _, stats, err := loadHistorySnapshotWithStats(db, nil, 2, true, PageCursor{})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("limit=2 应只返回 2 条原始行：%+v", rows)
	}
	if stats.RequestedLimit != 2 || stats.RowScanLimit != 2 || stats.RowsReturned != 2 {
		t.Fatalf("扫描统计基础字段异常：%+v", stats)
	}
	if stats.CacheHit || !stats.ReachedScanLimit || stats.ReachedScanCap {
		t.Fatalf("首次查询应未命中缓存、达到 scan limit、未触顶 max cap：%+v", stats)
	}

	_, _, cachedStats, err := loadHistorySnapshotWithStats(db, nil, 2, true, PageCursor{})
	if err != nil {
		t.Fatal(err)
	}
	if !cachedStats.CacheHit || cachedStats.RowsReturned != 2 {
		t.Fatalf("第二次同参数应命中缓存并保留统计：%+v", cachedStats)
	}
}

func TestReadHistoryColumnsLoadsThreadAndEdgeColumnsInOneQuery(t *testing.T) {
	oldSQLiteQueryFunc := sqliteQueryFunc
	queryCalls := 0
	sqliteQueryFunc = func(db string, query string) ([]byte, error) {
		queryCalls++
		if !strings.Contains(query, "pragma_table_info('threads')") || !strings.Contains(query, "pragma_table_info('thread_spawn_edges')") {
			t.Fatalf("schema 查询应一次性读取 threads 和 thread_spawn_edges：%s", query)
		}
		return []byte(`[
			{"table_name":"threads","name":"source"},
			{"table_name":"threads","name":"rollout_path"},
			{"table_name":"thread_spawn_edges","name":"child_thread_id"}
		]`), nil
	}
	defer func() { sqliteQueryFunc = oldSQLiteQueryFunc }()

	columns, edgeColumns, err := readHistoryColumns("state.sqlite")
	if err != nil {
		t.Fatal(err)
	}
	if queryCalls != 1 {
		t.Fatalf("读取 schema 应只启动一次 sqlite 查询，实际 %d", queryCalls)
	}
	if !columns["source"] || !columns["rollout_path"] {
		t.Fatalf("threads 列解析异常：%+v", columns)
	}
	if !edgeColumns["child_thread_id"] {
		t.Fatalf("thread_spawn_edges 列解析异常：%+v", edgeColumns)
	}
}

func TestLoadPageOverfetchesPastMissingRollouts(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 not available")
	}
	historyCache.Lock()
	historyCache.items = map[string]historyCacheEntry{}
	historyCache.access.reset()
	historyCache.Unlock()
	schemaCache.Lock()
	schemaCache.items = map[string]schemaCacheEntry{}
	schemaCache.Unlock()

	home := t.TempDir()
	codexDir := filepath.Join(home, ".codex")
	if err := os.MkdirAll(codexDir, 0o755); err != nil {
		t.Fatal(err)
	}
	oldHomeDirFunc := homeDirFunc
	homeDirFunc = func() (string, error) { return home, nil }
	defer func() { homeDirFunc = oldHomeDirFunc }()

	projectDir := t.TempDir()
	rolloutPath := filepath.Join(t.TempDir(), "valid.jsonl")
	if err := os.WriteFile(rolloutPath, []byte(`{"timestamp":"2026-06-01T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: projectDir}})
	if err != nil {
		t.Fatal(err)
	}

	db := filepath.Join(codexDir, "state_5.sqlite")
	sql := `
create table threads (
	id text primary key,
	title text,
	cwd text,
	source text,
	thread_source text,
	preview text,
	rollout_path text,
	archived integer,
	created_at_ms integer,
	updated_at_ms integer
);
insert into threads values ('stale1', '旧缺失 1', '` + sqlLiteral(projectDir) + `', 'cli', '', '旧缺失 1', '` + sqlLiteral(filepath.Join(t.TempDir(), "missing-1.jsonl")) + `', 0, 1, 50);
insert into threads values ('stale2', '旧缺失 2', '` + sqlLiteral(projectDir) + `', 'cli', '', '旧缺失 2', '` + sqlLiteral(filepath.Join(t.TempDir(), "missing-2.jsonl")) + `', 0, 2, 40);
insert into threads values ('valid', '可用历史', '` + sqlLiteral(projectDir) + `', 'cli', '', '可用历史', '` + sqlLiteral(rolloutPath) + `', 0, 3, 30);
`
	if out, err := exec.Command("sqlite3", db, sql).CombinedOutput(); err != nil {
		t.Fatalf("初始化测试 sqlite 失败：%v\n%s", err, out)
	}

	sessions := LoadPage(registry, nil, "demo", 2, PageCursor{})
	if len(sessions) != 1 || sessions[0].ID != "codex_valid" {
		t.Fatalf("列表应越过缺失 rollout 的 stale rows 返回可用历史：%+v", sessions)
	}
}

func TestLoadHistorySnapshotUsesStableIDOrderForCursor(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 not available")
	}
	historyCache.Lock()
	historyCache.items = map[string]historyCacheEntry{}
	historyCache.access.reset()
	historyCache.Unlock()
	schemaCache.Lock()
	schemaCache.items = map[string]schemaCacheEntry{}
	schemaCache.Unlock()

	db := filepath.Join(t.TempDir(), "state.sqlite")
	sql := `
create table threads (
	id text primary key,
	title text,
	cwd text,
	source text,
	thread_source text,
	preview text,
	archived integer,
	created_at_ms integer,
	updated_at_ms integer
);
insert into threads values ('alpha', 'Alpha', '/tmp/demo', 'cli', '', 'Alpha', 0, 1, 1000);
insert into threads values ('beta', 'Beta', '/tmp/demo', 'cli', '', 'Beta', 0, 1, 1000);
insert into threads values ('gamma', 'Gamma', '/tmp/demo', 'cli', '', 'Gamma', 0, 1, 1000);
`
	if out, err := exec.Command("sqlite3", db, sql).CombinedOutput(); err != nil {
		t.Fatalf("初始化测试 sqlite 失败：%v\n%s", err, out)
	}

	first, _, err := loadHistorySnapshot(db, nil, 2, false, PageCursor{})
	if err != nil {
		t.Fatal(err)
	}
	if got := rowIDs(first); strings.Join(got, ",") != "gamma,beta" {
		t.Fatalf("同时间戳第一页应按 id desc 稳定排序，实际：%v", got)
	}

	second, _, err := loadHistorySnapshot(db, nil, 2, false, PageCursor{ID: "codex_beta", UpdatedAtMS: 1000})
	if err != nil {
		t.Fatal(err)
	}
	if got := rowIDs(second); strings.Join(got, ",") != "alpha" {
		t.Fatalf("cursor 后一页应继续返回 beta 之前的记录，实际：%v", got)
	}
}

func rowIDs(rows []row) []string {
	ids := make([]string, 0, len(rows))
	for _, item := range rows {
		ids = append(ids, item.ID)
	}
	return ids
}

func sqlLiteral(value string) string {
	return strings.ReplaceAll(value, "'", "''")
}
