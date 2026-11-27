package httpapi

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const managedWorktreeRecentDeletionsMax = 256

type pendingRegistryDeleteEntry struct {
	worktree                 managedWorktree
	checkoutPath             string
	checkoutObjectID         string
	workspaceObjectID        string
	checkoutConfirmedDeleted bool
}

type deletedManagedWorktreeRecord struct {
	checkoutPath      string
	workspacePath     string
	checkoutObjectID  string
	workspaceObjectID string
	deletedAtEpoch    uint64
}

type managedWorktreeDependency struct {
	path        string
	instanceGen uint64
}

// unregisterManagedWorktreeLocked 要求调用方已持有 managedWorktreeCleanupMu，
// 且仅在物理 checkout 已确认删除或不存在之后调用。
// 先在内存中原子吊销授权并登记待删记录，再执行磁盘 registry 文件删除，
// 确保即使删盘失败也绝不重新授权已删除的 checkout。
func (r *Router) unregisterManagedWorktreeLocked(
	worktree managedWorktree,
	verifiedCheckoutRoot string,
	checkoutObjID string,
	workspaceObjID string,
) error {
	path := strings.TrimSpace(worktree.Path)
	checkoutRoot := strings.TrimSpace(verifiedCheckoutRoot)
	if checkoutRoot == "" {
		if stored, ok := storedManagedWorktreeCheckoutPath(worktree); ok {
			checkoutRoot = stored
		} else {
			checkoutRoot = path
		}
	}
	if checkoutObjID == "" {
		checkoutObjID = worktree.CheckoutObjectID
	}
	if workspaceObjID == "" {
		workspaceObjID = worktree.WorkspaceObjectID
	}

	// 1) 在定位/删除磁盘 registry 文件之前先原子吊销内存授权并推进生命周期代次。
	r.managedWorktreesMu.Lock()
	if prev, ok := r.managedWorktrees[path]; ok {
		if worktree.Path == "" {
			worktree = prev
			path = prev.Path
		}
		if checkoutObjID == "" {
			checkoutObjID = prev.CheckoutObjectID
		}
		if workspaceObjID == "" {
			workspaceObjID = prev.WorkspaceObjectID
		}
		delete(r.managedWorktrees, path)
	}
	if prevCold, ok := r.managedWorktreeColdCache[path]; ok {
		if checkoutObjID == "" {
			checkoutObjID = prevCold.CheckoutObjectID
		}
		if workspaceObjID == "" {
			workspaceObjID = prevCold.WorkspaceObjectID
		}
		delete(r.managedWorktreeColdCache, path)
	}
	if r.managedWorktreePendingRegistryDelete == nil {
		r.managedWorktreePendingRegistryDelete = map[string]pendingRegistryDeleteEntry{}
	}
	r.managedWorktreePendingRegistryDelete[path] = pendingRegistryDeleteEntry{
		worktree:                 worktree,
		checkoutPath:             checkoutRoot,
		checkoutObjectID:         checkoutObjID,
		workspaceObjectID:        workspaceObjID,
		checkoutConfirmedDeleted: true,
	}
	epoch := r.managedWorktreeLifecycleEpoch.Add(1)
	r.managedWorktreeRecentDeletions = append(r.managedWorktreeRecentDeletions, deletedManagedWorktreeRecord{
		checkoutPath:      checkoutRoot,
		workspacePath:     path,
		checkoutObjectID:  checkoutObjID,
		workspaceObjectID: workspaceObjID,
		deletedAtEpoch:    epoch,
	})
	if len(r.managedWorktreeRecentDeletions) > managedWorktreeRecentDeletionsMax {
		dropped := r.managedWorktreeRecentDeletions[0]
		r.managedWorktreeRecentDeletions = r.managedWorktreeRecentDeletions[1:]
		if dropped.deletedAtEpoch > r.managedWorktreeDeletionFloorEpoch {
			r.managedWorktreeDeletionFloorEpoch = dropped.deletedAtEpoch
		}
	}
	r.managedWorktreesMu.Unlock()

	// 2) 删除磁盘 registry 文件。失败时保留待删表供重试，但授权已永久吊销。
	file, err := r.managedWorktreeRegistryFile(path)
	if err != nil {
		return fmt.Errorf("定位 worktree registry 失败：%w", err)
	}
	remove := os.Remove
	if r.managedWorktreeRegistryRemove != nil {
		remove = r.managedWorktreeRegistryRemove
	}
	if err := remove(file); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("删除 worktree registry 失败：%w", err)
	}

	r.managedWorktreesMu.Lock()
	delete(r.managedWorktreePendingRegistryDelete, path)
	r.managedWorktreesMu.Unlock()
	return nil
}

