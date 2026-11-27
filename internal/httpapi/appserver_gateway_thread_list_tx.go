package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

type upstreamFrameDecision struct {
	forwardPayload []byte
	forward        bool
	policyErr      *appServerGatewayPolicyError
	targetSinkGen  uint64
	releasePins    func(grace time.Duration)
}

type threadListRequestBinding struct {
	key               string
	frameID           *json.RawMessage
	pendingThread     appServerGatewayPendingThreadRequest
	pendingHistory    *appServerGatewayPendingHistoryRequest
	envelopeMalformed *appServerGatewayPolicyError
}

type upstreamResponseClaim struct {
	dropReason        string // "" | "closed" | "late" | "unmatched" | "sink_replaced"
	droppedPending    appServerGatewayPendingThreadRequest
	clientRequest     appServerGatewayPendingClientRequest
	hasClientRequest  bool
	pendingHistory    appServerGatewayPendingHistoryRequest
	hasPendingHistory bool
	threadListBinding *threadListRequestBinding
	// validThreadListRPCError 表示命中在途 thread/list 的合法 JSON-RPC 错误帧，已按 pendingSeq 清理原绑定。
	validThreadListRPCError bool
	targetSinkGen           uint64
}

// claimUpstreamResponse 在单一 p.mu 临界区内（且在获锁之后才取 now）完成：
// 1) 识别完整信封（含 ID-only、result+error、error:null、合法 RPC error）；
// 2) 清理已回包的过期原条目；
// 3) 对在途 thread/list 原子构造不可变 threadListBinding；
// 4) 解锁后释放已摘除的 pendingHistory inflight 与 managed lease（严禁持 p.mu 调 cleanupMu/monitor.mu）。
func (p *appServerGatewayPolicy) claimUpstreamResponse(payload []byte, frame *appServerGatewayFrame) upstreamResponseClaim {
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return upstreamResponseClaim{}
	}

	// 精确检测顶层 result / error 键是否存在（区分 null 与缺键）。
	hasResultKey := len(bytes.TrimSpace(frame.Result)) > 0
	hasErrorKey := len(bytes.TrimSpace(frame.Error)) > 0
	var topLevel map[string]json.RawMessage
	if json.Unmarshal(payload, &topLevel) == nil {
		_, hasResultKey = topLevel["result"]
		_, hasErrorKey = topLevel["error"]
	}

	var historyToRelease *appServerGatewayPendingHistoryRequest
	var managedLeaseToRelease string

	p.mu.Lock()
	now := p.now()
	p.prunePendingClientRequestsLocked(now)
	p.prunePendingThreadsLocked(now)
	p.pruneHistoryLocked(now)

	clientReq, tracked := p.pendingClientRequests[key]
	if tracked {
		delete(p.pendingClientRequests, key)
	}
	pendingThread, hasPendingThread := p.pendingThreads[key]
	pendingHistory, hasPendingHistory := p.pendingHistory[key]

	// 优先处理命中在途 thread/list 的所有信封形态（含 ID-only、result+error、error:null、合法 RPC error）。
	if hasPendingThread && pendingThread.method == "thread/list" {
		if hasPendingHistory {
			delete(p.pendingHistory, key)
			h := pendingHistory
			historyToRelease = &h
		}
		sinkMismatch := pendingThread.clientSinkGen != 0 && p.activeSinkGen() != pendingThread.clientSinkGen
		if p.closed || pendingThread.expired || sinkMismatch {
			if pendingThread.managedWorktreePath != "" {
				delete(p.pendingThreads, key)
				managedLeaseToRelease = pendingThread.managedWorktreePath
			} else {
				delete(p.pendingThreads, key)
			}
			dropReason := "late"
			if p.closed {
				dropReason = "closed"
			} else if sinkMismatch {
				dropReason = "sink_replaced"
			}
			p.mu.Unlock()
			if historyToRelease != nil {
				p.releaseHistoryInflight(*historyToRelease)
			}
			if managedLeaseToRelease != "" && p.router != nil {
				p.router.releaseManagedWorktreePendingUse(managedLeaseToRelease)
			}
			return upstreamResponseClaim{
				dropReason:       dropReason,
				droppedPending:   pendingThread,
				clientRequest:    clientReq,
				hasClientRequest: tracked,
			}
		}

		// 1) 合法 JSON-RPC error：仅有 error 键且为合法 {code: int, message: string} 对象。
		if hasErrorKey && !hasResultKey && isValidJSONRPCErrorObject(frame.Error) {
			delete(p.pendingThreads, key)
			if pendingThread.managedWorktreePath != "" {
				managedLeaseToRelease = pendingThread.managedWorktreePath
			}
			targetGen := pendingThread.clientSinkGen
			p.mu.Unlock()
			if historyToRelease != nil {
				p.releaseHistoryInflight(*historyToRelease)
			}
			if managedLeaseToRelease != "" && p.router != nil {
				p.router.releaseManagedWorktreePendingUse(managedLeaseToRelease)
			}
			return upstreamResponseClaim{
				clientRequest:           clientReq,
				hasClientRequest:        tracked,
				pendingHistory:          pendingHistory,
				hasPendingHistory:       hasPendingHistory,
				validThreadListRPCError: true,
				targetSinkGen:           targetGen,
			}
		}

		// 2) 非法信封：同时含 result 与 error 键、既无 result 也无 error（ID-only）、或仅有非法 error（如 error:null / 缺 code/message）。
		var envelopeErr *appServerGatewayPolicyError
		if hasResultKey && hasErrorKey {
			envelopeErr = malformedThreadListPolicyError(frame.ID, "thread/list 响应不能同时包含 result 与 error 字段")
		} else if !hasResultKey && !hasErrorKey {
			envelopeErr = malformedThreadListPolicyError(frame.ID, "thread/list 响应缺少 result 或 error 字段")
		} else if hasErrorKey {
			envelopeErr = malformedThreadListPolicyError(frame.ID, "thread/list 错误响应缺少合法整数 code 或字符串 message")
		}

		var histCopy *appServerGatewayPendingHistoryRequest
		if historyToRelease != nil {
			h := *historyToRelease
			histCopy = &h
		}
		binding := &threadListRequestBinding{
			key:               key,
			frameID:           frame.ID,
			pendingThread:     pendingThread,
			pendingHistory:    histCopy,
			envelopeMalformed: envelopeErr,
		}
		p.mu.Unlock()
		if historyToRelease != nil {
			p.releaseHistoryInflight(*historyToRelease)
		}
		return upstreamResponseClaim{
			clientRequest:     clientReq,
			hasClientRequest:  tracked,
			pendingHistory:    pendingHistory,
			hasPendingHistory: hasPendingHistory,
			threadListBinding: binding,
			targetSinkGen:     pendingThread.clientSinkGen,
		}
	}

	// 非 thread/list 帧：若既无 result 也无 error 则不是标准 JSON-RPC 响应。
	if !hasResultKey && !hasErrorKey {
		p.mu.Unlock()
		return upstreamResponseClaim{}
	}

	// 非 thread/list 错误响应沿用原路径。
	if hasErrorKey && !bytes.Equal(bytes.TrimSpace(frame.Error), []byte("null")) {
		if hasPendingHistory {
			delete(p.pendingHistory, key)
			h := pendingHistory
			historyToRelease = &h
		}
		p.mu.Unlock()
		if historyToRelease != nil {
			p.releaseHistoryInflight(*historyToRelease)
		}
		return upstreamResponseClaim{
			clientRequest:     clientReq,
			hasClientRequest:  tracked,
			pendingHistory:    pendingHistory,
			hasPendingHistory: hasPendingHistory,
		}
	}

	// 非 thread/list 成功响应：在持锁取时的同一临界区判断 closed / late / unmatched。
	if p.closed {
		if hasPendingHistory {
			delete(p.pendingHistory, key)
			h := pendingHistory
			historyToRelease = &h
		}
		p.mu.Unlock()
		if historyToRelease != nil {
			p.releaseHistoryInflight(*historyToRelease)
		}
		return upstreamResponseClaim{dropReason: "closed"}
	}
	if hasPendingThread {
		if pendingThread.expired {
			if pendingThread.managedWorktreePath == "" {
				delete(p.pendingThreads, key)
			}
			if hasPendingHistory {
				delete(p.pendingHistory, key)
				h := pendingHistory
				historyToRelease = &h
			}
			p.mu.Unlock()
			if historyToRelease != nil {
				p.releaseHistoryInflight(*historyToRelease)
			}
			return upstreamResponseClaim{
				dropReason:       "late",
				droppedPending:   pendingThread,
				clientRequest:    clientReq,
				hasClientRequest: tracked,
			}
		}
		if hasPendingHistory {
			delete(p.pendingHistory, key)
			h := pendingHistory
			historyToRelease = &h
		}
		p.mu.Unlock()
		if historyToRelease != nil {
			p.releaseHistoryInflight(*historyToRelease)
		}
		return upstreamResponseClaim{
			clientRequest:     clientReq,
			hasClientRequest:  tracked,
			pendingHistory:    pendingHistory,
			hasPendingHistory: hasPendingHistory,
		}
	}
	if hasPendingHistory {
		delete(p.pendingHistory, key)
		h := pendingHistory
		historyToRelease = &h
		p.mu.Unlock()
		p.releaseHistoryInflight(*historyToRelease)
		return upstreamResponseClaim{
			clientRequest:     clientReq,
			hasClientRequest:  tracked,
			pendingHistory:    pendingHistory,
			hasPendingHistory: true,
		}
	}
	p.mu.Unlock()

	if tracked && clientReq.expired {
		return upstreamResponseClaim{
			dropReason:       "late",
			droppedPending:   appServerGatewayPendingThreadRequest{method: clientReq.method, createdAt: clientReq.createdAt},
			clientRequest:    clientReq,
			hasClientRequest: tracked,
		}
	}
	if !tracked {
		return upstreamResponseClaim{dropReason: "unmatched"}
	}
	return upstreamResponseClaim{clientRequest: clientReq, hasClientRequest: tracked}
}

