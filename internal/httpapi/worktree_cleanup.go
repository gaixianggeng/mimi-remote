package httpapi

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"
)

const (
	worktreeCleanupCandidateAfterDays   = 30
	worktreeCleanupKeepLatestPerProject = 3
	worktreeCleanupPlanTTL              = 10 * time.Minute
	worktreeCleanupPlanLimit            = 64
)

const (
	worktreeCleanupBlockerMetadataIncomplete  = "metadata_incomplete"
	worktreeCleanupBlockerOutsideManagedRoot  = "outside_managed_root"
	worktreeCleanupBlockerCheckoutMissing     = "checkout_missing"
	worktreeCleanupBlockerRepositoryMismatch  = "repository_mismatch"
	worktreeCleanupBlockerRecent              = "recent"
	worktreeCleanupBlockerKeepLatest          = "keep_latest"
	worktreeCleanupBlockerGitDirty            = "git_dirty"
	worktreeCleanupBlockerGitStateUnknown     = "git_state_unknown"
	worktreeCleanupBlockerSessionRunning      = "session_running"
	worktreeCleanupBlockerRootProjectMissing  = "root_project_missing"
	worktreeCleanupBlockerLastUsedUnpersisted = "last_used_unpersisted"
)

type worktreeCleanupRequest struct {
	DryRun  *bool    `json:"dry_run,omitempty"`
	Confirm bool     `json:"confirm,omitempty"`
	Paths   []string `json:"paths,omitempty"`
	PlanID  string   `json:"plan_id,omitempty"`
}

type worktreeCleanupPolicy struct {
	AutoDelete           bool `json:"auto_delete"`
	CandidateAfterDays   int  `json:"candidate_after_days"`
	KeepLatestPerProject int  `json:"keep_latest_per_project"`
}

type worktreeCleanupItem struct {
	Workspace  workspaceDescriptor `json:"workspace"`
	Worktree   worktreeDescriptor  `json:"worktree"`
	CreatedAt  time.Time           `json:"created_at"`
	LastUsedAt time.Time           `json:"last_used_at"`
	Eligible   bool                `json:"eligible"`
	Blockers   []string            `json:"blockers"`
}

type worktreeCleanupResponse struct {
	DryRun         bool                  `json:"dry_run"`
	PlanID         string                `json:"plan_id,omitempty"`
	Policy         worktreeCleanupPolicy `json:"policy"`
	GeneratedAt    time.Time             `json:"generated_at"`
	Worktrees      []worktreeCleanupItem `json:"worktrees"`
	CandidatePaths []string              `json:"candidate_paths"`
	DeletedPaths   []string              `json:"deleted_paths"`
	FailedPath     string                `json:"failed_path,omitempty"`
	Error          string                `json:"error,omitempty"`
}

type worktreeCleanupPlan struct {
	ExpiresAt    time.Time
	Fingerprints map[string]string
	Identities   map[string]worktreeCleanupInstanceIdentity
}

type worktreeCleanupEvaluation struct {
	GeneratedAt  time.Time
	Items        []worktreeCleanupItem
	Candidates   []string
	Fingerprints map[string]string
	Identities   map[string]worktreeCleanupInstanceIdentity
}

type worktreeCleanupInstanceIdentity struct {
	CheckoutPath   string `json:"checkout_path"`
	CheckoutObject string `json:"checkout_object"`
	GitDirectory   string `json:"git_directory"`
	GitObject      string `json:"git_object"`
	HeadRef        string `json:"head_ref"`
	Head           string `json:"head"`
	RegistryObject string `json:"registry_object"`
}

type managedWorktreeCleanupDeleteFunc func(context.Context, string, bool, worktreeCleanupInstanceIdentity) (managedWorktree, error)

