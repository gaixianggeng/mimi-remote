package codexhistory

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

const (
	externalActivityCandidateLimit = 500
	maxExternalActivityLineBytes   = 1 << 20
	// Gateway 登记只需要覆盖 turn/start 到 rollout 写入 user_message 的短窗口。
	// 有界 TTL 可以避免断线或 upstream 写失败后留下永久“本机发起”证据。
	gatewayTurnRegistrationTTL   = 2 * time.Minute
	gatewayTurnRegistrationLimit = 512
	gatewayTurnRegistrationIDMax = 256
	gatewayTurnEventClockSkew    = 2 * time.Second
	// gateway 在写入 upstream 前登记；task_started 应很快出现。真实 app-server
	// 冷启动时 user_message 可能比 task_started 晚十几秒落盘，因此不能再用
	// 两个 rollout 事件的短间隔判断归属。改为要求 task_started 靠近登记时刻，
	// 同时保留精确 Thread+client ID 和 2 分钟总 TTL。
	gatewayTurnStartWindow     = 30 * time.Second
	gatewayTurnLifecycleWindow = gatewayTurnRegistrationTTL
)

// ExternalActivity 是允许返回给移动端的最小只读快照。
// 不包含 cwd、rollout 路径、prompt 或消息内容，避免把本机 Codex 状态库变成文件枚举接口。
type ExternalActivity struct {
	ThreadID     string    `json:"thread_id"`
	ProjectID    string    `json:"project_id"`
	Source       string    `json:"source"`
	State        string    `json:"state"`
	TurnID       string    `json:"turn_id,omitempty"`
	Revision     string    `json:"revision"`
	LastActivity time.Time `json:"last_activity_at"`
}

type ExternalActivityDiagnostics struct {
	CandidateQueries int `json:"candidate_queries"`
	FileScans        int `json:"file_scans"`
	CacheHits        int `json:"cache_hits"`
	MalformedLines   int `json:"malformed_lines"`
	OversizedLines   int `json:"oversized_lines"`
	ClaimStoreWrites int `json:"claim_store_writes"`
	ClaimStoreErrors int `json:"claim_store_errors"`
}

type externalActivityCandidate struct {
	ThreadID     string
	CWD          string
	Source       string
	ThreadSource string
	RolloutPath  string
}

type externalRolloutCacheEntry struct {
	offset       int64
	size         int64
	modTime      time.Time
	metaThreadID string
	metaCWD      string
	threadSource string
	active       bool
	turnID       string
	// gatewayTurnPending 表示在 task_started 之前到达的 user_message 已与 gateway 登记匹配；
	// gatewayOwned 绑定当前 active turn。真实 rollout 可能先写 task_started，也可能先写
	// user_message，因此两个方向都要支持；新的 task_started 仍必须重新取证。
	gatewayTurnPending             bool
	gatewayTurnPendingAt           time.Time
	gatewayTurnPendingRegisteredAt time.Time
	gatewayOwned                   bool
	turnStartedAt                  time.Time
}

type gatewayTurnRegistration struct {
	registeredAt time.Time
}

type gatewayTurnEvidence struct {
	registeredAt time.Time
	eventAt      time.Time
}

type externalRolloutRecord struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Payload   struct {
		ID           string `json:"id"`
		CWD          string `json:"cwd"`
		ThreadSource string `json:"thread_source"`
		Type         string `json:"type"`
		TurnID       string `json:"turn_id"`
		ClientID     string `json:"client_id"`
	} `json:"payload"`
}

// ExternalActivityTracker 按请求增量读取 rollout 尾部。它没有后台 goroutine，
// agentd 空闲时不会持续扫盘；同一个文件未变化时只做一次 stat 并复用解析状态。
type ExternalActivityTracker struct {
	mu       sync.Mutex
	store    ThreadStore
	registry *projects.Registry
	now      func() time.Time
	stat     func(string) (os.FileInfo, error)
	open     func(string) (*os.File, error)
	query    func(string, string) ([]byte, error)

	dbSignature  dbSignature
	dbCached     bool
	candidates   []externalActivityCandidate
	files        map[string]externalRolloutCacheEntry
	gatewayTurns map[string]gatewayTurnRegistration
	// ownedGatewayTurns 是精确的 Thread+Turn 归属证据。生产环境可为它配置
	// 私有 claim store，使 managed app-server 被重启强杀后，新 Tracker 仍能
	// 区分旧 iPad turn 与真正的新 Mac turn。
	ownedGatewayTurns   map[string]gatewayOwnedTurnClaim
	gatewayClaimStore   *gatewayTurnClaimStore
	gatewayClaimsLoaded bool
	gatewayClaimsDirty  bool
	diagnostics         ExternalActivityDiagnostics
}

