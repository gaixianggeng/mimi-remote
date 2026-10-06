package codexhistory

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

type row struct {
	ID             string `json:"id"`
	Title          string `json:"title"`
	CWD            string `json:"cwd"`
	Source         string `json:"source"`
	ThreadSource   string `json:"thread_source"`
	Preview        string `json:"preview"`
	RolloutPath    string `json:"rollout_path"`
	HasRolloutPath int    `json:"has_rollout_path"`
	CreatedAtMS    int64  `json:"created_at_ms"`
	UpdatedAtMS    int64  `json:"updated_at_ms"`
}

type PageCursor struct {
	ID          string
	UpdatedAtMS int64
}

type Diagnostics struct {
	Home           string           `json:"home"`
	DatabasePath   string           `json:"database_path"`
	DatabaseExists bool             `json:"database_exists"`
	QueryMode      string           `json:"query_mode"`
	QueryLimit     int              `json:"query_limit"`
	Scan           HistoryScanStats `json:"scan"`
	Project        *ProjectDebug    `json:"project,omitempty"`
	Counts         map[string]int   `json:"counts"`
	Rows           []DiagnosticRow  `json:"rows"`
	Error          string           `json:"error,omitempty"`
}

type HistoryScanStats struct {
	RequestedLimit   int  `json:"requested_limit"`
	RowScanLimit     int  `json:"row_scan_limit"`
	RowsReturned     int  `json:"rows_returned"`
	IncludeSubagents bool `json:"include_subagents"`
	ProjectFiltered  bool `json:"project_filtered"`
	CacheHit         bool `json:"cache_hit"`
	ReachedScanLimit bool `json:"reached_scan_limit"`
	ReachedScanCap   bool `json:"reached_scan_cap"`
}

type ProjectDebug struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Path     string `json:"path"`
	RealPath string `json:"real_path"`
}

type DiagnosticRow struct {
	ThreadID         string    `json:"thread_id"`
	Title            string    `json:"title"`
	CWD              string    `json:"cwd"`
	MatchedProjectID string    `json:"matched_project_id,omitempty"`
	Included         bool      `json:"included"`
	Reason           string    `json:"reason"`
	UpdatedAt        time.Time `json:"updated_at"`
}

type projectPathMatch struct {
	project projects.Project
	ok      bool
}

var (
	homeDirFunc     = os.UserHomeDir
	statFileFunc    = os.Stat
	sqliteQueryFunc = querySQLiteJSON
)

const (
	defaultQueryLimit    = 300
	maxQueryLimit        = 2000
	maxHistoryCaches     = 16
	maxRolloutPathCaches = 512
	historyCacheTTL      = 1500 * time.Millisecond
	rolloutPathCacheTTL  = 1500 * time.Millisecond
)

type historyCacheEntry struct {
	signature      dbSignature
	loadedAt       time.Time
	rows           []row
	childThreadIDs map[string]bool
	stats          HistoryScanStats
}

type schemaCacheEntry struct {
	signature   dbSignature
	columns     map[string]bool
	edgeColumns map[string]bool
}

type dbSignature struct {
	size       int64
	modTime    time.Time
	walSize    int64
	walModTime time.Time
}

type rolloutPathCacheEntry struct {
	exists    bool
	checkedAt time.Time
}

var historyCache = struct {
	sync.Mutex
	items  map[string]historyCacheEntry
	access cacheAccessTracker
}{items: map[string]historyCacheEntry{}, access: newCacheAccessTracker()}

var schemaCache = struct {
	sync.Mutex
	items map[string]schemaCacheEntry
}{items: map[string]schemaCacheEntry{}}

var rolloutPathCache = struct {
	sync.Mutex
	items  map[string]rolloutPathCacheEntry
	access cacheAccessTracker
}{items: map[string]rolloutPathCacheEntry{}, access: newCacheAccessTracker()}