// recheckOrCleanThreadListBindingLocked 要求调用方已持有 p.mu（不持有 gatewayThreadsMu 以外叶锁的写操作）。
// 验证原绑定 pendingSeq、未关闭、未过期且 broker sink 代次仍活跃；
// 若已过期或 sink 换代且仍为同一原绑定，当场清理该原条目（绝不误删同 ID 新 pending）。
func (p *appServerGatewayPolicy) recheckOrCleanThreadListBindingLocked(
	binding threadListRequestBinding,
	now time.Time,
	cleanupMuHeld bool,
) bool {
	p.prunePendingThreadsLocked(now)
	current, ok := p.pendingThreads[binding.key]
	sameBinding := ok &&
		current.pendingSeq == binding.pendingThread.pendingSeq &&
		current.createdAt == binding.pendingThread.createdAt &&
		current.managedWorktreePath == binding.pendingThread.managedWorktreePath &&
		current.clientSinkGen == binding.pendingThread.clientSinkGen
	sinkInvalid := binding.pendingThread.clientSinkGen != 0 && p.activeSinkGen() != binding.pendingThread.clientSinkGen
	if p.closed || !sameBinding || current.expired || sinkInvalid {
		if sameBinding && (current.expired || sinkInvalid) {
			if current.managedWorktreePath == "" {
				delete(p.pendingThreads, binding.key)
			} else if cleanupMuHeld && p.router != nil {
				delete(p.pendingThreads, binding.key)
				p.router.releaseManagedWorktreePendingUseLocked(current.managedWorktreePath)
			}
		}
		return false
	}
	return true
}

type threadListStageACandidate struct {
	sourceIndex                     int
	itemFields                      map[string]json.RawMessage
	wire                            appServerGatewayThreadWire
	threadID                        string
	scope                           gatewayScope
	managedDep                      *managedWorktreeDependency
	ancestorObjectIDs               map[string]struct{}
	underManagedRoot                bool
	resolvedProjectID               string
	syntheticAgyMissingBrowseProj   bool
	syntheticProject                projects.Project
	readOnlyBrowseScope             bool
	relatedThreads                  []appServerGatewayAllowedThread
	statusRaw                       json.RawMessage
}

type threadListStageACandidates struct {
	worktreeLifecycleEpoch uint64
	canonicalBrowseRoots   []string
	managedRoot            string
	responseEnvelope       map[string]json.RawMessage
	resultFields           map[string]json.RawMessage
	upstreamListMeta       map[string]any
	hasUpstreamListMeta    bool
	hasNextCursor          bool
	rawNextCursor          string
	trimmedNextCursor      string
	incomplete             bool
	preGeneratedToken      string
	limit                  int64
	candidates             []threadListStageACandidate
	writerHolders          gatewayWriterHoldersSnapshot
	anchorRealPath         string
	anchorDep              *managedWorktreeDependency
	anchorAncestorObjIDs   map[string]struct{}
	anchorUnderManagedRoot bool
	anchorInvalidated      bool
}

// gatewayReadOnlyScopeForThreadListStageA 专供 thread/list 阶段 A 使用的 100% 纯只读作用域解析器：
// - 严禁调用 gatewayScopeForPath / managedWorktreeForPathLocked / touchManagedWorktreeAt / migrateLegacyManagedWorktree；
// - 项目匹配改用 FindByCanonicalPathInMemory / GetCached（零刷新、零写入/淘汰 pathMatchCache）；
// - 独立采集托管 checkout 生命周期依赖（即使被已登记项目优先命中）与祖先固化对象身份；
// - 当 disallowMissingFallback == true（并发删盘重跑）时，在进入 canonicalMissingPath 之前直接返回 ok=false。
func (r *Router) gatewayReadOnlyScopeForThreadListStageA(
	raw string,
	managedRoot string,
	disallowMissingFallback bool,
) (scope gatewayScope, dep *managedWorktreeDependency, ancestorObjIDs map[string]struct{}, underManagedRoot bool, ok bool) {
	path := strings.TrimSpace(raw)
	if path == "" || r == nil {
		return gatewayScope{}, nil, nil, false, false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return gatewayScope{}, nil, nil, false, false
	}
	realPath, evalErr := filepath.EvalSymlinks(abs)
	if evalErr == nil {
		cleanReal := filepath.Clean(realPath)
		ancestorObjIDs = captureAncestorObjectIDs(cleanReal)
		if managedRoot != "" && (realPathWithin(managedRoot, cleanReal) || exactPathWithin(managedRoot, cleanReal)) {
			underManagedRoot = true
		}
		// 独立探测托管 checkout 生命周期依赖（仅用于收紧复验，绝不扩大正向授权）。
		dep, _ = r.probeManagedWorktreeLifecycleDepStageA(cleanReal, ancestorObjIDs)

		if project, found := r.projects.FindByCanonicalPathInMemory(cleanReal); found {
			return gatewayScope{id: project.ID, realPath: cleanReal, project: project}, dep, ancestorObjIDs, underManagedRoot, true
		}
		if wt, found := r.probeManagedWorktreeForThreadListStageA(cleanReal); found {
			if dep == nil {
				dep = &managedWorktreeDependency{path: wt.Path, instanceGen: wt.InstanceGen}
			}
			return gatewayScope{
				id:       workspaceIDForRealPath(wt.Path),
				realPath: cleanReal,
				project:  wt.RootProject,
				managed:  true,
			}, dep, ancestorObjIDs, underManagedRoot, true
		}
		if r.realPathInBrowseRoots(cleanReal) {
			return gatewayScope{id: workspaceIDForRealPath(cleanReal), realPath: cleanReal, browse: true}, dep, ancestorObjIDs, underManagedRoot, true
		}
		return gatewayScope{}, dep, ancestorObjIDs, underManagedRoot, false
	}

	// 目录不存在：若处于并发删盘重跑（attempt >= 1），一律禁用 missing:true 回退。
	if disallowMissingFallback {
		return gatewayScope{}, nil, nil, false, false
	}
	canonicalMissing, missingOK := canonicalMissingPath(abs)
	if !missingOK {
		return gatewayScope{}, nil, nil, false, false
	}
	if managedRoot != "" && (realPathWithin(managedRoot, canonicalMissing) || exactPathWithin(managedRoot, canonicalMissing)) {
		underManagedRoot = true
	}
	if project, found := r.projects.FindByCanonicalPathInMemory(canonicalMissing); found {
		return gatewayScope{
			id:       project.ID,
			realPath: canonicalMissing,
			project:  project,
			missing:  true,
		}, nil, nil, underManagedRoot, true
	}
	if r.realPathInBrowseRoots(canonicalMissing) {
		return gatewayScope{
			id:       workspaceIDForRealPath(canonicalMissing),
			realPath: canonicalMissing,
			browse:   true,
			missing:  true,
		}, nil, nil, underManagedRoot, true
	}
	return gatewayScope{}, nil, nil, underManagedRoot, false
}