func (r *Router) pendingRegistryDeleteByExactPath(rawPath string) (pendingRegistryDeleteEntry, bool) {
	path := strings.TrimSpace(rawPath)
	if path == "" {
		return pendingRegistryDeleteEntry{}, false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return pendingRegistryDeleteEntry{}, false
	}
	candidates := []string{filepath.Clean(abs)}
	if realPath, err := filepath.EvalSymlinks(abs); err == nil {
		candidates = append(candidates, filepath.Clean(realPath))
	}
	r.managedWorktreesMu.Lock()
	defer r.managedWorktreesMu.Unlock()
	for _, candidate := range candidates {
		if entry, ok := r.managedWorktreePendingRegistryDelete[candidate]; ok {
			return entry, true
		}
	}
	return pendingRegistryDeleteEntry{}, false
}

func (r *Router) isManagedWorktreeRevokedPath(realPath string) bool {
	r.managedWorktreesMu.Lock()
	defer r.managedWorktreesMu.Unlock()
	return r.isManagedWorktreeRevokedPathLocked(realPath)
}

// isManagedWorktreeRevokedPathLocked 要求调用方已持有 managedWorktreesMu。
// 使用完整 checkout 根与工作区路径检查撤权，只做收紧拦截，不扩张正向授权。
func (r *Router) isManagedWorktreeRevokedPathLocked(realPath string) bool {
	if len(r.managedWorktreePendingRegistryDelete) == 0 {
		return false
	}
	for revokedPath, entry := range r.managedWorktreePendingRegistryDelete {
		if realPathWithin(revokedPath, realPath) || exactPathWithin(revokedPath, realPath) {
			return true
		}
		if entry.checkoutPath != "" && (realPathWithin(entry.checkoutPath, realPath) || exactPathWithin(entry.checkoutPath, realPath)) {
			return true
		}
	}
	return false
}

// managedWorktreeMapFromRegistryReadOnlyLocked 纯只读读取磁盘 registry/*.json，
// 严禁调用 migrateLegacyManagedWorktree 或 touchManagedWorktreeAt（零写盘）。
// 要求调用方已持有 managedWorktreeCleanupMu。
func (r *Router) managedWorktreeMapFromRegistryReadOnlyLocked() map[string]managedWorktree {
	items := map[string]managedWorktree{}
	root, err := r.worktreesRoot()
	if err != nil {
		return items
	}
	entries, err := os.ReadDir(filepath.Join(root, "registry"))
	if err != nil {
		return items
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		file := filepath.Join(root, "registry", entry.Name())
		data, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		var worktree managedWorktree
		if json.Unmarshal(data, &worktree) != nil {
			continue
		}
		if strings.TrimSpace(worktree.Path) == "" {
			continue
		}
		items[worktree.Path] = worktree
	}
	return items
}