func (r *Router) worktreeCleanupHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload worktreeCleanupRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	dryRun := true
	if payload.DryRun != nil {
		dryRun = *payload.DryRun
	}
	if dryRun {
		r.handleWorktreeCleanupDryRun(w, req)
		return
	}
	if !payload.Confirm {
		writeError(w, http.StatusBadRequest, "实际清理必须显式设置 confirm=true")
		return
	}
	paths, err := normalizedCleanupPaths(payload.Paths)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	planID := strings.TrimSpace(payload.PlanID)
	if planID == "" {
		writeError(w, http.StatusBadRequest, "实际清理必须携带 dry-run 返回的 plan_id")
		return
	}
	response, status, err := r.executeWorktreeCleanup(req.Context(), planID, paths)
	if err != nil {
		writeError(w, status, err.Error())
		return
	}
	writeJSON(w, status, response)
}

func (r *Router) handleWorktreeCleanupDryRun(w http.ResponseWriter, req *http.Request) {
	// dry-run 会读取 pending-use lease，并把结果固化为可执行计划；评估和
	// 存储必须处于同一临界区，避免漏掉正在建立的 Gateway thread。
	r.managedWorktreeCleanupMu.Lock()
	defer r.managedWorktreeCleanupMu.Unlock()

	evaluation := r.evaluateWorktreeCleanup(req.Context(), time.Now().UTC())
	planID, err := newWorktreeCleanupPlanID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "生成 Worktree 清理计划失败")
		return
	}
	r.pruneWorktreeCleanupPlansLocked(evaluation.GeneratedAt)
	if r.managedWorktreeCleanupPlans == nil {
		r.managedWorktreeCleanupPlans = map[string]worktreeCleanupPlan{}
	}
	r.managedWorktreeCleanupPlans[planID] = worktreeCleanupPlan{
		ExpiresAt:    evaluation.GeneratedAt.Add(worktreeCleanupPlanTTL),
		Fingerprints: cloneStringMap(evaluation.Fingerprints),
		Identities:   cloneWorktreeCleanupIdentities(evaluation.Identities),
	}
	r.trimWorktreeCleanupPlansLocked()

	response := worktreeCleanupResponseFromEvaluation(evaluation, true)
	response.PlanID = planID
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) executeWorktreeCleanup(ctx context.Context, planID string, paths []string) (worktreeCleanupResponse, int, error) {
	r.managedWorktreeCleanupMu.Lock()
	defer r.managedWorktreeCleanupMu.Unlock()

	now := time.Now().UTC()
	r.pruneWorktreeCleanupPlansLocked(now)
	plan, ok := r.managedWorktreeCleanupPlans[planID]
	if !ok {
		return worktreeCleanupResponse{}, http.StatusConflict, fmt.Errorf("清理计划不存在或已过期，请重新 dry-run")
	}
	for _, path := range paths {
		if _, ok := plan.Fingerprints[path]; !ok {
			return worktreeCleanupResponse{}, http.StatusConflict, fmt.Errorf("所选路径不是该 dry-run 计划中的候选：%s", path)
		}
	}

	// 执行前一次性重评估所有选中项；任何一项变脏、被使用、进入运行态或
	// identity 变化，都会在删除第一项之前整体返回 409，禁止部分执行。
	evaluation := r.evaluateWorktreeCleanup(ctx, now)
	for _, path := range paths {
		fingerprint, eligible := evaluation.Fingerprints[path]
		if !eligible || fingerprint != plan.Fingerprints[path] {
			return worktreeCleanupResponse{}, http.StatusConflict, fmt.Errorf("Worktree 状态已变化，请重新 dry-run：%s", path)
		}
	}
	delete(r.managedWorktreeCleanupPlans, planID)

	deleteWorktree := r.managedWorktreeCleanupDelete
	if deleteWorktree == nil {
		deleteWorktree = r.deleteManagedWorktreeWithExpectedIdentityLocked
	}
	deleted := make([]string, 0, len(paths))
	for _, path := range paths {
		if _, err := deleteWorktree(ctx, path, false, plan.Identities[path]); err != nil {
			// 多个 Git worktree 无法组成文件系统事务；若外部进程在预检后制造
			// 竞争导致第 N 项失败，必须用 200 + 结构化部分结果返回；通用客户端
			// 会丢弃非 2xx body，不能让它误以为一项都没有执行。
			var registryCleanupErr *managedWorktreeRegistryCleanupError
			if errors.As(err, &registryCleanupErr) {
				// checkout 已经实际删除；即使 registry unlink 失败，也必须把该路径
				// 计入 deleted_paths，让 APP 先移除不存在的工作区再展示警告。
				deleted = append(deleted, path)
			}
			response := worktreeCleanupResponseFromEvaluation(evaluation, false)
			response.PlanID = planID
			response.DeletedPaths = deleted
			response.FailedPath = path
			response.Error = err.Error()
			return response, http.StatusOK, nil
		}
		deleted = append(deleted, path)
	}
	response := worktreeCleanupResponseFromEvaluation(evaluation, false)
	response.PlanID = planID
	response.DeletedPaths = deleted
	return response, http.StatusOK, nil
}