func (r *Router) canonicalBrowseRootsSnapshot() []string {
	if r == nil || len(r.cfg.BrowseRoots) == 0 {
		return nil
	}
	out := make([]string, 0, len(r.cfg.BrowseRoots))
	for _, root := range r.cfg.BrowseRoots {
		value := strings.TrimSpace(root)
		if value == "" {
			continue
		}
		abs, err := filepath.Abs(value)
		if err != nil {
			continue
		}
		realRoot, err := filepath.EvalSymlinks(abs)
		if err != nil {
			continue
		}
		out = append(out, filepath.Clean(realRoot))
	}
	return out
}

func realPathWithinAny(roots []string, target string) bool {
	for _, root := range roots {
		if realPathWithin(root, target) {
			return true
		}
	}
	return false
}

func generateRandomGlobalListToken() (string, error) {
	raw := make([]byte, 18)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("生成 thread/list 安全 cursor 失败")
	}
	return "mimi_" + base64.RawURLEncoding.EncodeToString(raw), nil
}

// prepareThreadListStageA 100% 纯只读阶段 A：零授权写入、零 forgetPending、零 lastSeen 刷新、零磁盘写盘。
func (p *appServerGatewayPolicy) prepareThreadListStageA(
	payload []byte,
	frame appServerGatewayFrame,
	binding threadListRequestBinding,
	attempt int,
	disallowMissingFallback bool,
) (threadListStageACandidates, *appServerGatewayPolicyError) {
	var stageA threadListStageACandidates
	if p.router != nil {
		stageA.worktreeLifecycleEpoch = p.router.managedWorktreeLifecycleEpoch.Load()
		stageA.canonicalBrowseRoots = p.router.canonicalBrowseRootsSnapshot()
		if root, err := p.router.managedWorktreeCheckoutsRoot(); err == nil && strings.TrimSpace(root) != "" {
			stageA.managedRoot = canonicalPathBestEffort(root)
		}
	}

	var response map[string]json.RawMessage
	if err := json.Unmarshal(payload, &response); err != nil {
		return stageA, malformedThreadListPolicyError(frame.ID, "thread/list response 无效")
	}
	var resultFields map[string]json.RawMessage
	if raw := response["result"]; len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &resultFields) != nil {
		return stageA, malformedThreadListPolicyError(frame.ID, "thread/list response.result 必须是对象")
	}
	dataRaw, ok := resultFields["data"]
	if !ok || bytes.Equal(bytes.TrimSpace(dataRaw), []byte("null")) {
		return stageA, malformedThreadListPolicyError(frame.ID, "thread/list response.data 必须是数组")
	}
	var rawItems []json.RawMessage
	if err := json.Unmarshal(dataRaw, &rawItems); err != nil {
		return stageA, malformedThreadListPolicyError(frame.ID, "thread/list response.data 必须是数组")
	}

	// 无论 Global/Scoped 或 Git 是否未决，阶段 A 无条件严格校验 nextCursor 与 listMeta。
	hasNextCursor, rawNextCursor, trimmedNextCursor, cursorErr := validateThreadListNextCursor(resultFields)
	if cursorErr != nil {
		return stageA, malformedThreadListPolicyError(frame.ID, cursorErr.Error())
	}
	sanitizedMeta, hasMeta, metaErr := sanitizeThreadListMeta(resultFields["listMeta"])
	if metaErr != nil {
		return stageA, malformedThreadListPolicyError(frame.ID, metaErr.Error())
	}

	stageA.responseEnvelope = response
	stageA.resultFields = resultFields
	stageA.upstreamListMeta = sanitizedMeta
	stageA.hasUpstreamListMeta = hasMeta
	stageA.hasNextCursor = hasNextCursor
	stageA.rawNextCursor = rawNextCursor
	stageA.trimmedNextCursor = trimmedNextCursor

	limit := int64(appServerGatewayThreadListMaxLimit)
	if binding.pendingThread.responseLimitSet {
		limit = binding.pendingThread.responseLimit
	}
	if limit <= 0 || limit > appServerGatewayThreadListMaxLimit {
		limit = appServerGatewayThreadListMaxLimit
	}
	stageA.limit = limit

	if binding.pendingThread.globalDiscovery {
		return p.prepareGlobalThreadListStageA(stageA, rawItems, frame, binding, attempt, disallowMissingFallback)
	}
	return p.prepareScopedThreadListStageA(stageA, rawItems, frame, binding, attempt, disallowMissingFallback)
}