func NewExternalActivityTracker(db string, registry *projects.Registry) *ExternalActivityTracker {
	return &ExternalActivityTracker{
		store:               NewThreadStore(db),
		registry:            registry,
		now:                 time.Now,
		stat:                os.Stat,
		open:                os.Open,
		query:               sqliteQueryFunc,
		files:               map[string]externalRolloutCacheEntry{},
		gatewayTurns:        map[string]gatewayTurnRegistration{},
		ownedGatewayTurns:   map[string]gatewayOwnedTurnClaim{},
		gatewayClaimsLoaded: true,
	}
}

func NewDefaultExternalActivityTracker(registry *projects.Registry) *ExternalActivityTracker {
	return NewExternalActivityTracker("", registry)
}

// NewExternalActivityTrackerWithClaimStore 只为生产入口和重启回归测试启用持久化。
// 普通 Router/单元测试继续使用纯内存构造器，避免污染当前用户的状态目录。
func NewExternalActivityTrackerWithClaimStore(
	db string,
	registry *projects.Registry,
	claimStorePath string,
) *ExternalActivityTracker {
	tracker := NewExternalActivityTracker(db, registry)
	tracker.gatewayClaimStore = newGatewayTurnClaimStore(claimStorePath)
	tracker.gatewayClaimsLoaded = tracker.gatewayClaimStore == nil
	return tracker
}

func NewDefaultExternalActivityTrackerWithClaimStore(
	registry *projects.Registry,
	claimStorePath string,
) *ExternalActivityTracker {
	return NewExternalActivityTrackerWithClaimStore("", registry, claimStorePath)
}

func (t *ExternalActivityTracker) Diagnostics() ExternalActivityDiagnostics {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.diagnostics
}