func (r *Router) evaluateWorktreeCleanup(ctx context.Context, generatedAt time.Time) worktreeCleanupEvaluation {
	generatedAt = generatedAt.UTC()
	worktrees := r.managedWorktreeMapFromRegistryRaw()
	// 正常路径以持久化 registry 为准；如果最近使用时间落盘失败，则叠加当前
	// 进程内更保守的值并追加 blocker，绝不能用磁盘旧时间把活跃 checkout
	// 重新判成候选。
	r.managedWorktreesMu.Lock()
	for path, inMemory := range r.managedWorktrees {
		persisted, ok := worktrees[path]
		if !ok {
			continue
		}
		if inMemory.LastUsedAt.After(persisted.LastUsedAt) {
			persisted.LastUsedAt = inMemory.LastUsedAt
		}
		persisted.LastUsedPersistFailed = inMemory.LastUsedPersistFailed
		worktrees[path] = persisted
	}
	r.managedWorktreesMu.Unlock()

	keepLatest := cleanupKeepLatestPaths(worktrees)
	paths := make([]string, 0, len(worktrees))
	for path := range worktrees {
		paths = append(paths, path)
	}
	sort.Slice(paths, func(i, j int) bool {
		left, right := worktrees[paths[i]], worktrees[paths[j]]
		if left.RootProject.Name != right.RootProject.Name {
			return left.RootProject.Name < right.RootProject.Name
		}
		return paths[i] < paths[j]
	})

	items := make([]worktreeCleanupItem, 0, len(paths))
	candidates := make([]string, 0)
	fingerprints := map[string]string{}
	identities := map[string]worktreeCleanupInstanceIdentity{}
	for _, path := range paths {
		worktree := worktrees[path]
		item, identity := r.evaluateManagedWorktreeCleanupItem(ctx, generatedAt, worktree, keepLatest[path])
		items = append(items, item)
		if !item.Eligible {
			continue
		}
		candidates = append(candidates, path)
		fingerprints[path] = worktreeCleanupFingerprint(item, identity)
		identities[path] = identity
	}
	sort.Strings(candidates)
	return worktreeCleanupEvaluation{
		GeneratedAt:  generatedAt,
		Items:        items,
		Candidates:   candidates,
		Fingerprints: fingerprints,
		Identities:   identities,
	}
}

