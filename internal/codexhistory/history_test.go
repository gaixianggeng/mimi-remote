package codexhistory

import (
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestRowsToDiagnosticsFiltersSubagentThreads(t *testing.T) {
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
	diagnostics := rowsToDiagnostics(rows, registry, "demo", childThreadIDs)
	included := includedThreadIDs(diagnostics)
	if len(included) != 1 || included[0] != "main" {
		t.Fatalf("期望只保留 1 条顶层会话 main，实际 %v：%+v", included, diagnostics)
	}

	reasons := map[string]string{}
	for _, item := range diagnostics {
		reasons[item.ThreadID] = item.Reason
	}
	if reasons["child_thread_source"] != "subagent" || reasons["child_json_source"] != "subagent" || reasons["child_edge"] != "subagent" {
		t.Fatalf("子会话诊断原因异常：%+v", reasons)
	}
}

func TestRowsToDiagnosticsFiltersNonInteractiveSources(t *testing.T) {
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
	diagnostics := rowsToDiagnostics(rows, registry, "demo", nil)
	if included := includedThreadIDs(diagnostics); len(included) != 3 {
		t.Fatalf("期望只保留交互来源会话，实际 %v：%+v", included, diagnostics)
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

// includedThreadIDs 返回诊断中被判定为可收录的线程 ID。
// 生产侧只消费诊断行，因此测试也断言同一份输出。
func includedThreadIDs(diagnostics []DiagnosticRow) []string {
	var included []string
	for _, item := range diagnostics {
		if item.Included {
			included = append(included, item.ThreadID)
		}
	}
	return included
}