// RegisterGatewayTurnStart 登记一个已经通过 agentd gateway 校验的 Codex turn/start。
// 登记本身不会改变外部活动判断；只有同线程 rollout 随后写出时间相符且 client_id
// 完全一致的 user_message，才能把紧随其后的 task_started 认定为 iPad 发起。
func (t *ExternalActivityTracker) RegisterGatewayTurnStart(threadID string, clientUserMessageID string) {
	threadID = strings.TrimSpace(threadID)
	clientUserMessageID = strings.TrimSpace(clientUserMessageID)
	if threadID == "" ||
		clientUserMessageID == "" ||
		len(threadID) > gatewayTurnRegistrationIDMax ||
		len(clientUserMessageID) > gatewayTurnRegistrationIDMax {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	now := t.now().UTC()
	t.ensureGatewayTurnClaimsLoaded(now)
	t.pruneGatewayTurnRegistrations(now)
	t.pruneGatewayOwnedTurnClaims(now)
	if t.gatewayTurns == nil {
		t.gatewayTurns = map[string]gatewayTurnRegistration{}
	}
	key := gatewayTurnRegistrationKey(threadID, clientUserMessageID)
	t.gatewayTurns[key] = gatewayTurnRegistration{registeredAt: now}
	t.gatewayClaimsDirty = true
	t.trimGatewayTurnClaims()
	t.persistGatewayTurnClaims()
}

// Snapshot 只返回仍有外部 turn 运行证据的白名单项目线程。
// rollout 文件静默不等于 turn 结束；只有明确 terminal lifecycle 才会清除活动态。
func (t *ExternalActivityTracker) Snapshot() ([]ExternalActivity, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.registry == nil {
		return []ExternalActivity{}, nil
	}
	now := t.now().UTC()
	t.ensureGatewayTurnClaimsLoaded(now)
	t.pruneGatewayTurnRegistrations(now)
	t.pruneGatewayOwnedTurnClaims(now)
	defer t.persistGatewayTurnClaims()

	candidates, err := t.loadCandidates()
	if err != nil {
		return nil, err
	}

	activities := make([]ExternalActivity, 0, len(candidates))
	knownPaths := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		project, ok := t.registry.FindByPath(candidate.CWD)
		if !ok {
			continue
		}
		path := strings.TrimSpace(candidate.RolloutPath)
		if path == "" {
			continue
		}
		knownPaths[path] = struct{}{}
		info, err := t.stat(path)
		if err != nil || info.IsDir() {
			continue
		}
		entry, err := t.scanRollout(path, info)
		if err != nil {
			continue
		}
		if entry.gatewayOwned &&
			!t.hasGatewayOwnedTurnClaim(entry.metaThreadID, entry.turnID) {
			// claim TTL/容量裁剪已经失效时，不能让内存 rollout cache 继续隐藏 turn。
			// 安全降级为 external；文件是否静默不改变 active turn 的生命周期判断。
			entry.gatewayOwned = false
			t.files[path] = entry
		}
		if expireGatewayTurnPending(&entry, now) {
			t.files[path] = entry
		}
		if entry.active && entry.gatewayOwned {
			t.refreshGatewayOwnedTurnClaim(
				entry.metaThreadID,
				entry.turnID,
				info.ModTime().UTC(),
				now,
			)
		}
		// session_meta.originator 只表示 thread 的创建端，不是当前 turn 的所有者；
		// resume 后它可能仍是 mimi_remote、CLI 或其他创建端。只有 gateway 精确
		// Thread+Turn claim 才能证明这是 Mimi/iPad 自己的 turn，其他 active turn
		// 都必须按 external 只读活动处理。文件静默也不能证明 turn 已结束：长时间
		// 没有 rollout 写入可能只是正常等待，异常崩溃残留则保守地继续只读展示，
		// 以避免把仍在运行的 Desktop turn 误判为空闲。
		if entry.metaThreadID != candidate.ThreadID ||
			!isTopLevelExternalThreadSource(entry.threadSource) ||
			!entry.active ||
			entry.gatewayOwned {
			continue
		}
		// SQLite cwd 和 session_meta cwd 都必须落在同一个白名单项目中。
		// 这样即使状态库里出现不一致路径，也不会跨项目泄露线程身份。
		metaProject, ok := t.registry.FindByPath(entry.metaCWD)
		if !ok || metaProject.ID != project.ID {
			continue
		}
		activities = append(activities, ExternalActivity{
			ThreadID:     candidate.ThreadID,
			ProjectID:    project.ID,
			Source:       "codex_desktop",
			State:        "running",
			TurnID:       entry.turnID,
			Revision:     externalActivityRevision(info),
			LastActivity: info.ModTime().UTC(),
		})
	}
	for path := range t.files {
		if _, ok := knownPaths[path]; !ok {
			delete(t.files, path)
		}
	}
	sort.Slice(activities, func(i, j int) bool {
		if activities[i].LastActivity.Equal(activities[j].LastActivity) {
			return activities[i].ThreadID < activities[j].ThreadID
		}
		return activities[i].LastActivity.After(activities[j].LastActivity)
	})
	return activities, nil
}