func (p *appServerGatewayPolicy) prepareGlobalThreadListStageA(
	stageA threadListStageACandidates,
	rawItems []json.RawMessage,
	frame appServerGatewayFrame,
	binding threadListRequestBinding,
	attempt int,
	disallowMissingFallback bool,
) (threadListStageACandidates, *appServerGatewayPolicyError) {
	type rawGlobalEntry struct {
		sourceIndex      int
		itemFields       map[string]json.RawMessage
		wire             appServerGatewayThreadWire
		threadID         string
		scope            gatewayScope
		dep              *managedWorktreeDependency
		ancestorObjIDs   map[string]struct{}
		underManagedRoot bool
	}

	entries := make([]rawGlobalEntry, 0, len(rawItems))
	var gitPaths []string
	seenGitPaths := map[string]struct{}{}

	for idx, rawItem := range rawItems {
		trimmed := bytes.TrimSpace(rawItem)
		if len(trimmed) == 0 || trimmed[0] != '{' {
			return stageA, malformedThreadListPolicyError(frame.ID, "thread/list data 元素必须是对象")
		}
		var itemFields map[string]json.RawMessage
		if err := json.Unmarshal(trimmed, &itemFields); err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, "thread/list data 元素必须是对象")
		}
		// Global 有意收紧：非字符串类型的 cwd/path 拒绝整页（基线静默跳过）。
		if err := validateOptionalJSONStringField(itemFields, "cwd"); err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, err.Error())
		}
		if err := validateOptionalJSONStringField(itemFields, "path"); err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, err.Error())
		}
		var wire appServerGatewayThreadWire
		if err := json.Unmarshal(trimmed, &wire); err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, "thread/list data 元素结构无效")
		}
		threadIDRaw := firstNonEmptyRaw(wire.ID, wire.ThreadID, wire.SessionID)
		threadID := strings.TrimSpace(threadIDRaw)
		if threadID == "" || threadID != threadIDRaw {
			return stageA, malformedThreadListPolicyError(frame.ID, "thread/list data 元素缺少合法非空 id")
		}
		// 1b-7 Global 兼容语义：双空、首尾空白或相对路径仅裁该单行，不拒整页。
		cwdRaw := firstNonEmptyRaw(wire.CWD, wire.Path)
		cwd := strings.TrimSpace(cwdRaw)
		if cwd == "" || cwd != cwdRaw || !filepath.IsAbs(cwd) {
			continue
		}

		scope, dep, ancestorObjIDs, underManagedRoot, ok := p.router.gatewayReadOnlyScopeForThreadListStageA(cwd, stageA.managedRoot, disallowMissingFallback)
		if p.onStageAAfterPathProbe != nil {
			// 允许测试在候选路径探针后、阶段 B 前注入并发删盘竞态。
			p.onStageAAfterPathProbe(attempt)
		}
		if !ok {
			continue
		}
		if !scope.missing {
			info, statErr := os.Stat(scope.realPath)
			if statErr != nil || !info.IsDir() {
				continue
			}
			if strings.TrimSpace(scope.project.ID) == "" && scope.browse {
				if _, seen := seenGitPaths[scope.realPath]; !seen {
					seenGitPaths[scope.realPath] = struct{}{}
					gitPaths = append(gitPaths, scope.realPath)
				}
			}
		}
		entries = append(entries, rawGlobalEntry{
			sourceIndex:      idx,
			itemFields:       itemFields,
			wire:             wire,
			threadID:         threadID,
			scope:            scope,
			dep:              dep,
			ancestorObjIDs:   ancestorObjIDs,
			underManagedRoot: underManagedRoot,
		})
	}

	ctx, cancel := context.WithTimeout(context.Background(), appServerGatewayGlobalListGitWait)
	defer cancel()
	projectByPath, unsettledPaths := p.resolveGlobalListBrowseProjects(ctx, gitPaths)

	incomplete := false
	candidates := make([]threadListStageACandidate, 0, min(len(entries), int(stageA.limit)))
	var notLoadedIDs []string

	for _, entry := range entries {
		if int64(len(candidates)) >= stageA.limit {
			break
		}
		project := entry.scope.project
		syntheticAgy := false
		if strings.TrimSpace(project.ID) == "" && entry.scope.browse && !entry.scope.missing {
			if _, unsettled := unsettledPaths[entry.scope.realPath]; unsettled {
				incomplete = true
				continue
			}
			project = projectByPath[entry.scope.realPath]
		}
		if strings.TrimSpace(project.ID) == "" {
			if entry.scope.browse && entry.scope.missing && normalizeAppServerRuntimeID(p.runtimeID) == appServerRuntimeAgyID {
				// 1b-7 保留 Agy Global C15 browse-only 缺失目录合成项目 ID 特例。
				project = projects.Project{
					ID:   entry.scope.id,
					Name: filepath.Base(entry.scope.realPath),
					Path: entry.scope.realPath,
				}
				syntheticAgy = true
			} else {
				continue
			}
		}
		statusRaw := entry.itemFields["status"]
		if gatewayThreadStatusIsNotLoaded(statusRaw) {
			notLoadedIDs = append(notLoadedIDs, entry.threadID)
		}
		candidates = append(candidates, threadListStageACandidate{
			sourceIndex:                   entry.sourceIndex,
			itemFields:                    entry.itemFields,
			wire:                          entry.wire,
			threadID:                      entry.threadID,
			scope:                         entry.scope,
			managedDep:                    entry.dep,
			ancestorObjectIDs:             entry.ancestorObjIDs,
			underManagedRoot:              entry.underManagedRoot,
			resolvedProjectID:             project.ID,
			syntheticAgyMissingBrowseProj: syntheticAgy,
			syntheticProject:              project,
			readOnlyBrowseScope:           entry.scope.browse,
			statusRaw:                     statusRaw,
		})
	}

	stageA.incomplete = incomplete
	// 1b-6：Global incomplete==false 且上游返回与本次请求相同的非空游标（未推进）→ 换发 token 前直接拒收。
	if !incomplete && stageA.hasNextCursor &&
		strings.TrimSpace(binding.pendingThread.upstreamCursor) != "" &&
		stageA.trimmedNextCursor == strings.TrimSpace(binding.pendingThread.upstreamCursor) {
		return stageA, stalledThreadListCursorPolicyError(frame.ID, "thread/list 上游返回与请求相同的未推进 nextCursor")
	}

	// 锁外预生成随机不透明游标 token。
	if incomplete || stageA.hasNextCursor {
		token, err := generateRandomGlobalListToken()
		if err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, err.Error())
		}
		stageA.preGeneratedToken = token
	}

	stageA.candidates = candidates
	stageA.writerHolders = p.probeWriterHolders(notLoadedIDs)
	return stageA, nil
}

func (p *appServerGatewayPolicy) prepareScopedThreadListStageA(
	stageA threadListStageACandidates,
	rawItems []json.RawMessage,
	frame appServerGatewayFrame,
	binding threadListRequestBinding,
	attempt int,
	disallowMissingFallback bool,
) (threadListStageACandidates, *appServerGatewayPolicyError) {
	// 核验 Scoped 请求锚点 pending.cwd（独立采集其托管 checkout 依赖与对象身份）。
	if strings.TrimSpace(binding.pendingThread.cwd) != "" {
		anchorScope, anchorDep, anchorObjIDs, anchorUnderRoot, anchorOK := p.router.gatewayReadOnlyScopeForThreadListStageA(
			binding.pendingThread.cwd,
			stageA.managedRoot,
			disallowMissingFallback,
		)
		stageA.anchorRealPath = anchorScope.realPath
		stageA.anchorDep = anchorDep
		stageA.anchorAncestorObjIDs = anchorObjIDs
		stageA.anchorUnderManagedRoot = anchorUnderRoot
		if disallowMissingFallback && !anchorOK {
			stageA.anchorInvalidated = true
		}
	}

	candidates := make([]threadListStageACandidate, 0, len(rawItems))
	var sameRepository *gatewaySameRepository
	defer func() { sameRepository.close() }()
	var notLoadedIDs []string

	for idx, rawItem := range rawItems {
		trimmed := bytes.TrimSpace(rawItem)
		if len(trimmed) == 0 || trimmed[0] != '{' {
			return stageA, malformedThreadListPolicyError(frame.ID, "thread/list data 元素必须是对象")
		}
		var itemFields map[string]json.RawMessage
		if err := json.Unmarshal(trimmed, &itemFields); err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, "thread/list data 元素必须是对象")
		}
		if err := validateOptionalJSONStringField(itemFields, "cwd"); err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, err.Error())
		}
		if err := validateOptionalJSONStringField(itemFields, "path"); err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, err.Error())
		}
		var wire appServerGatewayThreadWire
		if err := json.Unmarshal(trimmed, &wire); err != nil {
			return stageA, malformedThreadListPolicyError(frame.ID, "thread/list data 元素结构无效")
		}
		threadIDRaw := firstNonEmptyRaw(wire.ID, wire.ThreadID, wire.SessionID)
		threadID := strings.TrimSpace(threadIDRaw)
		if threadID == "" || threadID != threadIDRaw {
			return stageA, malformedThreadListPolicyError(frame.ID, "thread/list data 元素缺少合法非空 id")
		}
		if stageA.anchorInvalidated {
			continue
		}

		// 1b-7 Scoped 基线兼容：沿用 firstNonEmpty(item.CWD, item.Path, pending.cwd)（trim + Abs + 作用域回退）。
		cwd := firstNonEmpty(wire.CWD, wire.Path, binding.pendingThread.cwd)
		scope, dep, ancestorObjIDs, underManagedRoot, ok := p.router.gatewayReadOnlyScopeForThreadListStageA(cwd, stageA.managedRoot, disallowMissingFallback)
		if p.onStageAAfterPathProbe != nil {
			p.onStageAAfterPathProbe(attempt)
		}
		if !ok {
			continue
		}
		readOnlyBrowseScope := false
		if binding.pendingThread.scopeID != "" && scope.id != binding.pendingThread.scopeID {
			if scope.missing {
				if stageA.anchorRealPath == "" || !realPathWithin(stageA.anchorRealPath, scope.realPath) {
					continue
				}
			} else {
				if sameRepository == nil {
					sameRepository = newGatewaySameRepository(binding.pendingThread.cwd)
				}
				if !sameRepository.matches(scope.realPath) {
					continue
				}
			}
			readOnlyBrowseScope = scope.browse
		}
		statusRaw := itemFields["status"]
		if gatewayThreadStatusIsNotLoaded(statusRaw) {
			notLoadedIDs = append(notLoadedIDs, threadID)
		}
		related := relatedThreadsForParent(
			receiverThreadIDsFromWireTurns(wire.Turns),
			normalizeAppServerRuntimeID(p.runtimeID),
			scope.realPath,
			scope.id,
		)
		candidates = append(candidates, threadListStageACandidate{
			sourceIndex:         idx,
			itemFields:          itemFields,
			wire:                wire,
			threadID:            threadID,
			scope:               scope,
			managedDep:          dep,
			ancestorObjectIDs:   ancestorObjIDs,
			underManagedRoot:    underManagedRoot,
			resolvedProjectID:   scope.project.ID,
			readOnlyBrowseScope: readOnlyBrowseScope,
			relatedThreads:      related,
			statusRaw:           statusRaw,
		})
	}

	stageA.candidates = candidates
	stageA.writerHolders = p.probeWriterHolders(notLoadedIDs)
	return stageA, nil
}