// probeManagedWorktreeForThreadListStageA 供 thread/list 阶段 A 做 100% 无写盘的托管工作树正向探测：
// - 热态查 r.managedWorktrees 与 r.managedWorktreeColdCache（严格按 .Path 匹配，排除已撤权路径）；
// - 冷启动持 managedWorktreeCleanupMu 只读扫描 registry（不迁移、不 touch），命中后仅写入隔离的
//   r.managedWorktreeColdCache（永不写入 r.managedWorktrees，避免遮蔽 allManagedWorktreeMap 迁移结果）；
// - 项目校验使用纯内存 r.projects.GetCached（不刷新磁盘可用性）。
func (r *Router) probeManagedWorktreeForThreadListStageA(realPath string) (managedWorktree, bool) {
	if r == nil || strings.TrimSpace(realPath) == "" {
		return managedWorktree{}, false
	}
	// 热态快速路径（不抢 cleanupMu）。
	r.managedWorktreesMu.Lock()
	if r.isManagedWorktreeRevokedPathLocked(realPath) {
		r.managedWorktreesMu.Unlock()
		return managedWorktree{}, false
	}
	if wt, ok := managedWorktreeForPathInMap(r.managedWorktrees, realPath); ok && !r.isManagedWorktreeRevokedPathLocked(wt.Path) {
		r.managedWorktreesMu.Unlock()
		if project, found := r.projects.GetCached(wt.RootProject.ID); found {
			wt.RootProject = project
			return wt, true
		}
		return managedWorktree{}, false
	}
	if wt, ok := managedWorktreeForPathInMap(r.managedWorktreeColdCache, realPath); ok && !r.isManagedWorktreeRevokedPathLocked(wt.Path) {
		r.managedWorktreesMu.Unlock()
		if project, found := r.projects.GetCached(wt.RootProject.ID); found {
			wt.RootProject = project
			return wt, true
		}
		return managedWorktree{}, false
	}
	r.managedWorktreesMu.Unlock()

	// 冷启动只读热身路径（锁外无 p.mu / gatewayThreadsMu，锁序安全）。
	r.managedWorktreeCleanupMu.Lock()
	defer r.managedWorktreeCleanupMu.Unlock()

	r.managedWorktreesMu.Lock()
	if r.isManagedWorktreeRevokedPathLocked(realPath) {
		r.managedWorktreesMu.Unlock()
		return managedWorktree{}, false
	}
	if wt, ok := managedWorktreeForPathInMap(r.managedWorktrees, realPath); ok && !r.isManagedWorktreeRevokedPathLocked(wt.Path) {
		r.managedWorktreesMu.Unlock()
		if project, found := r.projects.GetCached(wt.RootProject.ID); found {
			wt.RootProject = project
			return wt, true
		}
		return managedWorktree{}, false
	}
	if wt, ok := managedWorktreeForPathInMap(r.managedWorktreeColdCache, realPath); ok && !r.isManagedWorktreeRevokedPathLocked(wt.Path) {
		r.managedWorktreesMu.Unlock()
		if project, found := r.projects.GetCached(wt.RootProject.ID); found {
			wt.RootProject = project
			return wt, true
		}
		return managedWorktree{}, false
	}
	r.managedWorktreesMu.Unlock()

	diskItems := r.managedWorktreeMapFromRegistryReadOnlyLocked()
	wt, ok := managedWorktreeForPathInMap(diskItems, realPath)
	if !ok {
		return managedWorktree{}, false
	}
	if r.isManagedWorktreeRevokedPath(wt.Path) {
		return managedWorktree{}, false
	}
	if _, statErr := os.Stat(wt.Path); statErr != nil {
		return managedWorktree{}, false
	}
	project, found := r.projects.GetCached(wt.RootProject.ID)
	if !found {
		return managedWorktree{}, false
	}
	wt.RootProject = project
	r.managedWorktreeNextGen++
	wt.InstanceGen = r.managedWorktreeNextGen
	if checkoutRoot, ok := storedManagedWorktreeCheckoutPath(wt); ok {
		wt.CheckoutObjectID, _ = filesystemObjectIdentity(checkoutRoot)
	}
	wt.WorkspaceObjectID, _ = filesystemObjectIdentity(wt.Path)

	r.managedWorktreesMu.Lock()
	if r.managedWorktreeColdCache == nil {
		r.managedWorktreeColdCache = map[string]managedWorktree{}
	}
	// 严禁写入 r.managedWorktrees：保持冷启动只读热身与 allManagedWorktreeMap 完全隔离。
	r.managedWorktreeColdCache[wt.Path] = wt
	r.managedWorktreesMu.Unlock()
	return wt, true
}