func (t *ExternalActivityTracker) loadCandidates() ([]externalActivityCandidate, error) {
	db := t.store.databasePath()
	signature, err := t.readDBSignature(db)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			// 没有使用过 Codex 的旧主机可能尚未创建状态库。能力仍可安全声明，
			// 此时返回空活动而不是让 iPad 每轮轮询都收到 503。
			t.dbCached = false
			t.candidates = nil
			t.files = map[string]externalRolloutCacheEntry{}
			return []externalActivityCandidate{}, nil
		}
		return nil, err
	}
	if t.dbCached && signature == t.dbSignature {
		out := make([]externalActivityCandidate, len(t.candidates))
		copy(out, t.candidates)
		return out, nil
	}

	columns, edgeColumns, err := t.externalHistoryColumns(db)
	if err != nil {
		return nil, err
	}
	where := "1=1"
	if columns["archived"] {
		where = "archived=0"
	}
	where += " and " + interactiveSourcePredicate(columns)
	where += " and " + nonSubagentPredicate(columns, edgeColumns)
	if columns["thread_source"] {
		where += " and coalesce(thread_source, 'user') = 'user'"
	}
	sourceExpr := optionalColumnExpr(columns, "source")
	threadSourceExpr := optionalColumnExpr(columns, "thread_source")
	rolloutPathExpr := optionalColumnExpr(columns, "rollout_path")
	sql := "select id,cwd," + sourceExpr + "," + threadSourceExpr + "," + rolloutPathExpr +
		" from threads where " + where + " order by updated_at_ms desc, id desc limit " +
		strconv.Itoa(externalActivityCandidateLimit)
	out, err := t.query(db, sql)
	if err != nil {
		return nil, err
	}
	t.diagnostics.CandidateQueries++
	var rows []struct {
		ID           string `json:"id"`
		CWD          string `json:"cwd"`
		Source       string `json:"source"`
		ThreadSource string `json:"thread_source"`
		RolloutPath  string `json:"rollout_path"`
	}
	if len(bytes.TrimSpace(out)) != 0 {
		if err := json.Unmarshal(out, &rows); err != nil {
			return nil, err
		}
	}
	candidates := make([]externalActivityCandidate, 0, len(rows))
	for _, row := range rows {
		if strings.TrimSpace(row.ID) == "" ||
			strings.TrimSpace(row.CWD) == "" ||
			strings.TrimSpace(row.RolloutPath) == "" ||
			!isInteractiveSource(row.Source) ||
			!isTopLevelExternalThreadSource(row.ThreadSource) {
			continue
		}
		candidates = append(candidates, externalActivityCandidate{
			ThreadID:     row.ID,
			CWD:          row.CWD,
			Source:       row.Source,
			ThreadSource: row.ThreadSource,
			RolloutPath:  row.RolloutPath,
		})
	}
	t.dbSignature = signature
	t.dbCached = true
	t.candidates = candidates
	result := make([]externalActivityCandidate, len(candidates))
	copy(result, candidates)
	return result, nil
}

func (t *ExternalActivityTracker) externalHistoryColumns(db string) (map[string]bool, map[string]bool, error) {
	query := "select 'threads' as table_name, name from pragma_table_info('threads') " +
		"union all select 'thread_spawn_edges' as table_name, name from pragma_table_info('thread_spawn_edges')"
	out, err := t.query(db, query)
	if err != nil {
		return nil, nil, err
	}
	var rows []struct {
		TableName string `json:"table_name"`
		Name      string `json:"name"`
	}
	if len(bytes.TrimSpace(out)) != 0 {
		if err := json.Unmarshal(out, &rows); err != nil {
			return nil, nil, err
		}
	}
	columns := map[string]bool{}
	edgeColumns := map[string]bool{}
	for _, row := range rows {
		switch row.TableName {
		case "threads":
			columns[row.Name] = true
		case "thread_spawn_edges":
			edgeColumns[row.Name] = true
		}
	}
	if !columns["id"] || !columns["cwd"] || !columns["rollout_path"] || !columns["updated_at_ms"] {
		return nil, nil, fmt.Errorf("Codex 状态库缺少外部活动跟踪所需字段")
	}
	return columns, edgeColumns, nil
}

func (t *ExternalActivityTracker) readDBSignature(db string) (dbSignature, error) {
	info, err := t.stat(db)
	if err != nil {
		return dbSignature{}, err
	}
	signature := dbSignature{size: info.Size(), modTime: info.ModTime()}
	if wal, err := t.stat(db + "-wal"); err == nil {
		signature.walSize = wal.Size()
		signature.walModTime = wal.ModTime()
	}
	return signature, nil
}

func (t *ExternalActivityTracker) scanRollout(path string, info os.FileInfo) (externalRolloutCacheEntry, error) {
	entry, cached := t.files[path]
	if cached && entry.size == info.Size() && entry.modTime.Equal(info.ModTime()) {
		t.diagnostics.CacheHits++
		return entry, nil
	}
	if !cached || info.Size() < entry.offset || info.ModTime().Before(entry.modTime) {
		entry = externalRolloutCacheEntry{}
	}

	file, err := t.open(path)
	if err != nil {
		return entry, err
	}
	defer file.Close()
	if _, err := file.Seek(entry.offset, io.SeekStart); err != nil {
		return entry, err
	}

	t.diagnostics.FileScans++
	reader := bufio.NewReaderSize(file, 64*1024)
	committedOffset := entry.offset
	var line []byte
	lineBytes := int64(0)
	oversized := false
	for {
		fragment, readErr := reader.ReadSlice('\n')
		lineBytes += int64(len(fragment))
		if !oversized {
			if len(line)+len(fragment) <= maxExternalActivityLineBytes {
				line = append(line, fragment...)
			} else {
				oversized = true
				line = nil
			}
		}
		switch {
		case errors.Is(readErr, bufio.ErrBufferFull):
			continue
		case readErr == nil:
			if oversized {
				t.diagnostics.OversizedLines++
			} else {
				t.applyExternalRolloutLine(&entry, line)
			}
			committedOffset += lineBytes
			line = nil
			lineBytes = 0
			oversized = false
		case errors.Is(readErr, io.EOF):
			// rollout 是 append-only JSONL。尾部半行留到下次追加后再解析，
			// 不能提前提交 offset，否则会永久漏掉 lifecycle。
			entry.offset = committedOffset
			entry.size = info.Size()
			entry.modTime = info.ModTime()
			t.files[path] = entry
			return entry, nil
		default:
			return entry, readErr
		}
	}
}