// processPendingThreadListResponse 驱动完整的两阶段 thread/list 事务（阶段 A 只读 + 阶段 B 持锁原子提交）。
func (p *appServerGatewayPolicy) processPendingThreadListResponse(
	payload []byte,
	frame appServerGatewayFrame,
	binding threadListRequestBinding,
) upstreamFrameDecision {
	if p.onAfterResponseClaim != nil {
		p.onAfterResponseClaim()
	}

	// 信封畸形直接走阶段 B 原绑定复验收口（零预算扣减）。
	if binding.envelopeMalformed != nil {
		return p.finalizeThreadListErrorStageB(binding, binding.envelopeMalformed)
	}

	// 最多 2 次因并发删盘（lifecycleEpoch 变化）触发的锁外重取证（attempt=0,1,2）。
	for stageAAttempt := 0; stageAAttempt <= 2; stageAAttempt++ {
		stageA, stageAErr := p.prepareThreadListStageA(payload, frame, binding, stageAAttempt, stageAAttempt > 0)
		if stageAErr != nil {
			return p.finalizeThreadListErrorStageB(binding, stageAErr)
		}

		decision, needStageAReprobe := p.finalizeThreadListSuccessStageB(binding, stageA, stageAAttempt)
		if !needStageAReprobe {
			return decision
		}
		// 连续 2 次锁外重取证后仍遇并发删盘风暴 → fail-closed 静默丢弃（零授权、零游标、零预算）。
		if stageAAttempt == 2 {
			return p.abortThreadListSilently(binding)
		}
	}
	return p.abortThreadListSilently(binding)
}

func (p *appServerGatewayPolicy) abortThreadListSilently(binding threadListRequestBinding) upstreamFrameDecision {
	cleanupHeld := false
	if p.router != nil && binding.pendingThread.managedWorktreePath != "" {
		p.router.managedWorktreeCleanupMu.Lock()
		cleanupHeld = true
		defer p.router.managedWorktreeCleanupMu.Unlock()
	}
	p.mu.Lock()
	now := p.now()
	if p.recheckOrCleanThreadListBindingLocked(binding, now, cleanupHeld) {
		delete(p.pendingThreads, binding.key)
		if binding.pendingThread.managedWorktreePath != "" && p.router != nil {
			p.router.releaseManagedWorktreePendingUseLocked(binding.pendingThread.managedWorktreePath)
		}
	}
	p.mu.Unlock()
	return upstreamFrameDecision{}
}

func (p *appServerGatewayPolicy) finalizeThreadListErrorStageB(
	binding threadListRequestBinding,
	stageAErr *appServerGatewayPolicyError,
) upstreamFrameDecision {
	cleanupHeld := false
	if p.router != nil && binding.pendingThread.managedWorktreePath != "" {
		p.router.managedWorktreeCleanupMu.Lock()
		cleanupHeld = true
		defer p.router.managedWorktreeCleanupMu.Unlock()
	}
	p.mu.Lock()
	now := p.now()
	if !p.recheckOrCleanThreadListBindingLocked(binding, now, cleanupHeld) {
		p.mu.Unlock()
		return upstreamFrameDecision{}
	}
	delete(p.pendingThreads, binding.key)
	if binding.pendingThread.managedWorktreePath != "" && p.router != nil {
		p.router.releaseManagedWorktreePendingUseLocked(binding.pendingThread.managedWorktreePath)
	}
	p.mu.Unlock()
	errCopy := *stageAErr
	errCopy.targetSinkGen = binding.pendingThread.clientSinkGen
	return upstreamFrameDecision{
		forward:       false,
		policyErr:     &errCopy,
		targetSinkGen: binding.pendingThread.clientSinkGen,
	}
}

type committedThreadListRow struct {
	candidate   threadListStageACandidate
	liveProject projects.Project
	finalThread appServerGatewayAllowedThread
}