// probeManagedWorktreeLifecycleDepStageA 独立探测路径是否落在任意托管 checkout 范围内
// （用于生命周期依赖记录，即使该路径被已登记项目优先命中也不遗漏）。
// 仅用于收紧复验，绝不扩大正向授权。
func (r *Router) probeManagedWorktreeLifecycleDepStageA(realPath string, ancestorObjIDs map[string]struct{}) (*managedWorktreeDependency, bool) {
	if r == nil || strings.TrimSpace(realPath) == "" {
		return nil, false
	}
	matchMap := func(items map[string]managedWorktree) (*managedWorktreeDependency, bool) {
		for _, wt := range items {
			if wt.InstanceGen == 0 {
				continue
			}
			if wt.CheckoutObjectID != "" {
				if _, ok := ancestorObjIDs[wt.CheckoutObjectID]; ok {
					return &managedWorktreeDependency{path: wt.Path, instanceGen: wt.InstanceGen}, true
				}
			}
			if wt.WorkspaceObjectID != "" {
				if _, ok := ancestorObjIDs[wt.WorkspaceObjectID]; ok {
					return &managedWorktreeDependency{path: wt.Path, instanceGen: wt.InstanceGen}, true
				}
			}
			if checkoutRoot, ok := storedManagedWorktreeCheckoutPath(wt); ok && exactPathWithin(checkoutRoot, realPath) {
				return &managedWorktreeDependency{path: wt.Path, instanceGen: wt.InstanceGen}, true
			}
			if exactPathWithin(wt.Path, realPath) {
				return &managedWorktreeDependency{path: wt.Path, instanceGen: wt.InstanceGen}, true
			}
		}
		return nil, false
	}

	r.managedWorktreesMu.Lock()
	if dep, ok := matchMap(r.managedWorktrees); ok {
		r.managedWorktreesMu.Unlock()
		return dep, true
	}
	if dep, ok := matchMap(r.managedWorktreeColdCache); ok {
		r.managedWorktreesMu.Unlock()
		return dep, true
	}
	r.managedWorktreesMu.Unlock()

	// 若内存未热身，尝试只读探测一次（命中 .Path 则自动热身到 coldCache）。
	if wt, ok := r.probeManagedWorktreeForThreadListStageA(realPath); ok {
		return &managedWorktreeDependency{path: wt.Path, instanceGen: wt.InstanceGen}, true
	}
	return nil, false
}

// managedWorktreeForPathInMemoryLocked 要求调用方已持有 managedWorktreeCleanupMu。
// 100% 纯内存、零磁盘 I/O、零 touch、零迁移，正向授权仍严格按 .Path 匹配。
func (r *Router) managedWorktreeForPathInMemoryLocked(realPath string) (managedWorktree, bool) {
	if r == nil || strings.TrimSpace(realPath) == "" {
		return managedWorktree{}, false
	}
	r.managedWorktreesMu.Lock()
	if r.isManagedWorktreeRevokedPathLocked(realPath) {
		r.managedWorktreesMu.Unlock()
		return managedWorktree{}, false
	}
	wt, ok := managedWorktreeForPathInMap(r.managedWorktrees, realPath)
	if !ok {
		wt, ok = managedWorktreeForPathInMap(r.managedWorktreeColdCache, realPath)
	}
	if ok && r.isManagedWorktreeRevokedPathLocked(wt.Path) {
		ok = false
	}
	r.managedWorktreesMu.Unlock()
	if !ok {
		return managedWorktree{}, false
	}
	project, found := r.projects.GetCached(wt.RootProject.ID)
	if !found {
		return managedWorktree{}, false
	}
	wt.RootProject = project
	return wt, true
}