func Diagnose(registry *projects.Registry, projectID string, limit int) Diagnostics {
	limit = normalizeQueryLimit(limit)
	store := defaultThreadStore()
	db := store.databasePath()
	result := Diagnostics{
		Home:         homeDir(),
		DatabasePath: db,
		QueryMode:    "global",
		QueryLimit:   limit,
		Counts:       map[string]int{},
	}
	if _, err := os.Stat(db); err != nil {
		result.Error = err.Error()
		return result
	}
	result.DatabaseExists = true

	var projectFilter *projects.Project
	if projectID != "" {
		project, ok := registry.Get(projectID)
		if !ok {
			result.Error = "项目不存在"
			return result
		}
		projectFilter = &project
		result.QueryMode = "project_path"
		result.Project = &ProjectDebug{ID: project.ID, Name: project.Name, Path: project.Path, RealPath: project.RealPath}
	}

	rows, childThreadIDs, scan, err := store.ListThreadsWithStats(projectFilter, limit, true, PageCursor{})
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.Scan = scan
	result.Rows = rowsToDiagnostics(rows, registry, projectID, childThreadIDs)
	for _, item := range result.Rows {
		result.Counts["scanned"]++
		if item.Included {
			result.Counts["included"]++
		} else {
			result.Counts[item.Reason]++
		}
	}
	return result
}