// finalizeThreadListSuccessStageB 执行严格遵守全包锁图（cleanupMu → p.mu → 单把叶锁）的阶段 B 提交。
func (p *appServerGatewayPolicy) finalizeThreadListSuccessStageB(
	binding threadListRequestBinding,
	stageA threadListStageACandidates,
	stageAAttempt int,
) (decision upstreamFrameDecision, needStageAReprobe bool) {
	// 1b-1：凡可提交阶段 B 恒取 r.managedWorktreeCleanupMu（锁序最顶层，纯内存微秒级）。
	cleanupHeld := false
	if p.router != nil {
		p.router.managedWorktreeCleanupMu.Lock()
		cleanupHeld = true
	}
	releaseOuter := func() {
		if cleanupHeld {
			p.router.managedWorktreeCleanupMu.Unlock()
			cleanupHeld = false
		}
	}
	defer releaseOuter()

	p.mu.Lock()
	muLocked := true
	releaseMu := func() {
		if muLocked {
			p.mu.Unlock()
			muLocked = false
		}
	}
	defer releaseMu()

	if !p.recheckOrCleanThreadListBindingLocked(binding, p.now(), cleanupHeld) {
		return upstreamFrameDecision{}, false
	}

	// 1) 纯内存托管工作树与删除记录复验（仅短持 managedWorktreesMu，绝不与 gatewayThreadsMu 嵌套）。
	lifecycleChanged := p.router != nil && p.router.managedWorktreeLifecycleEpoch.Load() != stageA.worktreeLifecycleEpoch
	if p.router != nil && !binding.pendingThread.globalDiscovery && !stageA.anchorInvalidated {
		if stageA.anchorDep != nil {
			if _, ok := p.router.verifyManagedWorktreeDepInMemoryLocked(*stageA.anchorDep); !ok {
				stageA.anchorInvalidated = true
			}
		}
		if !stageA.anchorInvalidated && stageA.anchorRealPath != "" {
			matched, floorExceeded := p.router.matchesDeletedOrRevokedManagedWorktreeLocked(
				stageA.anchorRealPath,
				stageA.anchorAncestorObjIDs,
				stageA.worktreeLifecycleEpoch,
			)
			if matched || floorExceeded {
				stageA.anchorInvalidated = true
			} else if lifecycleChanged && (len(stageA.anchorAncestorObjIDs) == 0 || stageA.anchorUnderManagedRoot) {
				// 1b-1 (v21/v23)：代次已变且锚点身份不足或位于托管根未命中精确删除 → 释放锁并在锁外重取证。
				releaseMu()
				releaseOuter()
				return upstreamFrameDecision{}, true
			}
		}
	}

	// 2) Pass 1a：纯内存作用域与项目复验 + 同页严格单调收敛（永不触发 pathRestored）。
	type verifiedRow struct {
		candidate   threadListStageACandidate
		liveProject projects.Project
	}
	verifiedRows := make([]verifiedRow, 0, len(stageA.candidates))
	pageMergedByID := make(map[string]appServerGatewayAllowedThread, len(stageA.candidates))
	runtimeID := normalizeAppServerRuntimeID(p.runtimeID)

	if !stageA.anchorInvalidated {
		for _, cand := range stageA.candidates {
			if p.router != nil {
				if cand.managedDep != nil {
					if _, ok := p.router.verifyManagedWorktreeDepInMemoryLocked(*cand.managedDep); !ok {
						continue
					}
				}
				matched, floorExceeded := p.router.matchesDeletedOrRevokedManagedWorktreeLocked(
					cand.scope.realPath,
					cand.ancestorObjectIDs,
					stageA.worktreeLifecycleEpoch,
				)
				if matched || floorExceeded {
					continue
				}
				if lifecycleChanged && (len(cand.ancestorObjectIDs) == 0 || cand.underManagedRoot) {
					releaseMu()
					releaseOuter()
					return upstreamFrameDecision{}, true
				}
			}

			liveScope, liveProject, scopeStillOK := p.reverifyCandidateScopeInMemoryLocked(
				cand,
				stageA.canonicalBrowseRoots,
				binding.pendingThread.globalDiscovery,
			)
			if !scopeStillOK {
				continue
			}

			isSubagent := strings.TrimSpace(cand.wire.ParentThreadID) != ""
			readOnlyBrowse := cand.readOnlyBrowseScope ||
				(binding.pendingThread.globalDiscovery && liveScope.browse) ||
				(!binding.pendingThread.globalDiscovery && binding.pendingThread.scopeID != "" && liveScope.id != binding.pendingThread.scopeID && liveScope.browse)
			candidateThread := buildAllowedThreadFromWire(
				cand.threadID,
				runtimeID,
				liveScope.realPath,
				liveScope.id,
				cand.itemFields,
				cand.wire,
				isSubagent,
				readOnlyBrowse,
				liveScope.missing,
				false,
			)
			if prev, exists := pageMergedByID[cand.threadID]; exists {
				pageMergedByID[cand.threadID] = mergeSamePageAllowedThread(prev, candidateThread)
			} else {
				pageMergedByID[cand.threadID] = candidateThread
			}
			for _, rel := range cand.relatedThreads {
				if prev, exists := pageMergedByID[rel.id]; exists {
					pageMergedByID[rel.id] = mergeSamePageAllowedThread(prev, rel)
				} else {
					pageMergedByID[rel.id] = rel
				}
			}
			verifiedRows = append(verifiedRows, verifiedRow{
				candidate:   cand,
				liveProject: liveProject,
			})
		}
	}

	// 3) 有界权限基线复验循环（最多 4 次）：消除读基线与最终提交之间跨连接权限漂移。
	redactOnly := binding.pendingHistory != nil && binding.pendingHistory.redactOnly
	for permAttempt := 0; permAttempt < 4; permAttempt++ {
		// Step 3a：短持 gatewayThreadsMu 读取最新权限基线并记录 observedEpoch，立即释放。
		observedEpoch, historicalBaseByID := p.snapshotHistoricalBaselinesLocked(pageMergedByID, runtimeID)

		// Step 3b：不持有任何叶锁计算本页最终权限、构造响应、预备暂存媒体/输出并检查 cap。
		finalThreadByID := make(map[string]appServerGatewayAllowedThread, len(pageMergedByID))
		for id, pageMerged := range pageMergedByID {
			if base, hasBase := historicalBaseByID[id]; hasBase {
				finalThreadByID[id] = mergeCrossPageAllowedThread(base, pageMerged, nil)
			} else {
				finalThreadByID[id] = normalizeAllowedThreadRestrictionBits(pageMerged)
			}
		}

		committed := make([]committedThreadListRow, len(verifiedRows))
		for i, row := range verifiedRows {
			committed[i] = committedThreadListRow{
				candidate:   row.candidate,
				liveProject: row.liveProject,
				finalThread: finalThreadByID[row.candidate.threadID],
			}
		}

		rawForwardPayload, marshalErr := p.buildThreadListResponsePayload(binding, stageA, committed)
		if marshalErr != nil {
			return p.abortLockedWithPolicyError(binding, malformedThreadListPolicyError(binding.frameID, marshalErr.Error()), cleanupHeld), false
		}

		// 暂存模式图片脱敏与大输出脱水（短持 historyMedia.mu / historyOutput.mu，零叶锁嵌套，零写入零淘汰）。
		stagedPayload, mediaRes, outputRes := p.router.stageRedactAndDehydrateThreadListPayload(rawForwardPayload, redactOnly)

		// 记录诊断指标（不扣预算）。
		overHardCap := !redactOnly && appServerGatewayHistoryResponseCapBytes > 0 && len(stagedPayload) > appServerGatewayHistoryResponseCapBytes
		if binding.pendingHistory != nil {
			p.recordHistoryResponseMetrics(binding.pendingHistory.method, len(stagedPayload), overHardCap)
		}
		if overHardCap {
			mediaRes.cancel()
			outputRes.cancel()
			capErr := p.historyResponseTooLargeError(binding.frameID, *binding.pendingHistory, len(stagedPayload))
			return p.abortLockedWithPolicyError(binding, capErr, cleanupHeld), false
		}

		if p.onStageBBeforeFinalCommitLock != nil {
			p.onStageBBeforeFinalCommitLock(permAttempt)
		}

		// Step 3c：唯一提交边界 — 获取 gatewayThreadsMu，取最终 now，复验 TTL、sink 与整份权限基线。
		var finalNow time.Time
		baselineDrifted := false
		bindingDead := false
		if p.router != nil {
			p.router.gatewayThreadsMu.Lock()
			finalNow = p.now()
			if !p.recheckOrCleanThreadListBindingLocked(binding, finalNow, cleanupHeld) {
				bindingDead = true
			} else if p.router.gatewayThreadsMutationEpoch != observedEpoch {
				// 复验整份受影响 ID 的历史基线（含 readOnlyPermanent / explicitDirectInputVersion / pushSeededOnly）。
				p.syncRestrictionEvictionEpochLocked(finalNow)
				for id := range pageMergedByID {
					currBase, hasCurr := p.readSingleHistoricalBaselineLocked(id, runtimeID, finalNow)
					prevBase, hasPrev := historicalBaseByID[id]
					if hasCurr != hasPrev || (hasCurr && !allowedThreadBaselineEqual(currBase, prevBase)) {
						baselineDrifted = true
						break
					}
				}
			}

			if bindingDead || baselineDrifted {
				// 严格先释放 gatewayThreadsMu，绝不持 gatewayThreadsMu 调用其他叶锁！
				p.router.gatewayThreadsMu.Unlock()
				mediaRes.cancel()
				outputRes.cancel()
				if bindingDead {
					return upstreamFrameDecision{}, false
				}
				if permAttempt < 3 {
					continue
				}
				// 4 次冲突耗尽：严格丢弃，绝不发出过时权限帧。
				delete(p.pendingThreads, binding.key)
				if binding.pendingThread.managedWorktreePath != "" {
					p.router.releaseManagedWorktreePendingUseLocked(binding.pendingThread.managedWorktreePath)
				}
				return upstreamFrameDecision{}, false
			}

			if p.onStageBAfterFinalLockBeforeWrite != nil {
				p.onStageBAfterFinalLockBeforeWrite()
			}

			// 不可失败提交点：为含 rawDirectInputDeny 的线程分配新版本号并整页写入全局表与底板。
			allocVer := func() uint64 {
				p.router.nextGatewayThreadDirectInputVersion++
				return p.router.nextGatewayThreadDirectInputVersion
			}
			for id, pageMerged := range pageMergedByID {
				var merged appServerGatewayAllowedThread
				if base, hasBase := historicalBaseByID[id]; hasBase {
					merged = mergeCrossPageAllowedThread(base, pageMerged, allocVer)
				} else {
					merged = normalizeAllowedThreadRestrictionBits(pageMerged)
					merged.pushSeededOnly = false
					if merged.explicitDirectInputDenied || pageMerged.rawDirectInput == rawDirectInputDeny {
						merged.explicitDirectInputDenied = true
						merged.explicitDirectInputVersion = allocVer()
					}
					merged.rawDirectInput = rawDirectInputUnknown
				}
				merged.lastSeen = finalNow
				finalThreadByID[id] = merged

				globalCopy := merged
				globalCopy.autoTitleEligible = false
				if p.router.gatewayThreads == nil {
					p.router.gatewayThreads = map[string]appServerGatewayAllowedThread{}
				}
				cacheKey := gatewayThreadCacheKey(runtimeID, id)
				p.router.gatewayThreads[cacheKey] = globalCopy
				p.router.recordGatewayThreadRestrictionLocked(cacheKey, globalCopy, finalNow)
			}
			p.router.gatewayThreadsMutationEpoch++
			p.router.pruneGatewayThreadsLocked(finalNow)
			// 立即释放 gatewayThreadsMu，保证后续所有叶锁零嵌套！
			p.router.gatewayThreadsMu.Unlock()
		} else {
			finalNow = p.now()
			if !p.recheckOrCleanThreadListBindingLocked(binding, finalNow, cleanupHeld) {
				mediaRes.cancel()
				outputRes.cancel()
				return upstreamFrameDecision{}, false
			}
		}

		// 写入连接级 p.allowedThreads（已在 p.mu 下）。
		for id, merged := range finalThreadByID {
			p.allowedThreads[id] = merged
		}

		// 依次提交暂存媒体/输出缓存（各自短持单一叶锁，绝不嵌套）。
		mediaRelease := mediaRes.commit()
		outputRelease := outputRes.commit()

		// 登记 Global 游标 token（若有）。
		if binding.pendingThread.globalDiscovery && stageA.preGeneratedToken != "" {
			upstreamToStore := ""
			if stageA.incomplete {
				upstreamToStore = strings.TrimSpace(binding.pendingThread.upstreamCursor)
			} else if stageA.hasNextCursor {
				upstreamToStore = stageA.trimmedNextCursor
			}
			if p.globalListCursors == nil || len(p.globalListCursors) >= appServerGatewayGlobalCursorMax {
				p.globalListCursors = map[string]string{}
			}
			p.globalListCursors[stageA.preGeneratedToken] = upstreamToStore
		}

		// 删除原 pending 并释放 managed lease（已在 cleanupMu → p.mu 下）。
		delete(p.pendingThreads, binding.key)
		if binding.pendingThread.managedWorktreePath != "" && p.router != nil {
			p.router.releaseManagedWorktreePendingUseLocked(binding.pendingThread.managedWorktreePath)
		}

		// 仅在最终确定转发的提交点记录连接级预算、P1-3c 续页资格与全局预算。
		var histForGlobal *appServerGatewayPendingHistoryRequest
		if binding.pendingHistory != nil && !binding.pendingHistory.redactOnly {
			hist := *binding.pendingHistory
			p.recordHistoryResponseBudgetLocked(hist, len(stagedPayload), finalNow)
			// P1-3c：仅当非同页重试、存在前进游标且表未满 512 时登记免计次续页资格。
			if !stageA.incomplete && stageA.hasNextCursor &&
				stageA.trimmedNextCursor != "" &&
				stageA.trimmedNextCursor != strings.TrimSpace(hist.cursor) {
				p.pruneHistoryContinuationsLocked(finalNow)
				if p.historyContinuations == nil {
					p.historyContinuations = map[string]time.Time{}
				}
				if len(p.historyContinuations) < appServerGatewayHistoryContinuationMax {
					p.historyContinuations[gatewayHistoryContinuationKey(hist, stageA.trimmedNextCursor)] = finalNow.Add(appServerGatewayPendingHistoryRequestTTL)
				}
			}
			histForGlobal = &hist
		}

		// 沿既有锁序 p.mu → gatewayHistoryBudgetMu 记全局预算。
		if histForGlobal != nil && p.router != nil {
			p.router.recordHistoryGlobalResponseBudget(*histForGlobal, len(stagedPayload))
		}

		releaseMu()
		releaseOuter()

		var combinedRelease func(grace time.Duration)
		if mediaRelease != nil || outputRelease != nil {
			combinedRelease = func(grace time.Duration) {
				if mediaRelease != nil {
					mediaRelease(grace)
				}
				if outputRelease != nil {
					outputRelease(grace)
				}
			}
		}

		if binding.pendingThread.globalDiscovery && stageA.incomplete {
			log.Printf("app-server gateway global thread/list incomplete runtime=%s returned=%d; client will retry the same page", p.runtimeID, len(committed))
		}
		return upstreamFrameDecision{
			forwardPayload: stagedPayload,
			forward:        true,
			targetSinkGen:  binding.pendingThread.clientSinkGen,
			releasePins:    combinedRelease,
		}, false
	}

	return upstreamFrameDecision{}, false
}