func (r *Router) evaluateManagedWorktreeCleanupItem(ctx context.Context, now time.Time, worktree managedWorktree, keepLatest bool) (worktreeCleanupItem, worktreeCleanupInstanceIdentity) {
	descriptor := worktreeDescriptorForManagedWorktree(ctx, worktree)
	item := worktreeCleanupItem{
		Workspace:  workspaceDescriptorForManagedWorktree(worktree),
		Worktree:   descriptor,
		CreatedAt:  worktree.CreatedAt,
		LastUsedAt: worktree.LastUsedAt,
		Blockers:   []string{},
	}
	addBlocker := func(code string) {
		for _, existing := range item.Blockers {
			if existing == code {
				return
			}
		}
		item.Blockers = append(item.Blockers, code)
	}

	metadataComplete := worktree.Version == managedWorktreeRegistryVersion &&
		filepath.IsAbs(worktree.Path) && filepath.IsAbs(worktree.CheckoutPath) && filepath.IsAbs(worktree.RepositoryPath) &&
		strings.TrimSpace(worktree.Base) != "" && strings.TrimSpace(worktree.Branch) != "" &&
		strings.TrimSpace(worktree.RootProject.ID) != "" && !worktree.CreatedAt.IsZero() && !worktree.LastUsedAt.IsZero() &&
		!worktree.LastUsedAt.Before(worktree.CreatedAt)
	if !metadataComplete {
		addBlocker(worktreeCleanupBlockerMetadataIncomplete)
	}
	if worktree.LastUsedPersistFailed {
		addBlocker(worktreeCleanupBlockerLastUsedUnpersisted)
	}
	if _, ok := r.projects.Get(worktree.RootProject.ID); !ok {
		addBlocker(worktreeCleanupBlockerRootProjectMissing)
	}

	checkoutPath, hasCheckoutMetadata := storedManagedWorktreeCheckoutPath(worktree)
	canonicalCheckout := canonicalPathBestEffort(checkoutPath)
	managedRoot, rootErr := r.managedWorktreeCheckoutsRoot()
	projectManagedRoot := ""
	if rootErr == nil && strings.TrimSpace(worktree.RootProject.ID) != "" {
		projectManagedRoot = canonicalPathBestEffort(filepath.Join(managedRoot, worktree.RootProject.ID))
	}
	if !hasCheckoutMetadata || rootErr != nil || !realPathStrictlyWithin(managedRoot, canonicalCheckout) ||
		projectManagedRoot == "" || !realPathStrictlyWithin(projectManagedRoot, canonicalCheckout) ||
		!realPathWithin(canonicalCheckout, canonicalPathBestEffort(worktree.Path)) {
		addBlocker(worktreeCleanupBlockerOutsideManagedRoot)
	}
	checkoutExists := false
	if hasCheckoutMetadata {
		stat, err := os.Stat(checkoutPath)
		checkoutExists = err == nil && stat.IsDir()
		if os.IsNotExist(err) {
			addBlocker(worktreeCleanupBlockerCheckoutMissing)
		} else if err != nil || !stat.IsDir() {
			addBlocker(worktreeCleanupBlockerGitStateUnknown)
		}
	} else {
		addBlocker(worktreeCleanupBlockerCheckoutMissing)
	}

	identity := worktreeCleanupInstanceIdentity{}
	if checkoutExists {
		var identityOK bool
		identity, identityOK = r.managedWorktreeRepositoryIdentity(ctx, worktree, checkoutPath)
		if !identityOK {
			addBlocker(worktreeCleanupBlockerRepositoryMismatch)
		}
	} else {
		addBlocker(worktreeCleanupBlockerRepositoryMismatch)
	}

	if metadataComplete {
		lastActivity := worktree.CreatedAt
		if worktree.LastUsedAt.After(lastActivity) {
			lastActivity = worktree.LastUsedAt
		}
		if !lastActivity.Before(now.Add(-worktreeCleanupCandidateAfterDays * 24 * time.Hour)) {
			addBlocker(worktreeCleanupBlockerRecent)
		}
	}
	if keepLatest {
		addBlocker(worktreeCleanupBlockerKeepLatest)
	}
	switch descriptor.GitState {
	case worktreeGitStateDirty:
		addBlocker(worktreeCleanupBlockerGitDirty)
	case worktreeGitStateClean:
		// clean 是候选的必要条件，不额外添加 blocker。
	default:
		addBlocker(worktreeCleanupBlockerGitStateUnknown)
	}
	if r.managedWorktreeHasRunningSession(worktree) {
		addBlocker(worktreeCleanupBlockerSessionRunning)
	}
	if r.managedWorktreeHasPendingUseLocked(worktree) {
		// 移动端已会展示 session_running；pending start/resume/fork 在产品语义上
		// 同样是“会话正在建立”，复用稳定 blocker，不额外扩展公开枚举。
		addBlocker(worktreeCleanupBlockerSessionRunning)
	}
	item.Eligible = len(item.Blockers) == 0
	return item, identity
}