// rowsToDiagnostics 把 storage 行映射成诊断行。
// 它此前还顺带构造了一份 []session.SessionSnapshot，但调用方一直用 _ 丢弃，
// 而唯一会读它的 seen 又来自永远为空的 active 列表，因此整段投影都是白算的。
func rowsToDiagnostics(rows []row, registry *projects.Registry, projectID string, childThreadIDs map[string]bool) []DiagnosticRow {
	var diagnostics []DiagnosticRow
	projectPathCache := make(map[string]projectPathMatch, minInt(len(rows), 128))
	for _, item := range rows {
		diagnostic := DiagnosticRow{
			ThreadID:  item.ID,
			Title:     item.Title,
			CWD:       item.CWD,
			Reason:    "included",
			UpdatedAt: msTime(item.UpdatedAtMS),
		}
		if item.ID == "" {
			// 空 ID 沿用既有诊断码，避免仅清理不可达逻辑时改变接口返回值。
			diagnostic.Reason = "active_session"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		if isSubagentThread(item, childThreadIDs) {
			diagnostic.Reason = "subagent"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		if !isInteractiveSource(item.Source) {
			diagnostic.Reason = "unsupported_source"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		project, ok := cachedProjectForCWD(registry, item.CWD, projectPathCache)
		if !ok {
			diagnostic.Reason = "no_matching_project"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		diagnostic.MatchedProjectID = project.ID
		if projectID != "" && project.ID != projectID {
			diagnostic.Reason = "other_project"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		if isMissingRollout(item) {
			diagnostic.Reason = "missing_rollout"
			diagnostics = append(diagnostics, diagnostic)
			continue
		}
		diagnostic.Included = true
		diagnostics = append(diagnostics, diagnostic)
	}
	return diagnostics
}

func cachedProjectForCWD(registry *projects.Registry, cwd string, cache map[string]projectPathMatch) (projects.Project, bool) {
	if cached, ok := cache[cwd]; ok {
		return cached.project, cached.ok
	}
	project, ok := registry.FindByPath(cwd)
	// 一个 Codex 项目里大量历史 row 往往共享同一个 cwd；单次转换内缓存匹配结果，
	// 可以避免重复 EvalSymlinks/Abs 路径解析，同时不引入跨请求失效问题。
	cache[cwd] = projectPathMatch{project: project, ok: ok}
	return project, ok
}

func isMissingRollout(item row) bool {
	if item.HasRolloutPath == 0 {
		return false
	}
	path := strings.TrimSpace(item.RolloutPath)
	if path == "" {
		return true
	}
	return !cachedRolloutPathExists(path)
}

func cachedRolloutPathExists(path string) bool {
	rolloutPathCache.Lock()
	entry, ok := rolloutPathCache.items[path]
	if ok && time.Since(entry.checkedAt) <= rolloutPathCacheTTL {
		rolloutPathCache.access.touch(path)
		rolloutPathCache.Unlock()
		return entry.exists
	}
	if ok {
		delete(rolloutPathCache.items, path)
		rolloutPathCache.access.forget(path)
	}
	rolloutPathCache.Unlock()

	exists := true
	if _, err := statFileFunc(path); err != nil {
		exists = !errors.Is(err, os.ErrNotExist)
	}
	storeRolloutPathExists(path, exists)
	return exists
}

func storeRolloutPathExists(path string, exists bool) {
	rolloutPathCache.Lock()
	defer rolloutPathCache.Unlock()

	rolloutPathCache.items[path] = rolloutPathCacheEntry{exists: exists, checkedAt: time.Now()}
	rolloutPathCache.access.touch(path)
	trimCacheLRU(rolloutPathCache.items, &rolloutPathCache.access, maxRolloutPathCaches)
}

func loadHistorySnapshotWithStats(db string, project *projects.Project, limit int, includeSubagents bool, cursor PageCursor) ([]row, map[string]bool, HistoryScanStats, error) {
	signature, err := readDBSignature(db)
	if err != nil {
		return nil, nil, HistoryScanStats{}, err
	}
	key := historyCacheKey(db, project, limit, includeSubagents, cursor)
	if rows, childIDs, stats, ok := cachedHistorySnapshot(key, signature); ok {
		stats.CacheHit = true
		return rows, childIDs, stats, nil
	}

	columns, edgeColumns, err := historyColumns(db, signature)
	if err != nil {
		return nil, nil, HistoryScanStats{}, err
	}
	scanLimit := historyRowScanLimit(limit, includeSubagents, columns)
	stats := HistoryScanStats{
		RequestedLimit:   limit,
		RowScanLimit:     scanLimit,
		IncludeSubagents: includeSubagents,
		ProjectFiltered:  project != nil,
	}
	rows, err := queryRows(db, project, scanLimit, includeSubagents, columns, edgeColumns, cursor)
	if err != nil {
		return nil, nil, HistoryScanStats{}, err
	}
	stats.RowsReturned = len(rows)
	stats.ReachedScanLimit = scanLimit > 0 && len(rows) >= scanLimit
	stats.ReachedScanCap = stats.ReachedScanLimit && scanLimit >= maxQueryLimit
	childIDs := map[string]bool{}
	if includeSubagents {
		// 普通列表已经在 SQL predicate 里排除了子 Agent；只有诊断模式需要完整 child id
		// 映射来解释每条记录为何被过滤，避免每次侧栏刷新都扫 thread_spawn_edges。
		childIDs, err = childThreadIDs(db, edgeColumns)
		if err != nil {
			return nil, nil, HistoryScanStats{}, err
		}
	}
	storeHistorySnapshot(key, signature, rows, childIDs, stats)
	return cloneRows(rows), cloneBoolMap(childIDs), stats, nil
}

func historyRowScanLimit(limit int, includeSubagents bool, columns map[string]bool) int {
	if includeSubagents || !columns["rollout_path"] || limit <= 0 {
		return limit
	}
	// rollout_path 文件可能已被 Codex 清理。普通列表会过滤这些 stale rows，
	// 因此查询时多读一小段，避免最近几条 stale 记录把当前页挤空。
	scanLimit := limit * 3
	if scanLimit > maxQueryLimit {
		return maxQueryLimit
	}
	return scanLimit
}

func historyColumns(db string, signature dbSignature) (map[string]bool, map[string]bool, error) {
	if columns, edgeColumns, ok := cachedHistoryColumns(db, signature); ok {
		return columns, edgeColumns, nil
	}
	columns, edgeColumns, err := readHistoryColumns(db)
	if err != nil {
		return nil, nil, err
	}
	storeHistoryColumns(db, signature, columns, edgeColumns)
	return columns, edgeColumns, nil
}

func readHistoryColumns(db string) (map[string]bool, map[string]bool, error) {
	query := "select 'threads' as table_name, name from pragma_table_info('threads') " +
		"union all select 'thread_spawn_edges' as table_name, name from pragma_table_info('thread_spawn_edges')"
	out, err := sqliteQueryFunc(db, query)
	if err != nil {
		return nil, nil, err
	}
	columns := map[string]bool{}
	edgeColumns := map[string]bool{}
	if len(bytes.TrimSpace(out)) == 0 {
		return columns, edgeColumns, nil
	}
	var rows []struct {
		TableName string `json:"table_name"`
		Name      string `json:"name"`
	}
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, nil, err
	}
	for _, item := range rows {
		switch item.TableName {
		case "threads":
			columns[item.Name] = true
		case "thread_spawn_edges":
			edgeColumns[item.Name] = true
		}
	}
	return columns, edgeColumns, nil
}

func cachedHistoryColumns(db string, signature dbSignature) (map[string]bool, map[string]bool, bool) {
	schemaCache.Lock()
	defer schemaCache.Unlock()

	entry, ok := schemaCache.items[db]
	if !ok || entry.signature != signature {
		return nil, nil, false
	}
	return cloneBoolMap(entry.columns), cloneBoolMap(entry.edgeColumns), true
}

func storeHistoryColumns(db string, signature dbSignature, columns map[string]bool, edgeColumns map[string]bool) {
	schemaCache.Lock()
	defer schemaCache.Unlock()

	// 翻页和短时间刷新会使用不同 cursor/limit，行缓存不一定命中；schema 元数据可以按
	// SQLite 文件签名复用，减少每页额外的 PRAGMA shell 调用。
	schemaCache.items[db] = schemaCacheEntry{
		signature:   signature,
		columns:     cloneBoolMap(columns),
		edgeColumns: cloneBoolMap(edgeColumns),
	}
}

func queryRows(db string, project *projects.Project, limit int, includeSubagents bool, columns map[string]bool, edgeColumns map[string]bool, cursor PageCursor) ([]row, error) {
	where := "archived=0"
	if !includeSubagents {
		where += " and " + topLevelHistoryPredicate(columns, edgeColumns)
	}
	if project != nil {
		where += " and (" + pathPredicate(project.Path)
		if project.RealPath != "" && project.RealPath != project.Path {
			where += " or " + pathPredicate(project.RealPath)
		}
		where += ")"
	}
	if cursor.UpdatedAtMS > 0 {
		// 与 HTTP 层的会话排序保持一致：updated_at 降序，ID 降序。
		// 使用 keyset cursor 可以避免每次展开历史列表都从 SQLite 读出固定大页再丢弃。
		where += " and (updated_at_ms < " + strconv.FormatInt(cursor.UpdatedAtMS, 10) +
			" or (updated_at_ms = " + strconv.FormatInt(cursor.UpdatedAtMS, 10) +
			" and ('codex_' || id) < " + sqlQuote(cursor.ID) + "))"
	}
	sourceExpr := optionalColumnExpr(columns, "source")
	threadSourceExpr := optionalColumnExpr(columns, "thread_source")
	previewExpr := optionalColumnExpr(columns, "preview")
	rolloutPathExpr := optionalColumnExpr(columns, "rollout_path")
	hasRolloutPathExpr := "0 as has_rollout_path"
	if columns["rollout_path"] {
		hasRolloutPathExpr = "1 as has_rollout_path"
	}
	sql := "select id,title,cwd," + sourceExpr + "," + threadSourceExpr + "," + previewExpr + "," +
		rolloutPathExpr + "," + hasRolloutPathExpr + ",created_at_ms,updated_at_ms from threads where " +
		// cursor 使用 updated_at_ms + id 做 keyset 分页；SQL 排序也必须保持同一个全序，
		// 否则同毫秒多条历史时，SQLite 的返回顺序会让下一页漏项或重复。
		where + " order by updated_at_ms desc, id desc limit " + strconv.Itoa(limit)
	out, err := sqliteQueryFunc(db, sql)
	if err != nil {
		return nil, err
	}
	var rows []row
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

func historyCacheKey(db string, project *projects.Project, limit int, includeSubagents bool, cursor PageCursor) string {
	var projectPart string
	if project != nil {
		projectPart = project.Path + "\x00" + project.RealPath
	}
	return db + "\x00" + projectPart + "\x00" + strconv.Itoa(limit) + "\x00" +
		strconv.FormatBool(includeSubagents) + "\x00" + cursor.ID + "\x00" +
		strconv.FormatInt(cursor.UpdatedAtMS, 10)
}

func readDBSignature(db string) (dbSignature, error) {
	info, err := os.Stat(db)
	if err != nil {
		return dbSignature{}, err
	}
	signature := dbSignature{size: info.Size(), modTime: info.ModTime()}
	if walInfo, err := os.Stat(db + "-wal"); err == nil {
		signature.walSize = walInfo.Size()
		signature.walModTime = walInfo.ModTime()
	} else if !errors.Is(err, os.ErrNotExist) {
		return dbSignature{}, err
	}
	return signature, nil
}

func cachedHistorySnapshot(key string, signature dbSignature) ([]row, map[string]bool, HistoryScanStats, bool) {
	historyCache.Lock()
	defer historyCache.Unlock()

	entry, ok := historyCache.items[key]
	if !ok || entry.signature != signature || time.Since(entry.loadedAt) > historyCacheTTL {
		if ok {
			delete(historyCache.items, key)
			historyCache.access.forget(key)
		}
		return nil, nil, HistoryScanStats{}, false
	}
	historyCache.access.touch(key)
	stats := entry.stats
	return cloneRows(entry.rows), cloneBoolMap(entry.childThreadIDs), stats, true
}

func storeHistorySnapshot(key string, signature dbSignature, rows []row, childThreadIDs map[string]bool, stats HistoryScanStats) {
	historyCache.Lock()
	defer historyCache.Unlock()

	// 会话列表刷新常常是 iOS 多个视图连续触发；缓存一个短快照，避免重复查询 SQLite。
	historyCache.items[key] = historyCacheEntry{
		signature:      signature,
		loadedAt:       time.Now(),
		rows:           cloneRows(rows),
		childThreadIDs: cloneBoolMap(childThreadIDs),
		stats:          stats,
	}
	historyCache.access.touch(key)
	trimCacheLRU(historyCache.items, &historyCache.access, maxHistoryCaches)
}

func childThreadIDs(db string, columns map[string]bool) (map[string]bool, error) {
	ids := map[string]bool{}
	if !columns["child_thread_id"] {
		return ids, nil
	}
	out, err := sqliteQueryFunc(db, "select child_thread_id from thread_spawn_edges")
	if err != nil {
		return nil, err
	}
	var rows []struct {
		ChildThreadID string `json:"child_thread_id"`
	}
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, err
	}
	for _, item := range rows {
		if item.ChildThreadID != "" {
			ids[item.ChildThreadID] = true
		}
	}
	return ids, nil
}

func optionalColumnExpr(columns map[string]bool, name string) string {
	if columns[name] {
		return name
	}
	return "'' as " + name
}

func topLevelHistoryPredicate(columns map[string]bool, edgeColumns map[string]bool) string {
	return "(" + strings.Join([]string{
		displayableThreadPredicate(columns),
		interactiveSourcePredicate(columns),
		nonSubagentPredicate(columns, edgeColumns),
	}, " and ") + ")"
}

func displayableThreadPredicate(columns map[string]bool) string {
	if columns["preview"] {
		return "coalesce(preview, '') != ''"
	}
	if columns["title"] {
		return "coalesce(title, '') != ''"
	}
	return "1=1"
}

func interactiveSourcePredicate(columns map[string]bool) string {
	if !columns["source"] {
		return "1=1"
	}
	// Codex 的 thread/list 默认只展示交互入口：cli、vscode、atlas、chatgpt。
	return "(source in ('cli', 'vscode', '{\"custom\":\"atlas\"}', '{\"custom\":\"chatgpt\"}'))"
}

func nonSubagentPredicate(columns map[string]bool, edgeColumns map[string]bool) string {
	// Codex 的子 Agent 会话会进入同一个 threads 表，但 Codex 主界面默认不把它们当成顶层会话展示。
	var parts []string
	if edgeColumns["child_thread_id"] {
		parts = append(parts, "not exists (select 1 from thread_spawn_edges e where e.child_thread_id = threads.id)")
	}
	if columns["thread_source"] {
		parts = append(parts, "coalesce(thread_source, '') != 'subagent'")
	}
	if columns["source"] {
		parts = append(parts, "coalesce(source, '') != 'subagent'", "instr(coalesce(source, ''), '\"subagent\"') = 0")
	}
	if len(parts) == 0 {
		return "1=1"
	}
	return "(" + strings.Join(parts, " and ") + ")"
}

func isSubagentThread(item row, childThreadIDs map[string]bool) bool {
	if childThreadIDs[item.ID] {
		return true
	}
	if strings.EqualFold(strings.TrimSpace(item.ThreadSource), "subagent") {
		return true
	}
	source := strings.TrimSpace(item.Source)
	return strings.EqualFold(source, "subagent") || strings.Contains(source, `"subagent"`)
}

func isInteractiveSource(source string) bool {
	source = strings.TrimSpace(source)
	if source == "" {
		return true
	}
	switch strings.ToLower(source) {
	case "cli", "vscode":
		return true
	}
	var custom map[string]string
	if err := json.Unmarshal([]byte(source), &custom); err != nil {
		return false
	}
	value, ok := custom["custom"]
	return ok && (value == "atlas" || value == "chatgpt")
}

func pathPredicate(path string) string {
	clean := strings.TrimRight(filepath.Clean(path), string(os.PathSeparator))
	return "cwd = " + sqlQuote(clean) + " or cwd like " + sqlQuote(clean+string(os.PathSeparator)+"%")
}

func sqlQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func normalizeQueryLimit(limit int) int {
	if limit <= 0 {
		return defaultQueryLimit
	}
	if limit > maxQueryLimit {
		return maxQueryLimit
	}
	return limit
}

type cacheAccessTracker struct {
	next  uint64
	ticks map[string]uint64
}

func newCacheAccessTracker() cacheAccessTracker {
	return cacheAccessTracker{ticks: map[string]uint64{}}
}

func (tracker *cacheAccessTracker) touch(key string) {
	if tracker.ticks == nil {
		tracker.ticks = map[string]uint64{}
	}
	tracker.next++
	// 命中缓存时只更新一个递增 tick，避免原来的数组删除/追加导致每次命中都 O(n) 扫描。
	tracker.ticks[key] = tracker.next
}

func (tracker *cacheAccessTracker) forget(key string) {
	if tracker.ticks == nil {
		return
	}
	delete(tracker.ticks, key)
}

func (tracker *cacheAccessTracker) reset() {
	tracker.next = 0
	tracker.ticks = map[string]uint64{}
}

func trimCacheLRU[T any](items map[string]T, access *cacheAccessTracker, max int) {
	if max <= 0 {
		for key := range items {
			delete(items, key)
		}
		access.reset()
		return
	}

	pruneCacheAccess(items, access)
	for len(items) > max {
		oldest, ok := oldestCacheKey(items, access)
		if !ok {
			for key := range items {
				delete(items, key)
				access.forget(key)
				break
			}
			continue
		}
		delete(items, oldest)
		access.forget(oldest)
	}
}

func pruneCacheAccess[T any](items map[string]T, access *cacheAccessTracker) {
	if access.ticks == nil {
		access.reset()
		return
	}
	for key := range access.ticks {
		if _, ok := items[key]; !ok {
			delete(access.ticks, key)
		}
	}
}

func oldestCacheKey[T any](items map[string]T, access *cacheAccessTracker) (string, bool) {
	var oldest string
	var oldestTick uint64
	for key, tick := range access.ticks {
		if _, ok := items[key]; !ok {
			continue
		}
		if oldest == "" || tick < oldestTick {
			oldest = key
			oldestTick = tick
		}
	}
	return oldest, oldest != ""
}

func cloneRows(rows []row) []row {
	return append([]row(nil), rows...)
}

func cloneBoolMap(items map[string]bool) map[string]bool {
	if len(items) == 0 {
		return map[string]bool{}
	}
	cloned := make(map[string]bool, len(items))
	for key, value := range items {
		cloned[key] = value
	}
	return cloned
}

func minInt(a int, b int) int {
	if a < b {
		return a
	}
	return b
}

func homeDir() string {
	if home, err := homeDirFunc(); err == nil {
		return home
	}
	return ""
}

func msTime(v int64) time.Time {
	if v <= 0 {
		return time.Now()
	}
	return time.UnixMilli(v)
}