// verifyManagedWorktreeDepInMemoryLocked 要求调用方已持有 managedWorktreeCleanupMu。
// 100% 纯内存核验托管 checkout 依赖仍在活跃/冷缓存表、未撤权且 InstanceGen 精确一致。
func (r *Router) verifyManagedWorktreeDepInMemoryLocked(dep managedWorktreeDependency) (managedWorktree, bool) {
	if r == nil || dep.path == "" {
		return managedWorktree{}, false
	}
	r.managedWorktreesMu.Lock()
	if r.isManagedWorktreeRevokedPathLocked(dep.path) {
		r.managedWorktreesMu.Unlock()
		return managedWorktree{}, false
	}
	wt, ok := r.managedWorktrees[dep.path]
	if !ok {
		wt, ok = r.managedWorktreeColdCache[dep.path]
	}
	r.managedWorktreesMu.Unlock()
	if !ok {
		return managedWorktree{}, false
	}
	if dep.instanceGen != 0 && wt.InstanceGen != dep.instanceGen {
		return managedWorktree{}, false
	}
	project, found := r.projects.GetCached(wt.RootProject.ID)
	if !found {
		return managedWorktree{}, false
	}
	wt.RootProject = project
	return wt, true
}

// matchesDeletedOrRevokedManagedWorktreeLocked 要求调用方已持有 managedWorktreeCleanupMu。
// 100% 纯内存核对候选路径/固化对象身份是否命中待删记录或 sinceEpoch 之后发生的删除记录：
// 别名仅凭固化 filesystemObjectIdentity 精确字符串比对，路径兜底仅用逐段字节精确 exactPathWithin。
func (r *Router) matchesDeletedOrRevokedManagedWorktreeLocked(
	realPath string,
	ancestorObjIDs map[string]struct{},
	sinceEpoch uint64,
) (matched bool, floorExceeded bool) {
	if r == nil {
		return false, false
	}
	r.managedWorktreesMu.Lock()
	defer r.managedWorktreesMu.Unlock()

	if r.managedWorktreeDeletionFloorEpoch > sinceEpoch {
		floorExceeded = true
	}
	matchEntry := func(checkoutPath, workspacePath, checkoutObjID, workspaceObjID string) bool {
		if checkoutObjID != "" {
			if _, ok := ancestorObjIDs[checkoutObjID]; ok {
				return true
			}
		}
		if workspaceObjID != "" {
			if _, ok := ancestorObjIDs[workspaceObjID]; ok {
				return true
			}
		}
		if checkoutPath != "" && exactPathWithin(checkoutPath, realPath) {
			return true
		}
		if workspacePath != "" && exactPathWithin(workspacePath, realPath) {
			return true
		}
		return false
	}
	for _, pending := range r.managedWorktreePendingRegistryDelete {
		if matchEntry(pending.checkoutPath, pending.worktree.Path, pending.checkoutObjectID, pending.workspaceObjectID) {
			return true, floorExceeded
		}
	}
	for _, rec := range r.managedWorktreeRecentDeletions {
		if rec.deletedAtEpoch <= sinceEpoch {
			continue
		}
		if matchEntry(rec.checkoutPath, rec.workspacePath, rec.checkoutObjectID, rec.workspaceObjectID) {
			return true, floorExceeded
		}
	}
	return false, floorExceeded
}

// hasManagedWorktreeForLexicalPath 供 files.go 做错误分类只读判定：
// 串行于 managedWorktreeCleanupMu，零迁移写盘、零 touch，拦截已撤权记录，正向按 .Path 匹配。
func (r *Router) hasManagedWorktreeForLexicalPath(candidate string) bool {
	if r == nil || strings.TrimSpace(candidate) == "" {
		return false
	}
	if _, ok := r.managedWorktreeForPathFromMemory(candidate); ok {
		return true
	}
	r.managedWorktreeCleanupMu.Lock()
	defer r.managedWorktreeCleanupMu.Unlock()
	if r.isManagedWorktreeRevokedPath(candidate) {
		return false
	}
	items := r.managedWorktreeMapFromRegistryReadOnlyLocked()
	wt, ok := managedWorktreeForPathInMap(items, candidate)
	if !ok || r.isManagedWorktreeRevokedPath(wt.Path) {
		return false
	}
	if _, ok := r.projects.GetCached(wt.RootProject.ID); !ok {
		return false
	}
	_, statErr := os.Stat(wt.Path)
	return statErr == nil
}