func (p *appServerGatewayPolicy) abortLockedWithPolicyError(
	binding threadListRequestBinding,
	policyErr *appServerGatewayPolicyError,
	cleanupHeld bool,
) upstreamFrameDecision {
	if !p.recheckOrCleanThreadListBindingLocked(binding, p.now(), cleanupHeld) {
		return upstreamFrameDecision{}
	}
	delete(p.pendingThreads, binding.key)
	if binding.pendingThread.managedWorktreePath != "" && p.router != nil {
		p.router.releaseManagedWorktreePendingUseLocked(binding.pendingThread.managedWorktreePath)
	}
	errCopy := *policyErr
	errCopy.targetSinkGen = binding.pendingThread.clientSinkGen
	return upstreamFrameDecision{
		forward:       false,
		policyErr:     &errCopy,
		targetSinkGen: binding.pendingThread.clientSinkGen,
	}
}

func (p *appServerGatewayPolicy) historyResponseTooLargeError(
	id *json.RawMessage,
	pending appServerGatewayPendingHistoryRequest,
	responseBytes int,
) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id:      id,
		message: fmt.Sprintf("%s history response 过大（%d bytes > %d bytes），gateway 已阻断；请降低 limit/itemsView 或改用分页读取", pending.method, responseBytes, appServerGatewayHistoryResponseCapBytes),
		data: gatewayPolicyErrorData("history_response_too_large", appServerGatewayHistoryBudgetWindow, map[string]any{
			"method":           pending.method,
			"threadId":         pending.threadID,
			"cwd":              pending.cwd,
			"itemsView":        pending.itemsView,
			"responseBytes":    responseBytes,
			"maxResponseBytes": appServerGatewayHistoryResponseCapBytes,
		}),
		target:                 "client",
		historyResponseBlocked: true,
	}
}

func (p *appServerGatewayPolicy) snapshotHistoricalBaselinesLocked(
	pageMergedByID map[string]appServerGatewayAllowedThread,
	runtimeID string,
) (uint64, map[string]appServerGatewayAllowedThread) {
	baselines := make(map[string]appServerGatewayAllowedThread, len(pageMergedByID))
	var epoch uint64
	now := p.now()
	if p.router != nil {
		p.router.gatewayThreadsMu.Lock()
		p.syncRestrictionEvictionEpochLocked(now)
		epoch = p.router.gatewayThreadsMutationEpoch
		for id := range pageMergedByID {
			if base, ok := p.readSingleHistoricalBaselineLocked(id, runtimeID, now); ok {
				baselines[id] = base
			}
		}
		p.router.gatewayThreadsMu.Unlock()
		return epoch, baselines
	}
	for id := range pageMergedByID {
		if connOld, ok := p.allowedThreads[id]; ok {
			baselines[id] = normalizeAllowedThreadRestrictionBits(connOld)
		}
	}
	return 0, baselines
}

// readSingleHistoricalBaselineLocked 要求调用方已持有 p.mu 与 r.gatewayThreadsMu。
func (p *appServerGatewayPolicy) readSingleHistoricalBaselineLocked(id string, runtimeID string, now time.Time) (appServerGatewayAllowedThread, bool) {
	connOld, hasConn := p.allowedThreads[id]
	key := gatewayThreadCacheKey(runtimeID, id)
	globalOld, _, hasGlobal := p.router.effectiveGatewayThreadLocked(key, now)
	return mergeHistoricalBaseline(connOld, hasConn, globalOld, hasGlobal)
}

