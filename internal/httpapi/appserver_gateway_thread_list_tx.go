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
	key                     string
	frameID                 *json.RawMessage
	pendingThread           appServerGatewayPendingThreadRequest
	pendingHistory          *appServerGatewayPendingHistoryRequest
	envelopeMalformed       *appServerGatewayPolicyError
	claimDirectInputVersion uint64
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

		var claimVer uint64
		if p.router != nil {
			p.router.gatewayThreadsMu.Lock()
			p.router.nextGatewayThreadDirectInputVersion++
			claimVer = p.router.nextGatewayThreadDirectInputVersion
			p.router.gatewayThreadsMu.Unlock()
		}
		var histCopy *appServerGatewayPendingHistoryRequest
		if historyToRelease != nil {
			h := *historyToRelease
			histCopy = &h
		}
		binding := &threadListRequestBinding{
			key:                     key,
			frameID:                 frame.ID,
			pendingThread:           pendingThread,
			pendingHistory:          histCopy,
			envelopeMalformed:       envelopeErr,
			claimDirectInputVersion: claimVer,
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
	sourceIndex                   int
	itemFields                    map[string]json.RawMessage
	wire                          appServerGatewayThreadWire
	threadID                      string
	scope                         gatewayScope
	managedDep                    *managedWorktreeDependency
	ancestorObjectIDs             map[string]struct{}
	underManagedRoot              bool
	resolvedProjectID             string
	resolvedProject               projects.Project
	hasStageAResolvedProject      bool
	syntheticAgyMissingBrowseProj bool
	syntheticProject              projects.Project
	readOnlyBrowseScope           bool
	relatedThreads                []appServerGatewayAllowedThread
	statusRaw                     json.RawMessage
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
	usedProjectRoots       map[string]projects.Project
}

// gatewayReadOnlyScopeForThreadListStageA 专供 thread/list 阶段 A 使用的 100% 纯只读作用域解析器：
// - 严禁调用 gatewayScopeForPath / managedWorktreeForPathLocked / touchManagedWorktreeAt / migrateLegacyManagedWorktree；
// - 项目匹配改用 FindByCanonicalPathInMemory / GetCached（零刷新、零写入/淘汰 pathMatchCache）；
// - 独立采集托管 checkout 生命周期依赖（即使被已登记项目优先命中）与祖先固化对象身份；
// - 当 disallowMissingFallback == true（并发删盘重跑）时，在进入 canonicalMissingPath 之前直接返回 ok=false。
type stageAScopeProbeResult struct {
	scope            gatewayScope
	dep              *managedWorktreeDependency
	ancestorObjIDs   map[string]struct{}
	underManagedRoot bool
	ok               bool
}

func (r *Router) gatewayReadOnlyScopeForThreadListStageA(
	raw string,
	managedRoot string,
	disallowMissingFallback bool,
) (scope gatewayScope, dep *managedWorktreeDependency, ancestorObjIDs map[string]struct{}, underManagedRoot bool, ok bool) {
	var refreshed []projects.Project
	if r != nil && r.projects != nil {
		refreshed = r.projects.List()
	}
	res := r.gatewayReadOnlyScopeForThreadListStageAWithSnapshot(raw, managedRoot, disallowMissingFallback, refreshed)
	return res.scope, res.dep, res.ancestorObjIDs, res.underManagedRoot, res.ok
}