func cleanupKeepLatestPaths(worktrees map[string]managedWorktree) map[string]bool {
	byProject := map[string][]managedWorktree{}
	for _, worktree := range worktrees {
		key := strings.TrimSpace(worktree.RootProject.ID)
		if key == "" {
			key = "\x00" + worktree.Path
		}
		byProject[key] = append(byProject[key], worktree)
	}
	kept := map[string]bool{}
	for _, items := range byProject {
		sort.Slice(items, func(i, j int) bool {
			left, right := cleanupLastActivity(items[i]), cleanupLastActivity(items[j])
			if !left.Equal(right) {
				return left.After(right)
			}
			return items[i].Path < items[j].Path
		})
		limit := worktreeCleanupKeepLatestPerProject
		if len(items) < limit {
			limit = len(items)
		}
		for i := 0; i < limit; i++ {
			kept[items[i].Path] = true
		}
	}
	return kept
}

func cleanupLastActivity(worktree managedWorktree) time.Time {
	if worktree.LastUsedAt.After(worktree.CreatedAt) {
		return worktree.LastUsedAt
	}
	return worktree.CreatedAt
}

func (r *Router) managedWorktreeCheckoutsRoot() (string, error) {
	root, err := r.worktreesRoot()
	if err != nil {
		return "", err
	}
	return canonicalPathBestEffort(filepath.Join(root, "checkouts")), nil
}

func canonicalPathBestEffort(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return ""
	}
	if realPath, err := filepath.EvalSymlinks(abs); err == nil {
		return filepath.Clean(realPath)
	}
	return filepath.Clean(abs)
}

func realPathStrictlyWithin(root string, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator))
}

func (r *Router) managedWorktreeRepositoryIdentity(ctx context.Context, worktree managedWorktree, checkoutPath string) (worktreeCleanupInstanceIdentity, bool) {
	ctx, cancel := context.WithTimeout(ctx, worktreeStatusTimeout)
	defer cancel()
	identity := worktreeCleanupInstanceIdentity{}
	resolvedCheckout, ok := managedWorktreeCheckoutRootFromGit(ctx, checkoutPath)
	if !ok || resolvedCheckout != canonicalPathBestEffort(checkoutPath) {
		return identity, false
	}
	identity.CheckoutPath = resolvedCheckout
	identity.CheckoutObject, ok = filesystemObjectIdentity(resolvedCheckout)
	if !ok {
		return identity, false
	}
	checkoutCommon, ok := gitCommonDirectory(ctx, checkoutPath)
	if !ok {
		return identity, false
	}
	repositoryCommon, ok := gitCommonDirectory(ctx, worktree.RepositoryPath)
	if !ok || repositoryCommon != checkoutCommon {
		return identity, false
	}
	identity.GitDirectory, ok = gitDirectory(ctx, checkoutPath)
	if !ok {
		return identity, false
	}
	identity.GitObject, ok = filesystemObjectIdentity(identity.GitDirectory)
	if !ok {
		return identity, false
	}
	headRef, _, err := runGitReadOnly(ctx, checkoutPath, 4*1024, "symbolic-ref", "-q", "HEAD")
	if err != nil {
		return identity, false
	}
	identity.HeadRef = strings.TrimSpace(headRef)
	if identity.HeadRef == "" || identity.HeadRef != "refs/heads/"+strings.TrimSpace(worktree.Branch) {
		return identity, false
	}
	head, _, err := runGitReadOnly(ctx, checkoutPath, 4*1024, "rev-parse", "HEAD")
	if err != nil || strings.TrimSpace(head) == "" {
		return identity, false
	}
	identity.Head = strings.TrimSpace(head)
	registryFile, err := r.managedWorktreeRegistryFile(worktree.Path)
	if err != nil {
		return identity, false
	}
	identity.RegistryObject, ok = filesystemObjectIdentity(registryFile)
	if !ok {
		return identity, false
	}
	return identity, true
}