func (t *ExternalActivityTracker) applyExternalRolloutLine(entry *externalRolloutCacheEntry, line []byte) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return
	}
	var record externalRolloutRecord
	if err := json.Unmarshal(line, &record); err != nil {
		t.diagnostics.MalformedLines++
		return
	}
	switch record.Type {
	case "session_meta":
		entry.metaThreadID = strings.TrimSpace(record.Payload.ID)
		entry.metaCWD = strings.TrimSpace(record.Payload.CWD)
		entry.threadSource = strings.TrimSpace(record.Payload.ThreadSource)
	case "event_msg":
		turnID := strings.TrimSpace(record.Payload.TurnID)
		switch strings.TrimSpace(record.Payload.Type) {
		case "user_message":
			// rollout 的落盘顺序并不固定：当前版本通常先写 task_started，再写
			// user_message；旧版本或边界窗口也可能相反。精确证据到达时，已有 active
			// turn 就直接归属本机，否则留给紧随其后的 task_started 消费。
			evidence, matched := t.consumeGatewayTurnRegistration(
				entry.metaThreadID,
				record.Payload.ClientID,
				record.Timestamp,
			)
			clearGatewayTurnPending(entry)
			if matched &&
				entry.active &&
				gatewayTurnEvidenceMatchesTaskStart(evidence, entry.turnStartedAt) {
				entry.gatewayOwned = true
				t.setGatewayOwnedTurnClaim(
					entry.metaThreadID,
					entry.turnID,
					evidence.eventAt,
				)
			} else if matched && !entry.active {
				entry.gatewayTurnPending = true
				entry.gatewayTurnPendingAt = evidence.eventAt
				entry.gatewayTurnPendingRegisteredAt = evidence.registeredAt
			}
		case "task_started":
			turnStartedAt, _ := parseExternalRolloutTimestamp(record.Timestamp)
			entry.active = true
			entry.turnID = turnID
			entry.turnStartedAt = turnStartedAt
			pendingOwned := entry.gatewayTurnPending &&
				gatewayTurnEvidenceMatchesTaskStart(
					gatewayTurnEvidence{
						registeredAt: entry.gatewayTurnPendingRegisteredAt,
						eventAt:      entry.gatewayTurnPendingAt,
					},
					turnStartedAt,
				)
			if pendingOwned {
				t.setGatewayOwnedTurnClaim(
					entry.metaThreadID,
					turnID,
					entry.gatewayTurnPendingAt,
				)
			}
			entry.gatewayOwned = pendingOwned ||
				t.hasGatewayOwnedTurnClaim(entry.metaThreadID, turnID)
			// 全量重扫会先经过历史 turn，不能让历史 task_started 删除时间更晚的
			// 持久化 claim。只有时间上不早于 claim 的不同 turn 才能证明控制边界
			// 已前进；没有 exact claim 的新 Mac turn 仍会恢复 external 只读保护。
			t.removeSupersededGatewayOwnedTurnClaims(
				entry.metaThreadID,
				turnID,
				turnStartedAt,
			)
			clearGatewayTurnPending(entry)
		case "task_complete", "turn_aborted":
			terminalTurnID := turnID
			if terminalTurnID == "" {
				terminalTurnID = entry.turnID
			}
			t.removeGatewayOwnedTurnClaim(entry.metaThreadID, terminalTurnID)
			// 旧 turn 的迟到 terminal 不能终止已经开始的新 turn。
			if turnID == "" || entry.turnID == "" || turnID == entry.turnID {
				entry.active = false
				entry.turnID = ""
				entry.turnStartedAt = time.Time{}
				entry.gatewayOwned = false
				clearGatewayTurnPending(entry)
			}
		}
	}
}