// reverifyCandidateScopeInMemoryLocked 要求调用方已持有 managedWorktreeCleanupMu。
// 100% 纯内存、零磁盘 I/O（仅调用 projects.GetCached / FindByCanonicalPathInMemory / managedWorktreeForPathInMemoryLocked / realPathWithinAny）。
func (p *appServerGatewayPolicy) reverifyCandidateScopeInMemoryLocked(
	cand threadListStageACandidate,
	canonicalBrowseRoots []string,
	isGlobal bool,
) (gatewayScope, projects.Project, bool) {
	if p.router == nil {
		return cand.scope, cand.scope.project, true
	}

	// Agy Global C15 browse-only 缺失目录合成项目 ID 特例。
	if isGlobal && cand.syntheticAgyMissingBrowseProj {
		if !realPathWithinAny(canonicalBrowseRoots, cand.scope.realPath) {
			return gatewayScope{}, projects.Project{}, false
		}
		return cand.scope, cand.syntheticProject, true
	}

	// 1) 若候选属于托管工作树（非项目优先）：纯内存复验托管工作树及根项目。
	if cand.scope.managed {
		if wt, ok := p.router.managedWorktreeForPathInMemoryLocked(cand.scope.realPath); ok {
			liveScope := gatewayScope{
				id:       workspaceIDForRealPath(wt.Path),
				realPath: cand.scope.realPath,
				project:  wt.RootProject,
				managed:  true,
			}
			return liveScope, wt.RootProject, true
		}
		// 托管工作树已不可用 → 纯内存回落检查当前项目与 browse_roots。
		if project, found := p.router.projects.FindByCanonicalPathInMemory(cand.scope.realPath); found {
			return gatewayScope{id: project.ID, realPath: cand.scope.realPath, project: project, missing: cand.scope.missing}, project, true
		}
		if realPathWithinAny(canonicalBrowseRoots, cand.scope.realPath) {
			if isGlobal {
				if cand.resolvedProjectID != "" {
					if project, found := p.router.projects.GetCached(cand.resolvedProjectID); found {
						return gatewayScope{id: workspaceIDForRealPath(cand.scope.realPath), realPath: cand.scope.realPath, browse: true, missing: cand.scope.missing}, project, true
					}
				}
				return gatewayScope{}, projects.Project{}, false
			}
			return gatewayScope{id: workspaceIDForRealPath(cand.scope.realPath), realPath: cand.scope.realPath, browse: true, missing: cand.scope.missing}, projects.Project{}, true
		}
		return gatewayScope{}, projects.Project{}, false
	}

	// 2) 若候选原本在项目作用域内：纯内存复验 FindByCanonicalPathInMemory；撤权后按 browse_roots 降级或裁出。
	if !cand.scope.browse {
		if project, found := p.router.projects.FindByCanonicalPathInMemory(cand.scope.realPath); found {
			return gatewayScope{id: project.ID, realPath: cand.scope.realPath, project: project, missing: cand.scope.missing}, project, true
		}
		if realPathWithinAny(canonicalBrowseRoots, cand.scope.realPath) {
			if isGlobal {
				// Global 降级到 browse_roots 仍需归属某已登记项目（纯内存校验）。
				if cand.resolvedProjectID != "" {
					if project, found := p.router.projects.GetCached(cand.resolvedProjectID); found {
						return gatewayScope{id: workspaceIDForRealPath(cand.scope.realPath), realPath: cand.scope.realPath, browse: true, missing: cand.scope.missing}, project, true
					}
				}
				return gatewayScope{}, projects.Project{}, false
			}
			return gatewayScope{id: workspaceIDForRealPath(cand.scope.realPath), realPath: cand.scope.realPath, browse: true, missing: cand.scope.missing}, projects.Project{}, true
		}
		return gatewayScope{}, projects.Project{}, false
	}

	// 3) 若候选原本在 browse_roots 内：先检查是否已升级为项目，否则复验 browse_roots 与 Global 归属项目。
	if project, found := p.router.projects.FindByCanonicalPathInMemory(cand.scope.realPath); found {
		return gatewayScope{id: project.ID, realPath: cand.scope.realPath, project: project, missing: cand.scope.missing}, project, true
	}
	if !realPathWithinAny(canonicalBrowseRoots, cand.scope.realPath) {
		return gatewayScope{}, projects.Project{}, false
	}
	if isGlobal {
		project, found := p.router.projects.GetCached(cand.resolvedProjectID)
		if !found {
			return gatewayScope{}, projects.Project{}, false
		}
		return gatewayScope{id: workspaceIDForRealPath(cand.scope.realPath), realPath: cand.scope.realPath, browse: true, missing: cand.scope.missing}, project, true
	}
	return gatewayScope{id: workspaceIDForRealPath(cand.scope.realPath), realPath: cand.scope.realPath, browse: true, missing: cand.scope.missing}, projects.Project{}, true
}

func (p *appServerGatewayPolicy) buildThreadListResponsePayload(
	binding threadListRequestBinding,
	stageA threadListStageACandidates,
	committed []committedThreadListRow,
) ([]byte, error) {
	if binding.pendingThread.globalDiscovery {
		safeItems := make([]map[string]any, 0, len(committed))
		for _, row := range committed {
			safeThread := copyGatewayRawFields(row.candidate.itemFields,
				"id", "sessionId", "threadId", "parentThreadId", "cwd", "path",
				"name", "preview", "status", "modelProvider", "source", "threadSource",
				"agentNickname", "agentRole", "gitInfo", "createdAt", "updatedAt", "recencyAt",
				"cliVersion",
				"canAcceptDirectInput", "cwdMissing",
				"claudeOwner",
				"spawnedFromThreadId",
			)
			proj := row.liveProject
			applyFinalThreadPermissions(safeThread, row.finalThread, &proj, true)
			applyWriterHolderAnnotationToMap(safeThread, row.candidate.threadID, row.candidate.statusRaw, stageA.writerHolders)
			safeItems = append(safeItems, safeThread)
		}
		safeResult := map[string]any{
			"data":     safeItems,
			"listMeta": buildGlobalThreadListMeta(stageA.upstreamListMeta, stageA.hasUpstreamListMeta, stageA.incomplete),
		}
		if stageA.incomplete || stageA.hasNextCursor {
			safeResult["nextCursor"] = stageA.preGeneratedToken
		} else {
			safeResult["nextCursor"] = nil
		}
		safeResponse := map[string]any{
			"jsonrpc": "2.0",
			"id":      stageA.responseEnvelope["id"],
			"result":  safeResult,
		}
		return json.Marshal(safeResponse)
	}

	// Scoped 响应：直接遍历 committedRows（废除按 ID 回扫原页），保留原始 nextCursor 字节与 backwardsCursor。
	itemsOut := make([]map[string]any, 0, len(committed))
	for _, row := range committed {
		itemMap := make(map[string]any, len(row.candidate.itemFields)+2)
		for k, rawVal := range row.candidate.itemFields {
			var decoded any
			dec := json.NewDecoder(bytes.NewReader(rawVal))
			dec.UseNumber()
			if err := dec.Decode(&decoded); err != nil {
				itemMap[k] = rawVal
				continue
			}
			itemMap[k] = decoded
		}
		applyFinalThreadPermissions(itemMap, row.finalThread, nil, false)
		applyWriterHolderAnnotationToMap(itemMap, row.candidate.threadID, row.candidate.statusRaw, stageA.writerHolders)
		itemsOut = append(itemsOut, itemMap)
	}

	resultOut := make(map[string]json.RawMessage, len(stageA.resultFields))
	for k, v := range stageA.resultFields {
		if k == "data" || k == "listMeta" {
			continue
		}
		// 保留原始 nextCursor 字节、backwardsCursor 及其他分页字段。
		resultOut[k] = v
	}
	dataBytes, err := json.Marshal(itemsOut)
	if err != nil {
		return nil, err
	}
	resultOut["data"] = dataBytes
	if stageA.hasUpstreamListMeta {
		metaBytes, err := json.Marshal(stageA.upstreamListMeta)
		if err != nil {
			return nil, err
		}
		resultOut["listMeta"] = metaBytes
	}
	resultBytes, err := json.Marshal(resultOut)
	if err != nil {
		return nil, err
	}
	responseOut := make(map[string]json.RawMessage, len(stageA.responseEnvelope))
	for k, v := range stageA.responseEnvelope {
		responseOut[k] = v
	}
	responseOut["result"] = resultBytes
	return json.Marshal(responseOut)
}