func gitDirectory(ctx context.Context, path string) (string, bool) {
	output, _, err := runGitReadOnly(ctx, path, 16*1024, "rev-parse", "--git-dir")
	if err != nil {
		return "", false
	}
	gitDir := strings.TrimSpace(output)
	if gitDir == "" {
		return "", false
	}
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(path, gitDir)
	}
	realGitDir, err := filepath.EvalSymlinks(gitDir)
	if err != nil {
		return "", false
	}
	return filepath.Clean(realGitDir), true
}

func filesystemObjectIdentity(path string) (string, bool) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", false
	}
	// FileInfo.Sys 在 Darwin/Linux 上都是含 Dev/Ino 的 Stat_t；通过
	// 反射读取可避免两个平台的具体 syscall 类型差异。如果平台
	// 不提供稳定对象 ID，则身份校验失败并 fail-closed。
	stat := reflect.ValueOf(info.Sys())
	if !stat.IsValid() {
		return "", false
	}
	if stat.Kind() == reflect.Pointer {
		if stat.IsNil() {
			return "", false
		}
		stat = stat.Elem()
	}
	if stat.Kind() != reflect.Struct {
		return "", false
	}
	dev, ok := numericStatField(stat.FieldByName("Dev"))
	if !ok {
		return "", false
	}
	ino, ok := numericStatField(stat.FieldByName("Ino"))
	if !ok {
		return "", false
	}
	// 只绑定稳定的文件系统对象身份与类型。Git 的只读 status/lock
	// 可能改变 linked-worktree gitdir 的 mtime/size，把它们放入指纹会
	// 让没有业务变化的 preview 也无法执行。remove/re-add 会换 inode，
	// registry 原子更新也会换 inode，因此 Dev+Ino 已足以识别实例替换。
	return fmt.Sprintf("dev=%s;ino=%s;type=%s", dev, ino, info.Mode().Type()), true
}

func numericStatField(value reflect.Value) (string, bool) {
	if !value.IsValid() {
		return "", false
	}
	switch value.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return fmt.Sprintf("%d", value.Int()), true
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return fmt.Sprintf("%d", value.Uint()), true
	default:
		return "", false
	}
}

func gitCommonDirectory(ctx context.Context, path string) (string, bool) {
	output, _, err := runGitReadOnly(ctx, path, 16*1024, "rev-parse", "--git-common-dir")
	if err != nil {
		return "", false
	}
	common := strings.TrimSpace(output)
	if common == "" {
		return "", false
	}
	if !filepath.IsAbs(common) {
		common = filepath.Join(path, common)
	}
	realCommon, err := filepath.EvalSymlinks(common)
	if err != nil {
		return "", false
	}
	return filepath.Clean(realCommon), true
}

func (r *Router) managedWorktreeHasRunningSession(worktree managedWorktree) bool {
	checkoutPath, ok := storedManagedWorktreeCheckoutPath(worktree)
	if !ok {
		return false
	}
	workspaceID := workspaceIDForRealPath(worktree.Path)
	if r.sessions != nil {
		for _, running := range r.sessions.ListUnsorted() {
			snapshot := running.Snapshot()
			if snapshot.Status != "running" && snapshot.Status != "stopping" {
				continue
			}
			if snapshot.ProjectID == workspaceID || realPathWithin(checkoutPath, canonicalPathBestEffort(snapshot.Dir)) {
				return true
			}
		}
	}

	// 生产主链路是 app-server gateway；它没有独立的运行态 REST 索引，因此
	// 对仍在 24h 授权缓存中的同 scope thread 做保守阻止，宁可多保留一天，
	// 也不在活跃 WebSocket/turn 期间移除 cwd。
	now := time.Now()
	r.gatewayThreadsMu.Lock()
	r.pruneGatewayThreadsLocked(now)
	defer r.gatewayThreadsMu.Unlock()
	for _, thread := range r.gatewayThreads {
		if thread.scopeID == workspaceID || realPathWithin(checkoutPath, canonicalPathBestEffort(thread.cwd)) {
			return true
		}
	}
	return false
}