func (r *Router) gatewayReadOnlyScopeForThreadListStageAWithSnapshot(
	raw string,
	managedRoot string,
	disallowMissingFallback bool,
	refreshedProjects []projects.Project,
) stageAScopeProbeResult {
	path := strings.TrimSpace(raw)
	if path == "" || r == nil {
		return stageAScopeProbeResult{}
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return stageAScopeProbeResult{}
	}
	realPath, evalErr := filepath.EvalSymlinks(abs)
	if evalErr == nil {
		cleanReal := filepath.Clean(realPath)
		ancestorObjIDs := captureAncestorObjectIDs(cleanReal)
		underManagedRoot := false
		if managedRoot != "" && (realPathWithin(managedRoot, cleanReal) || exactPathWithin(managedRoot, cleanReal)) {
			underManagedRoot = true
		}
		// 独立探测托管 checkout 生命周期依赖（仅用于收紧复验，绝不扩大正向授权）。
		dep, _ := r.probeManagedWorktreeLifecycleDepStageA(cleanReal, ancestorObjIDs)

		// 阶段 A 锁外复用当次刷新快照匹配项目（支持符号链接改指与 Windows \\?\C:\... 归一化，且不写 pathMatchCache）。
		if project, found := projects.MatchCanonicalPathInList(refreshedProjects, cleanReal); found {
			return stageAScopeProbeResult{
				scope:            gatewayScope{id: project.ID, realPath: cleanReal, project: project},
				dep:              dep,
				ancestorObjIDs:   ancestorObjIDs,
				underManagedRoot: underManagedRoot,
				ok:               true,
			}
		}
		if wt, found := r.probeManagedWorktreeForThreadListStageA(cleanReal); found {
			if dep == nil {
				dep = &managedWorktreeDependency{path: wt.Path, instanceGen: wt.InstanceGen}
			}
			return stageAScopeProbeResult{
				scope: gatewayScope{
					id:       workspaceIDForRealPath(wt.Path),
					realPath: cleanReal,
					project:  wt.RootProject,
					managed:  true,
				},
				dep:              dep,
				ancestorObjIDs:   ancestorObjIDs,
				underManagedRoot: underManagedRoot,
				ok:               true,
			}
		}
		if r.realPathInBrowseRoots(cleanReal) {
			return stageAScopeProbeResult{
				scope:            gatewayScope{id: workspaceIDForRealPath(cleanReal), realPath: cleanReal, browse: true},
				dep:              dep,
				ancestorObjIDs:   ancestorObjIDs,
				underManagedRoot: underManagedRoot,
				ok:               true,
			}
		}
		return stageAScopeProbeResult{dep: dep, ancestorObjIDs: ancestorObjIDs, underManagedRoot: underManagedRoot}
	}

	// 目录不存在：若处于并发删盘重跑（attempt >= 1），一律禁用 missing:true 回退。
	if disallowMissingFallback {
		return stageAScopeProbeResult{}
	}
	canonicalMissing, missingOK := canonicalMissingPath(abs)
	if !missingOK {
		return stageAScopeProbeResult{}
	}
	underManagedRoot := false
	if managedRoot != "" && (realPathWithin(managedRoot, canonicalMissing) || exactPathWithin(managedRoot, canonicalMissing)) {
		underManagedRoot = true
	}
	if project, found := r.projects.FindByCanonicalPathInMemory(canonicalMissing); found {
		return stageAScopeProbeResult{
			scope: gatewayScope{
				id:       project.ID,
				realPath: canonicalMissing,
				project:  project,
				missing:  true,
			},
			underManagedRoot: underManagedRoot,
			ok:               true,
		}
	}
	if r.realPathInBrowseRoots(canonicalMissing) {
		return stageAScopeProbeResult{
			scope: gatewayScope{
				id:       workspaceIDForRealPath(canonicalMissing),
				realPath: canonicalMissing,
				browse:   true,
				missing:  true,
			},
			underManagedRoot: underManagedRoot,
			ok:               true,
		}
	}
	return stageAScopeProbeResult{underManagedRoot: underManagedRoot}
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
	var refreshedProjects []projects.Project
	if p.router != nil && p.router.projects != nil {
		// 每次阶段 A 尝试仅刷新一次已配置项目快照，同页所有行共享该快照与目录探针缓存。
		refreshedProjects = p.router.projects.List()
	}
	probeCache := map[string]stageAScopeProbeResult{}
	dirStatCache := map[string]bool{}

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

		res, cached := probeCache[cwd]
		if !cached {
			res = p.router.gatewayReadOnlyScopeForThreadListStageAWithSnapshot(cwd, stageA.managedRoot, disallowMissingFallback, refreshedProjects)
			probeCache[cwd] = res
		}
		if p.onStageAAfterPathProbe != nil {
			// 允许测试在候选路径探针后、阶段 B 前注入并发删盘竞态。
			p.onStageAAfterPathProbe(attempt)
		}
		if !res.ok {
			continue
		}
		scope, dep, ancestorObjIDs, underManagedRoot := res.scope, res.dep, res.ancestorObjIDs, res.underManagedRoot
		if !scope.missing {
			isDir, statCached := dirStatCache[scope.realPath]
			if !statCached {
				info, statErr := os.Stat(scope.realPath)
				isDir = statErr == nil && info.IsDir()
				dirStatCache[scope.realPath] = isDir
			}
			if !isDir {
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
	projectByPath, unsettledPaths := p.resolveGlobalListBrowseProjects(ctx, gitPaths, refreshedProjects)

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
			resolvedProject:               project,
			hasStageAResolvedProject:      strings.TrimSpace(project.ID) != "",
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
	if len(candidates) > 0 {
		stageA.usedProjectRoots = map[string]projects.Project{}
		for _, c := range candidates {
			if c.hasStageAResolvedProject && !c.syntheticAgyMissingBrowseProj && strings.TrimSpace(c.resolvedProjectID) != "" {
				stageA.usedProjectRoots[c.resolvedProjectID] = c.resolvedProject
			}
		}
	}
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
	var refreshedProjects []projects.Project
	if p.router != nil && p.router.projects != nil {
		refreshedProjects = p.router.projects.List()
	}
	probeCache := map[string]stageAScopeProbeResult{}

	// 核验 Scoped 请求锚点 pending.cwd（独立采集其托管 checkout 依赖与对象身份）。
	if strings.TrimSpace(binding.pendingThread.cwd) != "" {
		anchorRes := p.router.gatewayReadOnlyScopeForThreadListStageAWithSnapshot(
			binding.pendingThread.cwd,
			stageA.managedRoot,
			disallowMissingFallback,
			refreshedProjects,
		)
		probeCache[binding.pendingThread.cwd] = anchorRes
		stageA.anchorRealPath = anchorRes.scope.realPath
		stageA.anchorDep = anchorRes.dep
		stageA.anchorAncestorObjIDs = anchorRes.ancestorObjIDs
		stageA.anchorUnderManagedRoot = anchorRes.underManagedRoot
		if disallowMissingFallback && !anchorRes.ok {
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
		res, cached := probeCache[cwd]
		if !cached {
			res = p.router.gatewayReadOnlyScopeForThreadListStageAWithSnapshot(cwd, stageA.managedRoot, disallowMissingFallback, refreshedProjects)
			probeCache[cwd] = res
		}
		if p.onStageAAfterPathProbe != nil {
			p.onStageAAfterPathProbe(attempt)
		}
		if !res.ok {
			continue
		}
		scope, dep, ancestorObjIDs, underManagedRoot := res.scope, res.dep, res.ancestorObjIDs, res.underManagedRoot
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
			sourceIndex:              idx,
			itemFields:               itemFields,
			wire:                     wire,
			threadID:                 threadID,
			scope:                    scope,
			managedDep:               dep,
			ancestorObjectIDs:        ancestorObjIDs,
			underManagedRoot:         underManagedRoot,
			resolvedProjectID:        scope.project.ID,
			resolvedProject:          scope.project,
			hasStageAResolvedProject: strings.TrimSpace(scope.project.ID) != "",
			readOnlyBrowseScope:      readOnlyBrowseScope,
			relatedThreads:           related,
			statusRaw:                statusRaw,
		})
	}

	stageA.candidates = candidates
	if len(candidates) > 0 {
		stageA.usedProjectRoots = map[string]projects.Project{}
		for _, c := range candidates {
			if c.hasStageAResolvedProject && !c.syntheticAgyMissingBrowseProj && strings.TrimSpace(c.resolvedProjectID) != "" {
				stageA.usedProjectRoots[c.resolvedProjectID] = c.resolvedProject
			}
		}
	}
	stageA.writerHolders = p.probeWriterHolders(notLoadedIDs)
	return stageA, nil
}

// projectRootsDriftedOutsideLock 仅在提交锁外复核本页阶段 A 实际使用过的项目根目录，
// 防止扫描同页期间配置符号链接改指后仍将旧目标目录写入新鲜授权，同时避免探测无关项目挂载。
func (p *appServerGatewayPolicy) projectRootsDriftedOutsideLock(used map[string]projects.Project) bool {
	if p == nil || p.router == nil || p.router.projects == nil || len(used) == 0 {
		return false
	}
	for id, snap := range used {
		live, ok := p.router.projects.Get(id)
		if !ok {
			return true
		}
		if live.Missing != snap.Missing || filepath.Clean(live.RealPath) != filepath.Clean(snap.RealPath) {
			return true
		}
	}
	return false
}

// projectRootsDriftedInMemoryLocked 100% 纯内存复核阶段 A 使用过的项目根快照是否与最新已刷新索引一致。
func (p *appServerGatewayPolicy) projectRootsDriftedInMemoryLocked(used map[string]projects.Project) bool {
	if p == nil || p.router == nil || p.router.projects == nil || len(used) == 0 {
		return false
	}
	for id, snap := range used {
		live, ok := p.router.projects.GetCached(id)
		if !ok {
			return true
		}
		if live.Missing != snap.Missing || filepath.Clean(live.RealPath) != filepath.Clean(snap.RealPath) {
			return true
		}
	}
	return false
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

	// 最多 2 次因并发删盘（lifecycleEpoch 变化）或已用项目根符号链接改指触发的锁外重取证（attempt=0,1,2）。
	disallowMissingFallback := false
	for stageAAttempt := 0; stageAAttempt <= 2; stageAAttempt++ {
		stageA, stageAErr := p.prepareThreadListStageA(payload, frame, binding, stageAAttempt, disallowMissingFallback)
		if stageAErr != nil {
			return p.finalizeThreadListErrorStageB(binding, stageAErr)
		}
		if p.projectRootsDriftedOutsideLock(stageA.usedProjectRoots) {
			if stageAAttempt == 2 {
				return p.abortThreadListSilently(binding)
			}
			continue
		}

		decision, needStageAReprobe := p.finalizeThreadListSuccessStageB(binding, stageA, stageAAttempt)
		if !needStageAReprobe {
			return decision
		}
		disallowMissingFallback = true
		// 连续 2 次锁外重取证后仍遇并发删盘/改指风暴 → fail-closed 静默丢弃（零授权、零游标、零预算）。
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

// finalizeThreadListSuccessStageB 执行严格遵守全包锁图（managedWorktreeCommitMu → p.mu → 单把叶锁）的阶段 B 提交：
//   - 绝不获取串行慢速 Git/磁盘批量清理的 managedWorktreeCleanupMu，避免无关会话列表被慢速清理阻塞；
//   - 在获取短持生命周期提交锁 managedWorktreeCommitMu 之前先完成响应构造与暂存模式媒体/输出预留；
//   - 最终在 managedWorktreeCommitMu → p.mu → gatewayThreadsMu 短临界区内复验 worktree 生命周期、
//     TTL、sink 与权限基线并原子提交。
func (p *appServerGatewayPolicy) finalizeThreadListSuccessStageB(
	binding threadListRequestBinding,
	stageA threadListStageACandidates,
	stageAAttempt int,
) (decision upstreamFrameDecision, needStageAReprobe bool) {
	type verifiedRow struct {
		candidate   threadListStageACandidate
		liveProject projects.Project
	}

	verifyStageBCandidates := func() (
		verifiedRows []verifiedRow,
		pageMergedByID map[string]appServerGatewayAllowedThread,
		reprobe bool,
		anchorInvalidated bool,
	) {
		anchorInvalidated = stageA.anchorInvalidated
		lifecycleChanged := p.router != nil && p.router.managedWorktreeLifecycleEpoch.Load() != stageA.worktreeLifecycleEpoch
		if p.router != nil && !binding.pendingThread.globalDiscovery && !anchorInvalidated {
			if stageA.anchorDep != nil {
				if _, ok := p.router.verifyManagedWorktreeDepInMemoryLocked(*stageA.anchorDep); !ok {
					anchorInvalidated = true
				}
			}
			if !anchorInvalidated && stageA.anchorRealPath != "" {
				matched, floorExceeded := p.router.matchesDeletedOrRevokedManagedWorktreeLocked(
					stageA.anchorRealPath,
					stageA.anchorAncestorObjIDs,
					stageA.worktreeLifecycleEpoch,
				)
				if matched || floorExceeded {
					anchorInvalidated = true
				} else if lifecycleChanged && (len(stageA.anchorAncestorObjIDs) == 0 || stageA.anchorUnderManagedRoot) {
					return nil, nil, true, anchorInvalidated
				}
			}
		}

		verifiedRows = make([]verifiedRow, 0, len(stageA.candidates))
		pageMergedByID = make(map[string]appServerGatewayAllowedThread, len(stageA.candidates))
		runtimeID := normalizeAppServerRuntimeID(p.runtimeID)
		if anchorInvalidated {
			return verifiedRows, pageMergedByID, false, anchorInvalidated
		}
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
					return nil, nil, true, anchorInvalidated
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
		return verifiedRows, pageMergedByID, false, anchorInvalidated
	}

	releasePendingManagedUseIfAny := func() {
		if binding.pendingThread.managedWorktreePath != "" && p.router != nil {
			p.router.releaseManagedWorktreePendingUse(binding.pendingThread.managedWorktreePath)
		}
	}

	// 1) 快速前置复验（不持 managedWorktreeCleanupMu 也不持 managedWorktreeCommitMu）。
	p.mu.Lock()
	if !p.recheckOrCleanThreadListBindingLocked(binding, p.now(), false) {
		p.mu.Unlock()
		return upstreamFrameDecision{}, false
	}
	verifiedRows, pageMergedByID, needReprobe, _ := verifyStageBCandidates()
	if needReprobe {
		p.mu.Unlock()
		return upstreamFrameDecision{}, true
	}
	p.mu.Unlock()

	runtimeID := normalizeAppServerRuntimeID(p.runtimeID)
	redactOnly := binding.pendingHistory != nil && binding.pendingHistory.redactOnly

	// 2) 有界权限基线复验循环（最多 4 次）：先锁外构造与暂存，再短持 managedWorktreeCommitMu → p.mu → gatewayThreadsMu 原子提交。
	for permAttempt := 0; permAttempt < 4; permAttempt++ {
		// Step 2a：短持 p.mu → gatewayThreadsMu 读取最新权限基线与 observedEpoch，立即释放。
		p.mu.Lock()
		if !p.recheckOrCleanThreadListBindingLocked(binding, p.now(), false) {
			p.mu.Unlock()
			return upstreamFrameDecision{}, false
		}
		observedEpoch, historicalBaseByID := p.snapshotHistoricalBaselinesLocked(pageMergedByID, runtimeID)
		p.mu.Unlock()

		// Step 2b：在获取任何路由级 worktree 提交锁之前，无锁构造响应并完成媒体/输出暂存与硬上限检查。
		finalThreadByID := make(map[string]appServerGatewayAllowedThread, len(pageMergedByID))
		for id, pageMerged := range pageMergedByID {
			if base, hasBase := historicalBaseByID[id]; hasBase {
				finalThreadByID[id] = mergeCrossPageAllowedThread(base, pageMerged, binding.claimDirectInputVersion, nil)
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
			p.mu.Lock()
			dec := p.abortLockedWithPolicyError(binding, malformedThreadListPolicyError(binding.frameID, marshalErr.Error()), false)
			p.mu.Unlock()
			releasePendingManagedUseIfAny()
			return dec, false
		}

		// 暂存模式图片脱敏与大输出脱水（零持有 managedWorktreeCommitMu / p.mu / gatewayThreadsMu）。
		stagedPayload, mediaRes, outputRes := p.router.stageRedactAndDehydrateThreadListPayload(rawForwardPayload, redactOnly)

		overHardCap := !redactOnly && appServerGatewayHistoryResponseCapBytes > 0 && len(stagedPayload) > appServerGatewayHistoryResponseCapBytes
		if binding.pendingHistory != nil {
			p.recordHistoryResponseMetrics(binding.pendingHistory.method, len(stagedPayload), overHardCap)
		}
		if overHardCap {
			mediaRes.cancel()
			outputRes.cancel()
			capErr := p.historyResponseTooLargeError(binding.frameID, *binding.pendingHistory, len(stagedPayload))
			p.mu.Lock()
			dec := p.abortLockedWithPolicyError(binding, capErr, false)
			p.mu.Unlock()
			releasePendingManagedUseIfAny()
			return dec, false
		}

		if p.onStageBBeforeFinalCommitLock != nil {
			p.onStageBBeforeFinalCommitLock(permAttempt)
		}

		// Step 2c：唯一短持提交边界 — managedWorktreeCommitMu → p.mu → gatewayThreadsMu（全纯内存微秒级）。
		if p.router != nil {
			p.router.managedWorktreeCommitMu.Lock()
		}
		p.mu.Lock()

		// 在 commit 锁下复验 worktree 生命周期与已用项目根快照是否变化；若在暂存期间发生删除/撤权/deleting/改指，
		// 取消暂存并触发阶段 A 重探。
		if p.projectRootsDriftedInMemoryLocked(stageA.usedProjectRoots) {
			p.mu.Unlock()
			if p.router != nil {
				p.router.managedWorktreeCommitMu.Unlock()
			}
			mediaRes.cancel()
			outputRes.cancel()
			return upstreamFrameDecision{}, true
		}
		if p.router != nil && p.router.managedWorktreeLifecycleEpoch.Load() != stageA.worktreeLifecycleEpoch {
			reverifiedRows, _, commitNeedReprobe, _ := verifyStageBCandidates()
			if commitNeedReprobe || len(reverifiedRows) != len(verifiedRows) {
				p.mu.Unlock()
				p.router.managedWorktreeCommitMu.Unlock()
				mediaRes.cancel()
				outputRes.cancel()
				return upstreamFrameDecision{}, true
			}
		}

		var finalNow time.Time
		baselineDrifted := false
		bindingDead := false
		if p.router != nil {
			p.router.gatewayThreadsMu.Lock()
			finalNow = p.now()
			if !p.recheckOrCleanThreadListBindingLocked(binding, finalNow, false) {
				bindingDead = true
			} else if p.router.gatewayThreadsMutationEpoch != observedEpoch {
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
				p.router.gatewayThreadsMu.Unlock()
				if !bindingDead && permAttempt >= 3 {
					delete(p.pendingThreads, binding.key)
				}
				p.mu.Unlock()
				p.router.managedWorktreeCommitMu.Unlock()
				mediaRes.cancel()
				outputRes.cancel()
				if bindingDead {
					releasePendingManagedUseIfAny()
					return upstreamFrameDecision{}, false
				}
				if permAttempt < 3 {
					continue
				}
				releasePendingManagedUseIfAny()
				return upstreamFrameDecision{}, false
			}

			if p.onStageBAfterFinalLockBeforeWrite != nil {
				p.onStageBAfterFinalLockBeforeWrite()
			}

			commitVer := binding.claimDirectInputVersion
			useClaimVer := func() uint64 {
				if commitVer != 0 {
					return commitVer
				}
				p.router.nextGatewayThreadDirectInputVersion++
				return p.router.nextGatewayThreadDirectInputVersion
			}
			for id, pageMerged := range pageMergedByID {
				var merged appServerGatewayAllowedThread
				if base, hasBase := historicalBaseByID[id]; hasBase {
					merged = mergeCrossPageAllowedThread(base, pageMerged, binding.claimDirectInputVersion, useClaimVer)
				} else {
					merged = normalizeAllowedThreadRestrictionBits(pageMerged)
					merged.pushSeededOnly = false
					if merged.explicitDirectInputDenied || pageMerged.rawDirectInput == rawDirectInputDeny {
						merged.explicitDirectInputDenied = true
						merged.explicitDirectInputVersion = useClaimVer()
					} else if pageMerged.rawDirectInput == rawDirectInputAllow && !merged.readOnly {
						merged.explicitDirectInputDenied = false
						merged.explicitDirectInputVersion = useClaimVer()
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
			p.router.gatewayThreadsMu.Unlock()
		} else {
			finalNow = p.now()
			if !p.recheckOrCleanThreadListBindingLocked(binding, finalNow, false) {
				p.mu.Unlock()
				mediaRes.cancel()
				outputRes.cancel()
				return upstreamFrameDecision{}, false
			}
		}

		for id, merged := range finalThreadByID {
			p.allowedThreads[id] = merged
		}

		mediaRelease := mediaRes.commit()
		outputRelease := outputRes.commit()

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

		delete(p.pendingThreads, binding.key)

		var histForGlobal *appServerGatewayPendingHistoryRequest
		if binding.pendingHistory != nil && !binding.pendingHistory.redactOnly {
			hist := *binding.pendingHistory
			p.recordHistoryResponseBudgetLocked(hist, len(stagedPayload), finalNow)
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

		if histForGlobal != nil && p.router != nil {
			p.router.recordHistoryGlobalResponseBudget(*histForGlobal, len(stagedPayload))
		}

		p.mu.Unlock()
		if p.router != nil {
			p.router.managedWorktreeCommitMu.Unlock()
		}
		releasePendingManagedUseIfAny()

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
	globalOld, hasLiveGlobal, hasGlobal := p.router.effectiveGatewayThreadLocked(key, now)
	return mergeHistoricalBaseline(connOld, hasConn, globalOld, hasGlobal, hasLiveGlobal)
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

	// 2) 若候选原本在项目作用域内：优先核验阶段 A 刷新过的项目匹配与最新内存索引仍一致，
	//    避免配置项目符号链接改指后仍将旧目标目录放行或被启动期旧快照覆盖。
	if !cand.scope.browse {
		if cand.hasStageAResolvedProject && cand.resolvedProjectID != "" {
			if liveProj, stillRegistered := p.router.projects.GetCached(cand.resolvedProjectID); stillRegistered &&
				liveProj.Missing == cand.resolvedProject.Missing &&
				filepath.Clean(liveProj.RealPath) == filepath.Clean(cand.resolvedProject.RealPath) {
				return gatewayScope{id: liveProj.ID, realPath: cand.scope.realPath, project: liveProj, missing: cand.scope.missing}, liveProj, true
			}
		}
		if project, found := p.router.projects.FindByCanonicalPathInMemory(cand.scope.realPath); found {
			return gatewayScope{id: project.ID, realPath: cand.scope.realPath, project: project, missing: cand.scope.missing}, project, true
		}
		if realPathWithinAny(canonicalBrowseRoots, cand.scope.realPath) {
			if isGlobal {
				// Global 降级到 browse_roots 仍需归属某已登记项目（纯内存校验）。
				if cand.resolvedProjectID != "" {
					if project, found := p.router.projects.GetCached(cand.resolvedProjectID); found {
						if cand.hasStageAResolvedProject {
							project = cand.resolvedProject
						}
						return gatewayScope{id: workspaceIDForRealPath(cand.scope.realPath), realPath: cand.scope.realPath, browse: true, missing: cand.scope.missing}, project, true
					}
				}
				return gatewayScope{}, projects.Project{}, false
			}
			return gatewayScope{id: workspaceIDForRealPath(cand.scope.realPath), realPath: cand.scope.realPath, browse: true, missing: cand.scope.missing}, projects.Project{}, true
		}
		return gatewayScope{}, projects.Project{}, false
	}

	// 3) 若候选原本在 browse_roots 内：阶段 A 已使用当次刷新项目快照判定其不属于已登记项目，
	//    这里直接复验 browse_roots 与 Global 归属项目（纯内存 GetCached）。
	if !realPathWithinAny(canonicalBrowseRoots, cand.scope.realPath) {
		return gatewayScope{}, projects.Project{}, false
	}
	if isGlobal {
		project, found := p.router.projects.GetCached(cand.resolvedProjectID)
		if !found {
			return gatewayScope{}, projects.Project{}, false
		}
		if cand.hasStageAResolvedProject {
			project = cand.resolvedProject
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
