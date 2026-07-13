package codexhistory

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
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

type Message struct {
	ID              string    `json:"id,omitempty"`
	Role            string    `json:"role"`
	Content         string    `json:"content"`
	CreatedAt       time.Time `json:"created_at"`
	ClientMessageID string    `json:"client_message_id,omitempty"`
	Revision        int       `json:"revision,omitempty"`
	SendStatus      string    `json:"send_status,omitempty"`
}

type MessagePage struct {
	Messages       []Message `json:"messages"`
	PreviousCursor string    `json:"previous_cursor,omitempty"`
	HasMoreBefore  bool      `json:"has_more_before"`
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
	sqliteQueryFunc = func(db string, query string) ([]byte, error) {
		return exec.Command("sqlite3", "-json", db, query).Output()
	}
)

const (
	defaultQueryLimit       = 300
	maxQueryLimit           = 2000
	maxHistoryCaches        = 16
	maxMessageCaches        = 32
	maxMessagePageCaches    = 64
	maxMessageIndexCaches   = 16
	maxMessageIndexBytes    = 8 * 1024 * 1024
	maxRolloutPathCaches    = 512
	maxRolloutDBCaches      = 512
	historyCacheTTL         = 1500 * time.Millisecond
	rolloutPathCacheTTL     = 1500 * time.Millisecond
	tailInitialReadSize     = 128 * 1024
	tailReadChunkSize       = 512 * 1024
	maxTailPendingLineBytes = maxMessageIndexBytes
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

type rolloutDBPathCacheEntry struct {
	signature dbSignature
	path      string
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

var rolloutDBPathCache = struct {
	sync.Mutex
	items  map[string]rolloutDBPathCacheEntry
	access cacheAccessTracker
}{items: map[string]rolloutDBPathCacheEntry{}, access: newCacheAccessTracker()}

type messageCacheEntry struct {
	size     int64
	modTime  time.Time
	limit    int
	complete bool
	messages []Message
}

type messagePageCacheEntry struct {
	size         int64
	modTime      time.Time
	beforeOffset int64
	limit        int
	page         MessagePage
}

type messageIndexCacheEntry struct {
	size     int64
	modTime  time.Time
	messages []parsedMessage
}

var messageCache = struct {
	sync.Mutex
	items  map[string]messageCacheEntry
	access cacheAccessTracker
}{items: map[string]messageCacheEntry{}, access: newCacheAccessTracker()}

var messagePageCache = struct {
	sync.Mutex
	items  map[string]messagePageCacheEntry
	access cacheAccessTracker
}{items: map[string]messagePageCacheEntry{}, access: newCacheAccessTracker()}

var messageIndexCache = struct {
	sync.Mutex
	items  map[string]messageIndexCacheEntry
	access cacheAccessTracker
}{items: map[string]messageIndexCacheEntry{}, access: newCacheAccessTracker()}

func Load(registry *projects.Registry, active []*session.Session) []session.SessionSnapshot {
	sessions, _ := load(registry, active, "", defaultQueryLimit, PageCursor{})
	return sessions
}

func LoadForProject(registry *projects.Registry, active []*session.Session, projectID string, limit int) []session.SessionSnapshot {
	sessions, _ := load(registry, active, projectID, limit, PageCursor{})
	return sessions
}

func LoadPage(registry *projects.Registry, active []*session.Session, projectID string, limit int, cursor PageCursor) []session.SessionSnapshot {
	sessions, _ := load(registry, active, projectID, limit, cursor)
	return sessions
}

func Diagnose(registry *projects.Registry, active []*session.Session, projectID string, limit int) Diagnostics {
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

	seen := activeThreadIDs(active)
	rows, childThreadIDs, scan, err := store.ListThreadsWithStats(projectFilter, limit, true, PageCursor{})
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.Scan = scan
	_, diagnostics := rowsToSessions(rows, registry, seen, projectID, childThreadIDs)
	result.Rows = diagnostics
	for _, item := range diagnostics {
		result.Counts["scanned"]++
		if item.Included {
			result.Counts["included"]++
		} else {
			result.Counts[item.Reason]++
		}
	}
	return result
}

func load(registry *projects.Registry, active []*session.Session, projectID string, limit int, cursor PageCursor) ([]session.SessionSnapshot, error) {
	store := defaultThreadStore()
	if _, err := os.Stat(store.databasePath()); err != nil {
		return nil, err
	}

	var projectFilter *projects.Project
	if projectID != "" {
		project, ok := registry.Get(projectID)
		if !ok {
			return nil, os.ErrNotExist
		}
		projectFilter = &project
	}

	rows, childThreadIDs, err := store.ListThreads(projectFilter, normalizeQueryLimit(limit), false, cursor)
	if err != nil {
		return nil, err
	}
	sessions, _ := rowsToSessions(rows, registry, activeThreadIDs(active), projectID, childThreadIDs)
	return sessions, nil
}

func LatestThreadIDForProjectSince(project projects.Project, since time.Time) (string, error) {
	store := defaultThreadStore()
	return store.LatestThreadIDForProjectSince(project, since)
}

func (s ThreadStore) LatestThreadIDForProjectSince(project projects.Project, since time.Time) (string, error) {
	db := s.databasePath()
	signature, err := readDBSignature(db)
	if err != nil {
		return "", err
	}
	columns, edgeColumns, err := historyColumns(db, signature)
	if err != nil {
		return "", err
	}
	// -3s 回看窗口容忍 session 记录时间与 Codex 写库时间之间的时钟偏差。
	minMS := since.Add(-3 * time.Second).UnixMilli()
	rows, err := queryRowsSince(db, &project, minMS, 20, columns, edgeColumns)
	if err != nil {
		return "", err
	}
	for _, item := range rows {
		if item.ID == "" || isSubagentThread(item, nil) || !isInteractiveSource(item.Source) || isMissingRollout(item) {
			continue
		}
		// 只认“会话开始之后才新建”的 thread：新建会话的真实 thread，或 resume 被 Codex
		// fork 出来的新 thread。resume 沿用同一 thread 时它的 created_at 在会话开始之前，
		// 会被这里排除，于是上层回退到 baseline（resume thread），不改变既有 resume 行为。
		if item.CreatedAtMS > 0 && item.CreatedAtMS < minMS {
			continue
		}
		return item.ID, nil
	}
	return "", os.ErrNotExist
}

func activeThreadIDs(active []*session.Session) map[string]bool {
	seen := map[string]bool{}
	for _, s := range active {
		snapshot := s.Snapshot()
		if snapshot.HistoryThreadID != "" {
			seen[snapshot.HistoryThreadID] = true
		}
		if snapshot.ResumeID != "" {
			seen[snapshot.ResumeID] = true
		}
		if strings.HasPrefix(snapshot.ID, "codex_") {
			seen[strings.TrimPrefix(snapshot.ID, "codex_")] = true
		}
	}
	return seen
}

func rowsToSessions(rows []row, registry *projects.Registry, seen map[string]bool, projectID string, childThreadIDs map[string]bool) ([]session.SessionSnapshot, []DiagnosticRow) {
	var sessions []session.SessionSnapshot
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
		if item.ID == "" || seen[item.ID] {
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
		title := strings.TrimSpace(item.Title)
		if title == "" {
			title = strings.TrimSpace(item.Preview)
		}
		if title == "" {
			title = "Codex 历史会话"
		}
		sessions = append(sessions, session.SessionSnapshot{
			ID:        "codex_" + item.ID,
			ProjectID: project.ID,
			Project:   project.Name,
			Dir:       project.Path,
			Title:     trimRunes(title, 48),
			Status:    "history",
			Source:    "codex",
			ResumeID:  item.ID,
			CreatedAt: msTime(item.CreatedAtMS),
			UpdatedAt: msTime(item.UpdatedAtMS),
		})
		diagnostic.Included = true
		diagnostics = append(diagnostics, diagnostic)
	}
	return sessions, diagnostics
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

func rolloutDBPathCacheKey(db string, threadID string) string {
	return db + "\x00" + threadID
}

func cachedRolloutDBPath(key string, signature dbSignature) (string, bool) {
	rolloutDBPathCache.Lock()
	defer rolloutDBPathCache.Unlock()

	entry, ok := rolloutDBPathCache.items[key]
	if !ok || entry.signature != signature || entry.path == "" {
		if ok {
			delete(rolloutDBPathCache.items, key)
			rolloutDBPathCache.access.forget(key)
		}
		return "", false
	}
	rolloutDBPathCache.access.touch(key)
	return entry.path, true
}

func storeRolloutDBPath(key string, signature dbSignature, path string) {
	if path == "" {
		return
	}
	rolloutDBPathCache.Lock()
	defer rolloutDBPathCache.Unlock()

	// 打开历史消息时会反复按 thread id 查 rollout_path；用 DB/WAL 签名做失效条件，
	// 可以避免重复 shell sqlite3，同时保证 Codex 状态库变化后自动重新查询。
	rolloutDBPathCache.items[key] = rolloutDBPathCacheEntry{signature: signature, path: path}
	rolloutDBPathCache.access.touch(key)
	trimCacheLRU(rolloutDBPathCache.items, &rolloutDBPathCache.access, maxRolloutDBCaches)
}

func loadHistorySnapshot(db string, project *projects.Project, limit int, includeSubagents bool, cursor PageCursor) ([]row, map[string]bool, error) {
	rows, childIDs, _, err := loadHistorySnapshotWithStats(db, project, limit, includeSubagents, cursor)
	return rows, childIDs, err
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
	out, err := exec.Command("sqlite3", "-json", db, sql).Output()
	if err != nil {
		return nil, err
	}
	var rows []row
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

func queryRowsSince(db string, project *projects.Project, minUpdatedAtMS int64, limit int, columns map[string]bool, edgeColumns map[string]bool) ([]row, error) {
	where := "archived=0 and " + topLevelHistoryPredicate(columns, edgeColumns)
	if project != nil {
		where += " and (" + pathPredicate(project.Path)
		if project.RealPath != "" && project.RealPath != project.Path {
			where += " or " + pathPredicate(project.RealPath)
		}
		where += ")"
	}
	if minUpdatedAtMS > 0 {
		where += " and updated_at_ms >= " + strconv.FormatInt(minUpdatedAtMS, 10)
	}
	sourceExpr := optionalColumnExpr(columns, "source")
	threadSourceExpr := optionalColumnExpr(columns, "thread_source")
	previewExpr := optionalColumnExpr(columns, "preview")
	rolloutPathExpr := optionalColumnExpr(columns, "rollout_path")
	hasRolloutPathExpr := "0 as has_rollout_path"
	if columns["rollout_path"] {
		hasRolloutPathExpr = "1 as has_rollout_path"
	}
	if limit <= 0 {
		limit = 20
	}
	sql := "select id,title,cwd," + sourceExpr + "," + threadSourceExpr + "," + previewExpr + "," +
		rolloutPathExpr + "," + hasRolloutPathExpr + ",created_at_ms,updated_at_ms from threads where " +
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

	// 会话列表刷新常常是 iOS 多个视图连续触发；缓存一个短快照，避免重复 shell 出 sqlite3。
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
	out, err := exec.Command("sqlite3", "-json", db, "select child_thread_id from thread_spawn_edges").Output()
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

func Messages(threadID string) ([]Message, error) {
	return MessagesWithLimit(threadID, 0)
}

func MessagesWithLimit(threadID string, limit int) ([]Message, error) {
	return defaultThreadStore().ReadMessagesWithLimit(threadID, limit)
}

func MessagesPageWithLimit(threadID string, before string, limit int) (MessagePage, error) {
	return defaultThreadStore().ReadMessagesPage(threadID, before, limit)
}

func messagesFromFile(file *os.File, info os.FileInfo, limit int) ([]Message, error) {
	if limit > 0 {
		page, err := messagesPageFromTail(file, info.Size(), limit)
		if err != nil {
			return nil, err
		}
		return page.Messages, nil
	}
	return messagesFromReader(file, limit)
}

func messagesFromTail(file *os.File, size int64, limit int) ([]Message, error) {
	if limit <= 0 {
		return messagesFromReader(file, limit)
	}
	page, err := messagesPageFromTail(file, size, limit)
	if err != nil {
		return nil, err
	}
	return page.Messages, nil
}

type parsedMessage struct {
	message   Message
	lineStart int64
}

const defaultMessagePageLimit = 120

func messagesPageFromTail(file *os.File, endOffset int64, limit int) (MessagePage, error) {
	if limit <= 0 {
		limit = defaultMessagePageLimit
	}
	if endOffset < 0 {
		endOffset = 0
	}
	target := limit + 1
	newestFirst := make([]parsedMessage, 0, target)
	var pending []byte
	offset := endOffset
	bufferSize := int64(tailInitialReadSize)
	if bufferSize > tailReadChunkSize {
		bufferSize = tailReadChunkSize
	}
	if offset > 0 && offset < bufferSize {
		bufferSize = offset
	}
	chunk := make([]byte, bufferSize)
	for offset > 0 && len(newestFirst) < target {
		readSize := int64(len(chunk))
		if offset < readSize {
			readSize = offset
		}
		offset -= readSize

		n, err := file.ReadAt(chunk[:readSize], offset)
		if err != nil && !errors.Is(err, io.EOF) {
			return MessagePage{}, err
		}
		data := append(chunk[:n], pending...)
		dataStart := offset
		start := len(data)
		for start > 0 && len(newestFirst) < target {
			idx := bytes.LastIndexByte(data[:start], '\n')
			if idx < 0 {
				break
			}
			lineStart := dataStart + int64(idx+1)
			if message, ok := parseMessageLine(data[idx+1 : start]); ok {
				message.ID = messageIDForOffset(lineStart)
				newestFirst = append(newestFirst, parsedMessage{message: message, lineStart: lineStart})
			}
			start = idx
		}
		// 从文件尾部倒读时，data[:start] 是跨 chunk 的半行；保留下来等前一个 chunk 补齐。
		if len(newestFirst) < target {
			pending = storeTailPendingLine(pending, data[:start])
		}
	}
	if len(newestFirst) < target && len(bytes.TrimSpace(pending)) > 0 {
		if message, ok := parseMessageLine(pending); ok {
			message.ID = messageIDForOffset(0)
			newestFirst = append(newestFirst, parsedMessage{message: message, lineStart: 0})
		}
	}
	reverseParsedMessages(newestFirst)
	hasMoreBefore := len(newestFirst) > limit
	if hasMoreBefore {
		newestFirst = newestFirst[len(newestFirst)-limit:]
	}
	messages := make([]Message, 0, len(newestFirst))
	previousCursor := ""
	if len(newestFirst) > 0 && hasMoreBefore {
		previousCursor = encodeMessageCursor(newestFirst[0].lineStart)
	}
	for _, item := range newestFirst {
		messages = append(messages, item.message)
	}
	return MessagePage{
		Messages:       messages,
		PreviousCursor: previousCursor,
		HasMoreBefore:  hasMoreBefore,
	}, nil
}

func storeTailPendingLine(reuse []byte, halfLine []byte) []byte {
	if len(halfLine) > maxTailPendingLineBytes {
		// Codex rollout 里常见超大的 token_count/tool/result 行。倒读时如果一直拼接这类跨 chunk
		// 半行，服务端会临时持有数十 MB 内存；超过上限后直接跳过该行尾部，继续解析更早消息。
		return nil
	}
	return append(reuse[:0], halfLine...)
}

func indexedMessagesFromFile(file *os.File) ([]parsedMessage, error) {
	return indexedMessagesFromFileAt(file, 0, nil)
}

func indexedMessagesFromFileAt(file *os.File, startOffset int64, messages []parsedMessage) ([]parsedMessage, error) {
	if _, err := file.Seek(startOffset, io.SeekStart); err != nil {
		return nil, err
	}
	buffered := bufio.NewReaderSize(file, 256*1024)
	offset := startOffset
	for {
		line, err := buffered.ReadBytes('\n')
		lineStart := offset
		offset += int64(len(line))
		if len(bytes.TrimSpace(line)) > 0 {
			if message, ok := parseMessageLine(line); ok {
				message.ID = messageIDForOffset(lineStart)
				messages = append(messages, parsedMessage{message: message, lineStart: lineStart})
			}
		}
		if err == nil {
			continue
		}
		if errors.Is(err, io.EOF) {
			return messages, nil
		}
		return nil, err
	}
}

func extendCachedMessageIndex(path string, info os.FileInfo, file *os.File) ([]parsedMessage, bool, error) {
	indexed, startOffset, ok := cachedMessageIndexPrefix(path, info)
	if !ok {
		return nil, false, nil
	}
	atLineBoundary, err := fileOffsetStartsAtLineBoundary(file, startOffset)
	if err != nil {
		return nil, false, err
	}
	if !atLineBoundary {
		return nil, false, nil
	}
	// Codex rollout 是 append-only JSONL；已有索引覆盖旧 size 前缀时，只解析新增尾段，
	// 避免运行中会话每次刷新都把同一个小文件前缀重新扫一遍。
	indexed, err = indexedMessagesFromFileAt(file, startOffset, indexed)
	if err != nil {
		return nil, false, err
	}
	storeCachedMessageIndex(path, info, indexed)
	return indexed, true, nil
}

func fileOffsetStartsAtLineBoundary(file *os.File, offset int64) (bool, error) {
	if offset <= 0 {
		return true, nil
	}
	var previous [1]byte
	_, err := file.ReadAt(previous[:], offset-1)
	if err != nil {
		return false, err
	}
	return previous[0] == '\n', nil
}

func pageFromIndexedMessages(indexed []parsedMessage, endOffset int64, limit int) MessagePage {
	if limit <= 0 {
		limit = defaultMessagePageLimit
	}
	if endOffset < 0 {
		endOffset = 0
	}
	endIndex := sort.Search(len(indexed), func(i int) bool {
		return indexed[i].lineStart >= endOffset
	})
	start := endIndex - limit - 1
	if start < 0 {
		start = 0
	}
	window := indexed[start:endIndex]
	hasMoreBefore := len(window) > limit
	if hasMoreBefore {
		window = window[len(window)-limit:]
	}
	page := MessagePage{
		Messages:      make([]Message, 0, len(window)),
		HasMoreBefore: hasMoreBefore,
	}
	if hasMoreBefore && len(window) > 0 {
		page.PreviousCursor = encodeMessageCursor(window[0].lineStart)
	}
	for _, item := range window {
		page.Messages = append(page.Messages, item.message)
	}
	return page
}

func messagesFromReader(reader io.Reader, limit int) ([]Message, error) {
	var messages []Message
	buffered := bufio.NewReaderSize(reader, 256*1024)
	var offset int64
	for {
		// Codex rollout 里可能包含很大的 tool/result 行，Scanner 有单行上限；
		// 用 ReadBytes 按行读取可以保留 JSONL 语义，同时避免大历史会话被整页吞空。
		line, err := buffered.ReadBytes('\n')
		lineStart := offset
		offset += int64(len(line))
		if len(bytes.TrimSpace(line)) > 0 {
			if message, ok := parseMessageLine(line); ok {
				message.ID = messageIDForOffset(lineStart)
				messages = appendLimitedMessage(messages, message, limit)
			}
		}
		if err == nil {
			continue
		}
		if errors.Is(err, io.EOF) {
			return messages, nil
		}
		return messages, err
	}
}

func parseMessageLine(line []byte) (Message, bool) {
	var message Message
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return message, false
	}
	if !bytes.Contains(line, []byte(`"type":"event_msg"`)) {
		return message, false
	}
	if !bytes.Contains(line, []byte(`"type":"user_message"`)) && !bytes.Contains(line, []byte(`"type":"agent_message"`)) {
		return message, false
	}

	if message, ok := parseMessageLineFast(line); ok {
		return message, true
	}
	return parseMessageLineJSON(line)
}

func parseMessageLineFast(line []byte) (Message, bool) {
	var message Message
	topType, topEscaped, ok := jsonStringField(line, []byte(`"type"`))
	if !ok || topEscaped || !bytes.Equal(topType, []byte("event_msg")) {
		return message, false
	}
	payloadIndex := bytes.Index(line, []byte(`"payload"`))
	if payloadIndex < 0 {
		return message, false
	}
	payload := line[payloadIndex:]
	eventType, eventEscaped, ok := jsonStringField(payload, []byte(`"type"`))
	if !ok || eventEscaped {
		return message, false
	}
	role := ""
	switch {
	case bytes.Equal(eventType, []byte("user_message")):
		role = "user"
	case bytes.Equal(eventType, []byte("agent_message")):
		role = "assistant"
	default:
		return message, false
	}
	rawText, textEscaped, ok := jsonStringField(payload, []byte(`"message"`))
	if !ok {
		return message, false
	}
	text, ok := decodeJSONString(rawText, textEscaped)
	if !ok {
		return message, false
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return message, false
	}
	rawTimestamp, timestampEscaped, ok := jsonStringField(line, []byte(`"timestamp"`))
	if !ok {
		return message, false
	}
	timestamp, ok := decodeJSONString(rawTimestamp, timestampEscaped)
	if !ok {
		return message, false
	}
	return Message{Role: role, Content: text, CreatedAt: parseTime(timestamp)}, true
}

func parseMessageLineJSON(line []byte) (Message, bool) {
	var message Message
	var item struct {
		Timestamp string `json:"timestamp"`
		Type      string `json:"type"`
		Payload   struct {
			Type    string `json:"type"`
			Message string `json:"message"`
			Phase   string `json:"phase"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(line, &item); err != nil || item.Type != "event_msg" {
		return message, false
	}
	role := ""
	switch item.Payload.Type {
	case "user_message":
		role = "user"
	case "agent_message":
		role = "assistant"
	default:
		return message, false
	}
	text := strings.TrimSpace(item.Payload.Message)
	if text == "" {
		return message, false
	}
	return Message{Role: role, Content: text, CreatedAt: parseTime(item.Timestamp)}, true
}

func jsonStringField(line []byte, key []byte) ([]byte, bool, bool) {
	index := bytes.Index(line, key)
	if index < 0 {
		return nil, false, false
	}
	position := index + len(key)
	for position < len(line) && isJSONSpace(line[position]) {
		position++
	}
	if position >= len(line) || line[position] != ':' {
		return nil, false, false
	}
	position++
	for position < len(line) && isJSONSpace(line[position]) {
		position++
	}
	if position >= len(line) || line[position] != '"' {
		return nil, false, false
	}
	position++
	start := position
	escaped := false
	for position < len(line) {
		switch line[position] {
		case '\\':
			escaped = true
			position += 2
			continue
		case '"':
			return line[start:position], escaped, true
		default:
			position++
		}
	}
	return nil, false, false
}

func decodeJSONString(raw []byte, escaped bool) (string, bool) {
	if !escaped {
		return string(raw), true
	}
	quoted := make([]byte, 0, len(raw)+2)
	quoted = append(quoted, '"')
	quoted = append(quoted, raw...)
	quoted = append(quoted, '"')
	value, err := strconv.Unquote(string(quoted))
	if err != nil {
		return "", false
	}
	return value, true
}

func isJSONSpace(value byte) bool {
	return value == ' ' || value == '\n' || value == '\r' || value == '\t'
}

func appendLimitedMessage(messages []Message, message Message, limit int) []Message {
	if limit <= 0 || len(messages) < limit {
		return append(messages, message)
	}
	// 只保留最近 N 条历史，避免大历史会话一次性撑满网络响应和 SwiftUI 渲染。
	copy(messages, messages[1:])
	messages[len(messages)-1] = message
	return messages
}

func cachedMessages(path string, info os.FileInfo, limit int) ([]Message, bool) {
	messageCache.Lock()
	defer messageCache.Unlock()

	entry, ok := messageCache.items[path]
	if !ok || entry.size != info.Size() || !entry.modTime.Equal(info.ModTime()) {
		if ok {
			delete(messageCache.items, path)
			messageCache.access.forget(path)
		}
		return nil, false
	}
	if !entry.complete && (limit <= 0 || entry.limit < limit) {
		return nil, false
	}
	messageCache.access.touch(path)
	return applyMessageLimit(cloneMessages(entry.messages), limit), true
}

func storeCachedMessages(path string, info os.FileInfo, limit int, messages []Message) {
	messageCache.Lock()
	defer messageCache.Unlock()

	// rollout 会随会话追加而变更；用 size+mtime 做缓存版本，命中时避免反复扫描大 JSONL。
	messageCache.items[path] = messageCacheEntry{
		size:     info.Size(),
		modTime:  info.ModTime(),
		limit:    limit,
		complete: limit <= 0,
		messages: cloneMessages(messages),
	}
	messageCache.access.touch(path)
	trimCacheLRU(messageCache.items, &messageCache.access, maxMessageCaches)
}

func cachedMessagePage(path string, info os.FileInfo, beforeOffset int64, limit int) (MessagePage, bool) {
	messagePageCache.Lock()
	defer messagePageCache.Unlock()

	key := messagePageCacheKey(path, beforeOffset, limit)
	entry, ok := messagePageCache.items[key]
	if !ok || !cachedMessagePageStillValid(entry, info, beforeOffset) {
		if ok {
			delete(messagePageCache.items, key)
			messagePageCache.access.forget(key)
		}
		return MessagePage{}, false
	}
	messagePageCache.access.touch(key)
	return cloneMessagePage(entry.page), true
}

func cachedMessagePageStillValid(entry messagePageCacheEntry, info os.FileInfo, beforeOffset int64) bool {
	if entry.size == info.Size() && entry.modTime.Equal(info.ModTime()) {
		return true
	}
	// Codex rollout 是 append-only JSONL。历史翻页读取的是 beforeOffset 之前的稳定前缀；
	// 后续追加只改变尾部最新页，不会改变旧 offset 前的消息窗口。这样用户边看旧历史边有新输出时，
	// “加载更早消息”不会因为文件 size/mtime 变化而反复倒读同一段 JSONL。
	return beforeOffset > 0 && beforeOffset <= entry.size && info.Size() >= entry.size
}

func storeCachedMessagePage(path string, info os.FileInfo, beforeOffset int64, limit int, page MessagePage) {
	messagePageCache.Lock()
	defer messagePageCache.Unlock()

	key := messagePageCacheKey(path, beforeOffset, limit)
	// 历史消息页会在打开/刷新/返回会话时反复读取；按 offset+limit 缓存整页。
	// 最新尾页仍由当前 file size 决定；旧 before offset 页按 append-only 前缀复用。
	messagePageCache.items[key] = messagePageCacheEntry{
		size:         info.Size(),
		modTime:      info.ModTime(),
		beforeOffset: beforeOffset,
		limit:        limit,
		page:         cloneMessagePage(page),
	}
	messagePageCache.access.touch(key)
	trimCacheLRU(messagePageCache.items, &messagePageCache.access, maxMessagePageCaches)
}

func shouldBuildMessageIndex(info os.FileInfo) bool {
	return info.Size() > 0 && info.Size() <= maxMessageIndexBytes
}

func cachedMessageIndex(path string, info os.FileInfo) ([]parsedMessage, bool) {
	messageIndexCache.Lock()
	defer messageIndexCache.Unlock()

	entry, ok := messageIndexCache.items[path]
	if !ok || entry.size != info.Size() || !entry.modTime.Equal(info.ModTime()) {
		if ok && entry.size > info.Size() {
			delete(messageIndexCache.items, path)
			messageIndexCache.access.forget(path)
		}
		return nil, false
	}
	messageIndexCache.access.touch(path)
	return cloneParsedMessages(entry.messages), true
}

func cachedMessageIndexPrefix(path string, info os.FileInfo) ([]parsedMessage, int64, bool) {
	if !shouldBuildMessageIndex(info) {
		return nil, 0, false
	}
	messageIndexCache.Lock()
	defer messageIndexCache.Unlock()

	entry, ok := messageIndexCache.items[path]
	if !ok || entry.size <= 0 || entry.size >= info.Size() {
		return nil, 0, false
	}
	messageIndexCache.access.touch(path)
	return cloneParsedMessages(entry.messages), entry.size, true
}

func storeCachedMessageIndex(path string, info os.FileInfo, messages []parsedMessage) {
	if !shouldBuildMessageIndex(info) {
		return
	}
	messageIndexCache.Lock()
	defer messageIndexCache.Unlock()

	// 这是 Codex rollout 的轻量 metadata index：只缓存消息行 offset 和已解析消息。
	// 翻更早历史时可以直接二分切页，不再对同一个 JSONL 前缀重复倒读和解析。
	messageIndexCache.items[path] = messageIndexCacheEntry{
		size:     info.Size(),
		modTime:  info.ModTime(),
		messages: cloneParsedMessages(messages),
	}
	messageIndexCache.access.touch(path)
	trimCacheLRU(messageIndexCache.items, &messageIndexCache.access, maxMessageIndexCaches)
}

func messagePageCacheKey(path string, beforeOffset int64, limit int) string {
	return path + "\x00" + strconv.FormatInt(beforeOffset, 10) + "\x00" + strconv.Itoa(limit)
}

func applyMessageLimit(messages []Message, limit int) []Message {
	if limit <= 0 || len(messages) <= limit {
		return messages
	}
	return messages[len(messages)-limit:]
}

func cloneMessagePage(page MessagePage) MessagePage {
	page.Messages = cloneMessages(page.Messages)
	return page
}

func cloneMessages(messages []Message) []Message {
	return append([]Message(nil), messages...)
}

func cloneParsedMessages(messages []parsedMessage) []parsedMessage {
	return append([]parsedMessage(nil), messages...)
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

type messageCursor struct {
	Offset int64 `json:"offset"`
}

func encodeMessageCursor(offset int64) string {
	if offset <= 0 {
		return ""
	}
	data, err := json.Marshal(messageCursor{Offset: offset})
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(data)
}

func decodeMessageCursor(raw string) (int64, bool) {
	if strings.TrimSpace(raw) == "" {
		return 0, false
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return 0, false
	}
	var cursor messageCursor
	if err := json.Unmarshal(data, &cursor); err != nil || cursor.Offset <= 0 {
		return 0, false
	}
	return cursor.Offset, true
}

func messageIDForOffset(offset int64) string {
	return "rollout:" + strconv.FormatInt(offset, 10)
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

func reverseMessages(messages []Message) {
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}
}

func reverseParsedMessages(messages []parsedMessage) {
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}
}

func MessagesForSession(sessionID string, resumeID string) ([]Message, error) {
	threadID := ThreadIDForSession(sessionID, resumeID)
	if threadID == "" {
		return nil, os.ErrNotExist
	}
	return MessagesWithLimit(threadID, 0)
}

func ThreadIDForSession(sessionID string, resumeID string) string {
	if trimmed := strings.TrimSpace(resumeID); trimmed != "" {
		return trimmed
	}
	sessionID = strings.TrimSpace(sessionID)
	if strings.HasPrefix(sessionID, "codex_") {
		return strings.TrimPrefix(sessionID, "codex_")
	}
	return sessionID
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

func parseTime(raw string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return time.Now()
	}
	return t
}

func trimRunes(s string, n int) string {
	runes := []rune(strings.Join(strings.Fields(s), " "))
	if len(runes) <= n {
		return string(runes)
	}
	return string(runes[:n]) + "..."
}