func normalizedCleanupPaths(paths []string) ([]string, error) {
	if len(paths) == 0 {
		return nil, fmt.Errorf("实际清理的 paths 不能为空")
	}
	seen := map[string]struct{}{}
	out := make([]string, 0, len(paths))
	for _, raw := range paths {
		if raw == "" || raw != strings.TrimSpace(raw) || !filepath.IsAbs(raw) {
			return nil, fmt.Errorf("cleanup path 必须是未带首尾空白的绝对路径")
		}
		path := filepath.Clean(raw)
		if path != raw {
			return nil, fmt.Errorf("cleanup path 必须精确匹配 dry-run 候选：%s", raw)
		}
		if _, exists := seen[path]; exists {
			return nil, fmt.Errorf("cleanup paths 不能重复：%s", path)
		}
		seen[path] = struct{}{}
		out = append(out, path)
	}
	sort.Strings(out)
	return out, nil
}

func worktreeCleanupFingerprint(item worktreeCleanupItem, identity worktreeCleanupInstanceIdentity) string {
	payload := struct {
		Item     worktreeCleanupItem             `json:"item"`
		Identity worktreeCleanupInstanceIdentity `json:"identity"`
	}{Item: item, Identity: identity}
	data, _ := json.Marshal(payload)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func newWorktreeCleanupPlanID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return "wtc_" + hex.EncodeToString(value[:]), nil
}

func (r *Router) pruneWorktreeCleanupPlansLocked(now time.Time) {
	for id, plan := range r.managedWorktreeCleanupPlans {
		if !plan.ExpiresAt.After(now) {
			delete(r.managedWorktreeCleanupPlans, id)
		}
	}
}

func (r *Router) trimWorktreeCleanupPlansLocked() {
	for len(r.managedWorktreeCleanupPlans) > worktreeCleanupPlanLimit {
		oldestID := ""
		var oldest time.Time
		for id, plan := range r.managedWorktreeCleanupPlans {
			if oldestID == "" || plan.ExpiresAt.Before(oldest) {
				oldestID = id
				oldest = plan.ExpiresAt
			}
		}
		if oldestID == "" {
			return
		}
		delete(r.managedWorktreeCleanupPlans, oldestID)
	}
}

func worktreeCleanupResponseFromEvaluation(evaluation worktreeCleanupEvaluation, dryRun bool) worktreeCleanupResponse {
	return worktreeCleanupResponse{
		DryRun: dryRun,
		Policy: worktreeCleanupPolicy{
			AutoDelete:           false,
			CandidateAfterDays:   worktreeCleanupCandidateAfterDays,
			KeepLatestPerProject: worktreeCleanupKeepLatestPerProject,
		},
		GeneratedAt:    evaluation.GeneratedAt,
		Worktrees:      evaluation.Items,
		CandidatePaths: append([]string(nil), evaluation.Candidates...),
		DeletedPaths:   []string{},
	}
}

func cloneStringMap(value map[string]string) map[string]string {
	out := make(map[string]string, len(value))
	for key, item := range value {
		out[key] = item
	}
	return out
}

func cloneWorktreeCleanupIdentities(value map[string]worktreeCleanupInstanceIdentity) map[string]worktreeCleanupInstanceIdentity {
	out := make(map[string]worktreeCleanupInstanceIdentity, len(value))
	for key, item := range value {
		out[key] = item
	}
	return out
}