// captureAncestorObjectIDs 沿存在路径的祖先链采集固化的纯字符串对象身份，
// 供阶段 B 零系统调用、跨大小写别名精确比对。
func captureAncestorObjectIDs(path string) map[string]struct{} {
	clean := filepath.Clean(strings.TrimSpace(path))
	if clean == "" || clean == "." {
		return nil
	}
	var ids map[string]struct{}
	cur := clean
	for {
		if id, ok := filesystemObjectIdentity(cur); ok && id != "" {
			if ids == nil {
				ids = map[string]struct{}{}
			}
			ids[id] = struct{}{}
		}
		parent := filepath.Dir(cur)
		if parent == cur || parent == "" {
			break
		}
		cur = parent
	}
	return ids
}

// exactPathWithin 执行全平台（含 Windows）一致的逐段字节精确前缀判断：
// 绝不调用 filepath.Rel 或 strings.EqualFold，避免在大小写敏感卷/目录上将 foo 误匹配为 Foo 或 Foo\gone。
func exactPathWithin(root, target string) bool {
	rootPrefix, rootSegs, okRoot := splitExactPath(root)
	targetPrefix, targetSegs, okTarget := splitExactPath(target)
	if !okRoot || !okTarget || rootPrefix != targetPrefix {
		return false
	}
	if len(targetSegs) < len(rootSegs) {
		return false
	}
	for i := range rootSegs {
		if targetSegs[i] != rootSegs[i] {
			return false
		}
	}
	return true
}

func splitExactPath(raw string) (prefix string, segments []string, ok bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", nil, false
	}
	// 统一按 POSIX 根、Windows 盘符根（如 C:\）或 UNC 根（如 \\host\share）解析，
	// 全部分段保持原始字节大小写，不做 EqualFold。
	norm := strings.ReplaceAll(trimmed, `\`, `/`)
	switch {
	case strings.HasPrefix(norm, "//"):
		rest := strings.TrimPrefix(norm, "//")
		parts := splitNonEmptyExactSegments(rest)
		if len(parts) < 2 {
			return "", nil, false
		}
		prefix = "//" + parts[0] + "/" + parts[1]
		segments = cleanExactSegments(parts[2:])
		return prefix, segments, true
	case len(norm) >= 3 && isASCIIAlpha(norm[0]) && norm[1] == ':' && norm[2] == '/':
		prefix = norm[:3]
		segments = cleanExactSegments(splitNonEmptyExactSegments(norm[3:]))
		return prefix, segments, true
	case len(norm) == 2 && isASCIIAlpha(norm[0]) && norm[1] == ':':
		return norm + "/", nil, true
	case strings.HasPrefix(norm, "/"):
		prefix = "/"
		segments = cleanExactSegments(splitNonEmptyExactSegments(norm[1:]))
		return prefix, segments, true
	default:
		return "", nil, false
	}
}

func isASCIIAlpha(b byte) bool {
	return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')
}

func splitNonEmptyExactSegments(rest string) []string {
	rawParts := strings.Split(rest, "/")
	out := make([]string, 0, len(rawParts))
	for _, part := range rawParts {
		if part == "" || part == "." {
			continue
		}
		out = append(out, part)
	}
	return out
}

func cleanExactSegments(parts []string) []string {
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
			continue
		}
		out = append(out, part)
	}
	return out
}

// managedWorktreeNowForTest 允许测试注入单调时间而不改变默认行为。
var _ = time.Now