func clearGatewayTurnPending(entry *externalRolloutCacheEntry) {
	entry.gatewayTurnPending = false
	entry.gatewayTurnPendingAt = time.Time{}
	entry.gatewayTurnPendingRegisteredAt = time.Time{}
}

func expireGatewayTurnPending(entry *externalRolloutCacheEntry, now time.Time) bool {
	if !entry.gatewayTurnPending {
		return false
	}
	if !entry.gatewayTurnPendingAt.IsZero() &&
		!now.After(entry.gatewayTurnPendingAt.Add(gatewayTurnLifecycleWindow)) {
		return false
	}
	clearGatewayTurnPending(entry)
	return true
}

func (t *ExternalActivityTracker) consumeGatewayTurnRegistration(
	threadID string,
	clientUserMessageID string,
	rawTimestamp string,
) (gatewayTurnEvidence, bool) {
	threadID = strings.TrimSpace(threadID)
	clientUserMessageID = strings.TrimSpace(clientUserMessageID)
	rawTimestamp = strings.TrimSpace(rawTimestamp)
	if threadID == "" || clientUserMessageID == "" || rawTimestamp == "" {
		return gatewayTurnEvidence{}, false
	}
	eventAt, ok := parseExternalRolloutTimestamp(rawTimestamp)
	if !ok {
		return gatewayTurnEvidence{}, false
	}
	key := gatewayTurnRegistrationKey(threadID, clientUserMessageID)
	registration, ok := t.gatewayTurns[key]
	if !ok {
		return gatewayTurnEvidence{}, false
	}
	// 同一个 client id 只能消费一次。即使时间校验失败也删除，避免恶意或损坏
	// rollout 在稍后的重复行中重新尝试命中。
	delete(t.gatewayTurns, key)
	t.gatewayClaimsDirty = true
	if eventAt.Before(registration.registeredAt.Add(-gatewayTurnEventClockSkew)) {
		return gatewayTurnEvidence{}, false
	}
	if eventAt.After(registration.registeredAt.Add(gatewayTurnRegistrationTTL)) {
		return gatewayTurnEvidence{}, false
	}
	return gatewayTurnEvidence{
		registeredAt: registration.registeredAt,
		eventAt:      eventAt,
	}, true
}

func parseExternalRolloutTimestamp(rawTimestamp string) (time.Time, bool) {
	eventAt, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(rawTimestamp))
	if err != nil {
		return time.Time{}, false
	}
	return eventAt.UTC(), true
}

func gatewayTurnEvidenceMatchesTaskStart(evidence gatewayTurnEvidence, turnStartedAt time.Time) bool {
	if evidence.registeredAt.IsZero() || evidence.eventAt.IsZero() || turnStartedAt.IsZero() {
		return false
	}
	if turnStartedAt.Before(evidence.registeredAt.Add(-gatewayTurnEventClockSkew)) ||
		turnStartedAt.After(evidence.registeredAt.Add(gatewayTurnStartWindow)) {
		return false
	}
	delta := turnStartedAt.Sub(evidence.eventAt)
	if delta < 0 {
		delta = -delta
	}
	return delta <= gatewayTurnLifecycleWindow
}

func (t *ExternalActivityTracker) pruneGatewayTurnRegistrations(now time.Time) {
	for key, registration := range t.gatewayTurns {
		if now.After(registration.registeredAt.Add(gatewayTurnRegistrationTTL)) {
			delete(t.gatewayTurns, key)
			t.gatewayClaimsDirty = true
		}
	}
}

func gatewayTurnRegistrationKey(threadID string, clientUserMessageID string) string {
	return strings.TrimSpace(threadID) + "\x00" + strings.TrimSpace(clientUserMessageID)
}

func externalActivityRevision(info os.FileInfo) string {
	return strconv.FormatInt(info.Size(), 36) + "-" + strconv.FormatInt(info.ModTime().UnixNano(), 36)
}

func isTopLevelExternalThreadSource(source string) bool {
	source = strings.ToLower(strings.TrimSpace(source))
	return source == "" || source == "user"
}
