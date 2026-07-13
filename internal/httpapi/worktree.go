package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

const worktreeCreateTimeout = 30 * time.Second
const worktreeStatusTimeout = 2 * time.Second
const managedWorktreeLastUsedWriteInterval = time.Hour

const managedWorktreeRegistryVersion = 1

const (
	worktreeGitStateClean   = "clean"
	worktreeGitStateDirty   = "dirty"
	worktreeGitStateUnknown = "unknown"
)

var errManagedWorktreeNotFound = errors.New("managed worktree not found")

type managedWorktreeRegistryCleanupError struct {
	Path string
	Err  error
}

func (e *managedWorktreeRegistryCleanupError) Error() string {
	return fmt.Sprintf("Worktree checkout 已删除，但 registry 登记清理失败：%v", e.Err)
}

func (e *managedWorktreeRegistryCleanupError) Unwrap() error {
	return e.Err
}

type worktreeBranchListRequest struct {
	Path string `json:"path"`
}

type worktreeBranchListResponse struct {
	Path          string               `json:"path"`
	DefaultBase   string               `json:"default_base,omitempty"`
	CurrentBranch string               `json:"current_branch,omitempty"`
	Branches      []worktreeBranchItem `json:"branches"`
}

type worktreeBranchItem struct {
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	IsCurrent bool   `json:"is_current,omitempty"`
	IsDefault bool   `json:"is_default,omitempty"`
}

type worktreeCreateRequest struct {
	Path   string `json:"path"`
	Name   string `json:"name,omitempty"`
	Base   string `json:"base,omitempty"`
	Branch string `json:"branch,omitempty"`
}

type worktreeListResponse struct {
	Worktrees []worktreeListItem `json:"worktrees"`
}

type worktreeListItem struct {
	Workspace workspaceDescriptor `json:"workspace"`
	Worktree  worktreeDescriptor  `json:"worktree"`
}

type worktreeDeleteRequest struct {
	Path  string `json:"path"`
	Force bool   `json:"force,omitempty"`
}

type worktreeDeleteResponse struct {
	DeletedPath          string               `json:"deleted_path"`
	Worktrees            []worktreeListItem   `json:"worktrees"`
	Workspace            *workspaceDescriptor `json:"workspace,omitempty"`
	Worktree             *worktreeDescriptor  `json:"worktree,omitempty"`
	RegistryCleanupError string               `json:"registry_cleanup_error,omitempty"`
}

type worktreePruneResponse struct {
	PrunedPaths []string           `json:"pruned_paths"`
	FailedPaths map[string]string  `json:"failed_paths,omitempty"`
	Worktrees   []worktreeListItem `json:"worktrees"`
}

type worktreeCreateResponse struct {
	Workspace workspaceDescriptor `json:"workspace"`
	Worktree  worktreeDescriptor  `json:"worktree"`
}

type worktreeDescriptor struct {
	Path            string `json:"path"`
	RepositoryPath  string `json:"repository_path"`
	Base            string `json:"base"`
	Branch          string `json:"branch,omitempty"`
	GitState        string `json:"git_state"`
	Dirty           bool   `json:"dirty,omitempty"`
	Ahead           int    `json:"ahead,omitempty"`
	Behind          int    `json:"behind,omitempty"`
	Upstream        string `json:"upstream,omitempty"`
	RootProjectID   string `json:"root_project_id"`
	RootProjectName string `json:"root_project_name"`
	RootProjectPath string `json:"root_project_path"`
}

type managedWorktree struct {
	Version        int              `json:"version,omitempty"`
	Path           string           `json:"path"`
	CheckoutPath   string           `json:"checkout_path,omitempty"`
	RepositoryPath string           `json:"repository_path"`
	Base           string           `json:"base"`
	Branch         string           `json:"branch,omitempty"`
	CreatedAt      time.Time        `json:"created_at,omitempty"`
	LastUsedAt     time.Time        `json:"last_used_at,omitempty"`
	RootProject    projects.Project `json:"root_project"`
	// LastUsedPersistFailed 只存在于当前进程内；实际访问时间未能落盘时，cleanup
	// 必须 fail-closed，不能继续使用磁盘上的旧时间判断候选资格。
	LastUsedPersistFailed bool      `json:"-"`
	LastUsedPersistedAt   time.Time `json:"-"`
}

func (r *Router) worktreeListHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, worktreeListResponse{
		Worktrees: r.managedWorktreeListItems(req.Context()),
	})
}

func (r *Router) worktreeBranchListHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload worktreeBranchListRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	stat, err := os.Stat(scope.realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "path 必须是目录")
		return
	}

	response, err := r.worktreeBranchList(req.Context(), scope.realPath)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) worktreeCreateHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload worktreeCreateRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if scope.browse || strings.TrimSpace(scope.project.ID) == "" {
		writeError(w, http.StatusBadRequest, "Worktree 只能从已配置项目创建")
		return
	}

	workspace, worktree, err := r.createManagedWorktree(req.Context(), scope, strings.TrimSpace(payload.Name), strings.TrimSpace(payload.Base), strings.TrimSpace(payload.Branch))
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, worktreeCreateResponse{
		Workspace: workspace,
		Worktree:  worktree,
	})
}

func (r *Router) worktreeDeleteHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload worktreeDeleteRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	if payload.Force {
		// 保留 force 字段仅用于兼容旧客户端 JSON；后端不再暴露强制
		// 删除能力，避免脏 checkout 中尚未提交的用户内容被 API 丢弃。
		writeError(w, http.StatusBadRequest, "force 删除已禁用，请先处理 Worktree 中的改动")
		return
	}
	deleted, err := r.deleteManagedWorktree(req.Context(), path, payload.Force)
	if err != nil {
		if errors.Is(err, errManagedWorktreeNotFound) {
			writeError(w, http.StatusForbidden, "只能删除 agentd 创建并登记过的 Worktree")
			return
		}
		var registryCleanupErr *managedWorktreeRegistryCleanupError
		if errors.As(err, &registryCleanupErr) {
			// checkout 的物理删除已经发生，因此仍返回 200 + deleted_path；
			// registry 失败通过可选字段告知客户端，避免通用客户端丢弃非 2xx body。
			writeJSON(w, http.StatusOK, worktreeDeleteResponse{
				DeletedPath:          deleted.Path,
				Worktrees:            r.managedWorktreeListItems(req.Context()),
				RegistryCleanupError: registryCleanupErr.Error(),
			})
			return
		}
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, worktreeDeleteResponse{
		DeletedPath: deleted.Path,
		Worktrees:   r.managedWorktreeListItems(req.Context()),
	})
}

func (r *Router) worktreePruneHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	pruned, failed := r.pruneMissingManagedWorktrees()
	writeJSON(w, http.StatusOK, worktreePruneResponse{
		PrunedPaths: pruned,
		FailedPaths: failed,
		Worktrees:   r.managedWorktreeListItems(req.Context()),
	})
}

func (r *Router) createManagedWorktree(ctx context.Context, scope gatewayScope, name string, base string, branch string) (workspaceDescriptor, worktreeDescriptor, error) {
	ctx, cancel := context.WithTimeout(ctx, worktreeCreateTimeout)
	defer cancel()

	if _, err := exec.LookPath("git"); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("git 不可用：%w", err)
	}
	repoRoot, _, err := runGitReadOnly(ctx, scope.realPath, 16*1024, "rev-parse", "--show-toplevel")
	if err != nil {
		if isGitRepositoryMissingError(err) {
			return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("当前工作区不是 Git 仓库")
		}
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}
	repoRoot = strings.TrimSpace(repoRoot)
	if repoRoot == "" {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("无法识别 Git 仓库根目录")
	}
	projectRel, err := filepath.Rel(repoRoot, scope.realPath)
	if err != nil || projectRel == ".." || strings.HasPrefix(projectRel, ".."+string(os.PathSeparator)) {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("项目路径不在 Git 仓库内")
	}

	baseRef := "HEAD"
	if base != "" {
		normalized, err := normalizedWorktreeBase(base)
		if err != nil {
			return workspaceDescriptor{}, worktreeDescriptor{}, err
		}
		baseRef = normalized
	}
	baseCommit, _, err := runGitReadOnly(ctx, repoRoot, 16*1024, "rev-parse", "--verify", baseRef+"^{commit}")
	if err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("base 不是有效提交：%w", err)
	}
	baseCommit = strings.TrimSpace(baseCommit)
	if baseCommit == "" {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("base 没有解析到有效提交")
	}
	// 创建与回滚都绑定同一个确切 SHA，避免 base 引用在过程中移动。
	commitish := baseCommit

	root, err := r.worktreesRoot()
	if err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}
	projectRoot := filepath.Join(root, "checkouts", scope.project.ID)
	if err := os.MkdirAll(projectRoot, 0o755); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("创建 worktree 根目录失败：%w", err)
	}
	slug := sanitizedWorktreeName(firstNonEmpty(name, scope.project.Name))
	timestamp := time.Now().UTC().Format("20060102-150405")
	branchName, err := r.worktreeBranchName(ctx, repoRoot, branch, firstNonEmpty(name, scope.project.Name), timestamp)
	if err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}
	target := filepath.Join(projectRoot, fmt.Sprintf("%s-%s", slug, timestamp))
	for i := 2; pathExists(target); i++ {
		target = filepath.Join(projectRoot, fmt.Sprintf("%s-%s-%d", slug, timestamp, i))
	}

	if _, _, err := runGitCommand(ctx, repoRoot, 32*1024, "worktree", "add", "-b", branchName, target, commitish); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}
	realCheckoutPath, err := filepath.EvalSymlinks(target)
	if err != nil {
		cause := fmt.Errorf("读取 worktree checkout 根目录失败：%w", err)
		return workspaceDescriptor{}, worktreeDescriptor{}, rollbackCreatedManagedWorktree(repoRoot, target, branchName, baseCommit, cause)
	}
	workspacePath := realCheckoutPath
	if projectRel != "." {
		workspacePath = filepath.Join(realCheckoutPath, projectRel)
	}
	realWorkspacePath, err := filepath.EvalSymlinks(workspacePath)
	if err != nil {
		cause := fmt.Errorf("读取 worktree 路径失败：%w", err)
		return workspaceDescriptor{}, worktreeDescriptor{}, rollbackCreatedManagedWorktree(repoRoot, realCheckoutPath, branchName, baseCommit, cause)
	}
	now := time.Now().UTC()
	worktree := managedWorktree{
		Version:        managedWorktreeRegistryVersion,
		Path:           realWorkspacePath,
		CheckoutPath:   realCheckoutPath,
		RepositoryPath: repoRoot,
		Base:           baseRef,
		Branch:         branchName,
		CreatedAt:      now,
		LastUsedAt:     now,
		RootProject:    scope.project,
	}
	if err := r.registerManagedWorktree(worktree); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, rollbackCreatedManagedWorktree(repoRoot, realCheckoutPath, branchName, baseCommit, err)
	}

	workspace := workspaceDescriptor{
		ID:              workspaceIDForRealPath(realWorkspacePath),
		Name:            filepath.Base(realWorkspacePath),
		Path:            realWorkspacePath,
		RootProjectID:   scope.project.ID,
		RootProjectName: scope.project.Name,
		RootProjectPath: scope.project.Path,
		Trusted:         true,
		CanStartSession: true,
	}
	return workspace, worktreeDescriptorForManagedWorktree(ctx, worktree), nil
}

func rollbackCreatedManagedWorktree(repoRoot string, checkoutPath string, branch string, expectedBranchTip string, cause error) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// 这里只会在 `git worktree add -b` 已成功、但 API 尚未返回的窗口调用；
	// branchName 在 add 前已确认不存在，因此回滚只处理本次刚创建的分支。
	// checkout 坚持普通 remove，hook 若留下改动则立即停止；checkout 删除后，
	// 分支使用 update-ref 的 old-value 条件删除，只有 tip 仍等于创建时 base SHA
	// 才会成功。这既能回滚未合并 base，又不会误删 hook/外部新提交。
	failures := make([]string, 0, 2)
	checkoutRemoved := true
	if _, _, err := runGitCommand(ctx, repoRoot, 32*1024, "worktree", "remove", checkoutPath); err != nil {
		checkoutRemoved = false
		failures = append(failures, "删除新 checkout 失败："+err.Error())
	}
	ref := "refs/heads/" + branch
	if checkoutRemoved && worktreeBranchExists(ctx, repoRoot, branch) {
		if _, _, err := runGitCommand(ctx, repoRoot, 16*1024, "update-ref", "-d", ref, expectedBranchTip); err != nil {
			failures = append(failures, "删除新分支失败（tip 可能已变化，已保留现场）："+err.Error())
		}
	}
	if len(failures) == 0 {
		return fmt.Errorf("创建 Worktree 后处理失败：%v；回滚成功，已删除本次 checkout 和新分支", cause)
	}
	return fmt.Errorf("创建 Worktree 后处理失败：%v；回滚未完全成功：%s", cause, strings.Join(failures, "；"))
}

func (r *Router) pruneMissingManagedWorktrees() ([]string, map[string]string) {
	r.managedWorktreeCleanupMu.Lock()
	defer r.managedWorktreeCleanupMu.Unlock()

	items := r.managedWorktreeMapFromRegistryRaw()
	r.managedWorktreesMu.Lock()
	for path, worktree := range r.managedWorktrees {
		items[path] = worktree
	}
	r.managedWorktreesMu.Unlock()

	pruned := make([]string, 0)
	failed := map[string]string{}
	for path, worktree := range items {
		checkoutPath, ok := storedManagedWorktreeCheckoutPath(worktree)
		if !ok {
			// 旧 registry 没有 checkout_path 时，只有 Git 仍能从 workspace
			// 可靠解析出仓库顶层才允许继续判断；解析失败必须保留登记，避免把
			// “项目子目录消失”或“仓库暂时不可访问”误判成整个 checkout 已删除。
			ctx, cancel := context.WithTimeout(context.Background(), worktreeStatusTimeout)
			checkoutPath, ok = managedWorktreeCheckoutRootFromGit(ctx, worktree.Path)
			cancel()
		}
		if !ok {
			continue
		}
		if _, err := os.Stat(checkoutPath); os.IsNotExist(err) {
			if err := r.unregisterManagedWorktree(path); err != nil {
				failed[path] = err.Error()
				continue
			}
			pruned = append(pruned, path)
		}
	}
	sort.Strings(pruned)
	return pruned, failed
}

func storedManagedWorktreeCheckoutPath(worktree managedWorktree) (string, bool) {
	if worktree.Version != managedWorktreeRegistryVersion {
		return "", false
	}
	path := strings.TrimSpace(worktree.CheckoutPath)
	if path == "" || !filepath.IsAbs(path) {
		return "", false
	}
	return filepath.Clean(path), true
}

func managedWorktreeCheckoutRootFromGit(ctx context.Context, path string) (string, bool) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", false
	}
	root, _, err := runGitReadOnly(ctx, path, 16*1024, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", false
	}
	root = strings.TrimSpace(root)
	if root == "" {
		return "", false
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", false
	}
	stat, err := os.Stat(realRoot)
	if err != nil || !stat.IsDir() {
		return "", false
	}
	return filepath.Clean(realRoot), true
}

func (r *Router) deleteManagedWorktree(ctx context.Context, rawPath string, force bool) (managedWorktree, error) {
	r.managedWorktreeCleanupMu.Lock()
	defer r.managedWorktreeCleanupMu.Unlock()
	return r.deleteManagedWorktreeLocked(ctx, rawPath, force)
}

// deleteManagedWorktreeLocked 要求调用方已持有 managedWorktreeCleanupMu。
// cleanup execute 需要在“整体预检 -> 逐项删除”全程保持同一个临界区；
// 普通 delete API 则通过上层包装获取该锁，避免与新 gateway scope 竞态。
func (r *Router) deleteManagedWorktreeLocked(ctx context.Context, rawPath string, force bool) (managedWorktree, error) {
	return r.deleteManagedWorktreeWithExpectedIdentity(ctx, rawPath, force, nil)
}

func (r *Router) deleteManagedWorktreeWithExpectedIdentityLocked(ctx context.Context, rawPath string, force bool, expected worktreeCleanupInstanceIdentity) (managedWorktree, error) {
	return r.deleteManagedWorktreeWithExpectedIdentity(ctx, rawPath, force, &expected)
}

func (r *Router) deleteManagedWorktreeWithExpectedIdentity(ctx context.Context, rawPath string, force bool, expected *worktreeCleanupInstanceIdentity) (managedWorktree, error) {
	if force {
		return managedWorktree{}, fmt.Errorf("force 删除已禁用")
	}
	ctx, cancel := context.WithTimeout(ctx, worktreeCreateTimeout)
	defer cancel()

	worktree, ok := r.managedWorktreeByExactPath(rawPath)
	if !ok {
		return managedWorktree{}, errManagedWorktreeNotFound
	}
	if r.managedWorktreeHasPendingUseLocked(worktree) {
		return managedWorktree{}, fmt.Errorf("Worktree 仍有正在建立的 gateway thread 请求，拒绝删除")
	}

	checkoutCandidate, hasStoredCheckout := storedManagedWorktreeCheckoutPath(worktree)
	if hasStoredCheckout {
		if _, err := os.Stat(checkoutCandidate); os.IsNotExist(err) {
			if err := r.unregisterManagedWorktree(worktree.Path); err != nil {
				return worktree, &managedWorktreeRegistryCleanupError{Path: worktree.Path, Err: err}
			}
			return worktree, nil
		}
	} else {
		// 旧 registry 只能从仍存在的 workspace 解析 checkout 根；解析失败时
		// 宁可拒绝删除，也不能只丢掉登记后留下一个无人管理的真实 checkout。
		checkoutCandidate = worktree.Path
	}
	if _, err := exec.LookPath("git"); err != nil {
		return managedWorktree{}, fmt.Errorf("git 不可用：%w", err)
	}
	checkoutRoot, ok := managedWorktreeCheckoutRootFromGit(ctx, checkoutCandidate)
	if !ok {
		return managedWorktree{}, fmt.Errorf("无法安全识别 Worktree checkout 根目录")
	}
	if !force {
		managedRoot, err := r.managedWorktreeCheckoutsRoot()
		projectManagedRoot := canonicalPathBestEffort(filepath.Join(managedRoot, worktree.RootProject.ID))
		canonicalCheckout := canonicalPathBestEffort(checkoutRoot)
		if err != nil || !realPathStrictlyWithin(managedRoot, canonicalCheckout) ||
			!realPathStrictlyWithin(projectManagedRoot, canonicalCheckout) ||
			!realPathWithin(canonicalCheckout, canonicalPathBestEffort(worktree.Path)) {
			return managedWorktree{}, fmt.Errorf("Worktree checkout 不在 agentd managed root 内，拒绝删除")
		}
		identity, identityOK := r.managedWorktreeRepositoryIdentity(ctx, worktree, checkoutRoot)
		if !identityOK || (expected != nil && identity != *expected) {
			return managedWorktree{}, fmt.Errorf("Worktree repository identity 已变化，拒绝删除")
		}
		// cleanup 的批量预检之后仍可能有直接 session 启动；Git remove
		// 紧前再检查一次，与 managedWorktreeForPath 的 cleanup 锁共同缩小竞态窗口。
		if r.managedWorktreeHasRunningSession(worktree) {
			return managedWorktree{}, fmt.Errorf("Worktree 仍有运行中的 session 或 gateway thread，拒绝删除")
		}
		// session 检查期间外部 Git 仍可替换同路径 checkout；在真正
		// `git worktree remove` 紧前再绑定一次 dry-run 的那个具体实例。
		identity, identityOK = r.managedWorktreeRepositoryIdentity(ctx, worktree, checkoutRoot)
		if !identityOK || (expected != nil && identity != *expected) {
			return managedWorktree{}, fmt.Errorf("Worktree 实例在删除前已变化，拒绝删除")
		}
	}

	commandDir := worktree.RepositoryPath
	if _, err := os.Stat(commandDir); err != nil {
		return managedWorktree{}, fmt.Errorf("原始仓库不可访问，无法安全删除 worktree：%w", err)
	}
	args := []string{"worktree", "remove", checkoutRoot}
	if _, _, err := runGitCommand(ctx, commandDir, 32*1024, args...); err != nil {
		return managedWorktree{}, err
	}
	if err := r.unregisterManagedWorktree(worktree.Path); err != nil {
		return worktree, &managedWorktreeRegistryCleanupError{Path: worktree.Path, Err: err}
	}
	return worktree, nil
}

func (r *Router) registerManagedWorktree(worktree managedWorktree) error {
	if strings.TrimSpace(worktree.Path) == "" || strings.TrimSpace(worktree.RootProject.ID) == "" {
		return fmt.Errorf("worktree 元数据不完整")
	}
	file, err := r.managedWorktreeRegistryFile(worktree.Path)
	if err != nil {
		return err
	}
	if err := writeManagedWorktreeRegistryFile(file, worktree); err != nil {
		return err
	}

	// 只有 registry 已经原子落盘后才能开放到内存 allowlist；否则 API 虽然
	// 返回失败，当前进程却仍会把一个无法跨重启恢复的 checkout 当成已管理。
	worktree.LastUsedPersistedAt = worktree.LastUsedAt
	r.managedWorktreesMu.Lock()
	r.managedWorktrees[worktree.Path] = worktree
	r.managedWorktreesMu.Unlock()
	return nil
}

func (r *Router) managedWorktreeRegistryFile(path string) (string, error) {
	root, err := r.worktreesRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "registry", workspaceIDForRealPath(path)+".json"), nil
}

func writeManagedWorktreeRegistryFile(file string, worktree managedWorktree) error {
	registryDir := filepath.Dir(file)
	if err := os.MkdirAll(registryDir, 0o755); err != nil {
		return fmt.Errorf("创建 worktree registry 失败：%w", err)
	}
	data, err := json.MarshalIndent(worktree, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化 worktree registry 失败：%w", err)
	}

	temporary, err := os.CreateTemp(registryDir, ".worktree-*.tmp")
	if err != nil {
		return fmt.Errorf("创建 worktree registry 临时文件失败：%w", err)
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return fmt.Errorf("设置 worktree registry 权限失败：%w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		return fmt.Errorf("写入 worktree registry 临时文件失败：%w", err)
	}
	if err := temporary.Sync(); err != nil {
		return fmt.Errorf("同步 worktree registry 临时文件失败：%w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("关闭 worktree registry 临时文件失败：%w", err)
	}
	if err := os.Rename(temporaryPath, file); err != nil {
		return fmt.Errorf("提交 worktree registry 失败：%w", err)
	}
	committed = true
	return nil
}

func (r *Router) unregisterManagedWorktree(path string) error {
	file, err := r.managedWorktreeRegistryFile(path)
	if err != nil {
		return fmt.Errorf("定位 worktree registry 失败：%w", err)
	}
	remove := os.Remove
	if r.managedWorktreeRegistryRemove != nil {
		remove = r.managedWorktreeRegistryRemove
	}
	if err := remove(file); err != nil && !os.IsNotExist(err) {
		// 先保留内存登记，确保 list/prune 仍能看到这个陈旧项并允许用户重试；
		// 不能在磁盘登记还存在时只清当前进程状态，造成重启前后表现不一致。
		return fmt.Errorf("删除 worktree registry 失败：%w", err)
	}

	r.managedWorktreesMu.Lock()
	delete(r.managedWorktrees, path)
	r.managedWorktreesMu.Unlock()
	return nil
}

func (r *Router) managedWorktreeForPath(realPath string) (managedWorktree, bool) {
	// cleanup execute 在预检到删除完成期间持有同一把锁。
	// 先到的实际访问会被 LastUsedAt 指纹捕获；先到的 cleanup
	// 则会阻塞新 scope 解析，直到 checkout 保留或已安全删除。
	r.managedWorktreeCleanupMu.Lock()
	defer r.managedWorktreeCleanupMu.Unlock()
	return r.managedWorktreeForPathLocked(realPath)
}

// managedWorktreeForPathLocked 要求调用方已持有 managedWorktreeCleanupMu，
// 便于 Gateway 在同一临界区内完成路径授权、LastUsedAt 更新和 pending-use 登记。
func (r *Router) managedWorktreeForPathLocked(realPath string) (managedWorktree, bool) {
	if worktree, ok := r.managedWorktreeForPathFromMemory(realPath); ok {
		worktree = r.touchManagedWorktreeAt(worktree, time.Now().UTC())
		r.cacheManagedWorktree(worktree)
		return worktree, true
	}
	if worktree, ok := r.managedWorktreeForPathFromRegistry(realPath); ok {
		worktree = r.touchManagedWorktreeAt(worktree, time.Now().UTC())
		r.cacheManagedWorktree(worktree)
		return worktree, true
	}
	return managedWorktree{}, false
}

func (r *Router) acquireManagedWorktreePendingUseLocked(path string) {
	path = filepath.Clean(strings.TrimSpace(path))
	if path == "." || path == "" {
		return
	}
	if r.managedWorktreePendingUses == nil {
		r.managedWorktreePendingUses = map[string]int{}
	}
	r.managedWorktreePendingUses[path]++
}

func (r *Router) releaseManagedWorktreePendingUse(path string) {
	path = filepath.Clean(strings.TrimSpace(path))
	if path == "." || path == "" {
		return
	}
	r.managedWorktreeCleanupMu.Lock()
	r.releaseManagedWorktreePendingUseLocked(path)
	r.managedWorktreeCleanupMu.Unlock()
}

func (r *Router) releaseManagedWorktreePendingUseLocked(path string) {
	count := r.managedWorktreePendingUses[path]
	if count <= 1 {
		delete(r.managedWorktreePendingUses, path)
		return
	}
	r.managedWorktreePendingUses[path] = count - 1
}

func (r *Router) managedWorktreeHasPendingUseLocked(worktree managedWorktree) bool {
	return r.managedWorktreePendingUses[filepath.Clean(worktree.Path)] > 0
}

func (r *Router) cacheManagedWorktree(worktree managedWorktree) {
	r.managedWorktreesMu.Lock()
	r.managedWorktrees[worktree.Path] = worktree
	r.managedWorktreesMu.Unlock()
}

func (r *Router) touchManagedWorktreeAt(worktree managedWorktree, now time.Time) managedWorktree {
	if worktree.Version != managedWorktreeRegistryVersion || worktree.LastUsedAt.IsZero() {
		return worktree
	}
	now = now.UTC()
	if !now.After(worktree.LastUsedAt) {
		return worktree
	}
	updated := worktree
	// 每次真实访问都先推进进程内时间，让 cleanup 的二次确认能
	// 立即发现预览后的使用；磁盘写入仍基于独立的已持久化基线限制为每小时一次。
	updated.LastUsedAt = now
	persistedAt := worktree.LastUsedPersistedAt
	if persistedAt.IsZero() {
		persistedAt = worktree.LastUsedAt
	}
	updated.LastUsedPersistedAt = persistedAt
	if !worktree.LastUsedPersistFailed && now.Sub(persistedAt) < managedWorktreeLastUsedWriteInterval {
		return updated
	}
	updated.LastUsedPersistFailed = false
	file, err := r.managedWorktreeRegistryFile(updated.Path)
	if err != nil {
		updated.LastUsedPersistFailed = true
		return updated
	}
	// LastUsedAt 只是保留策略证据，不能反过来影响正常请求；持久化失败时
	// 保留旧值并继续使用原 worktree，下一次实际访问仍会重试。
	if err := writeManagedWorktreeRegistryFile(file, updated); err != nil {
		updated.LastUsedPersistFailed = true
		return updated
	}
	updated.LastUsedPersistedAt = now
	return updated
}

func (r *Router) managedWorktreeForPathFromMemory(realPath string) (managedWorktree, bool) {
	r.managedWorktreesMu.Lock()
	defer r.managedWorktreesMu.Unlock()
	return managedWorktreeForPathInMap(r.managedWorktrees, realPath)
}

func (r *Router) managedWorktreeForPathFromRegistry(realPath string) (managedWorktree, bool) {
	items := r.managedWorktreeMapFromRegistry(true)
	return managedWorktreeForPathInMap(items, realPath)
}

func (r *Router) managedWorktreeByExactPath(rawPath string) (managedWorktree, bool) {
	path := strings.TrimSpace(rawPath)
	if path == "" {
		return managedWorktree{}, false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return managedWorktree{}, false
	}
	candidates := []string{filepath.Clean(abs)}
	if realPath, err := filepath.EvalSymlinks(abs); err == nil {
		candidates = append(candidates, filepath.Clean(realPath))
	}
	items := r.allManagedWorktreeMap(false)
	for _, candidate := range candidates {
		if worktree, ok := items[candidate]; ok {
			return worktree, true
		}
	}
	return managedWorktree{}, false
}

func (r *Router) managedWorktreeListItems(ctx context.Context) []worktreeListItem {
	items := r.allManagedWorktreeMap(true)
	worktrees := make([]managedWorktree, 0, len(items))
	for _, worktree := range items {
		worktrees = append(worktrees, worktree)
	}
	sort.Slice(worktrees, func(i, j int) bool {
		if worktrees[i].RootProject.Name != worktrees[j].RootProject.Name {
			return worktrees[i].RootProject.Name < worktrees[j].RootProject.Name
		}
		return worktrees[i].Path < worktrees[j].Path
	})
	out := make([]worktreeListItem, 0, len(worktrees))
	for _, worktree := range worktrees {
		out = append(out, worktreeListItem{
			Workspace: workspaceDescriptorForManagedWorktree(worktree),
			Worktree:  worktreeDescriptorForManagedWorktree(ctx, worktree),
		})
	}
	return out
}

func (r *Router) allManagedWorktreeMap(existingOnly bool) map[string]managedWorktree {
	items := r.managedWorktreeMapFromRegistry(existingOnly)
	r.managedWorktreesMu.Lock()
	defer r.managedWorktreesMu.Unlock()
	for path, worktree := range r.managedWorktrees {
		if existingOnly {
			if _, err := os.Stat(worktree.Path); err != nil {
				continue
			}
		}
		project, ok := r.projects.Get(worktree.RootProject.ID)
		if !ok {
			continue
		}
		worktree.RootProject = project
		items[path] = worktree
	}
	return items
}

func (r *Router) managedWorktreeMapFromRegistry(existingOnly bool) map[string]managedWorktree {
	items := map[string]managedWorktree{}
	for path, worktree := range r.managedWorktreeMapFromRegistryRaw() {
		project, ok := r.projects.Get(worktree.RootProject.ID)
		if !ok {
			continue
		}
		worktree.RootProject = project
		if existingOnly {
			if _, err := os.Stat(worktree.Path); err != nil {
				continue
			}
		}
		items[path] = worktree
	}
	return items
}

func (r *Router) managedWorktreeMapFromRegistryRaw() map[string]managedWorktree {
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
		worktree = migrateLegacyManagedWorktree(file, worktree)
		items[worktree.Path] = worktree
	}
	return items
}

func migrateLegacyManagedWorktree(file string, worktree managedWorktree) managedWorktree {
	if worktree.Version > managedWorktreeRegistryVersion {
		// 不覆盖未来版本字段；当前进程无法证明其语义时按 unknown 使用。
		return worktree
	}
	if worktree.Version == managedWorktreeRegistryVersion &&
		strings.TrimSpace(worktree.CheckoutPath) != "" &&
		!worktree.CreatedAt.IsZero() && !worktree.LastUsedAt.IsZero() {
		return worktree
	}

	ctx, cancel := context.WithTimeout(context.Background(), worktreeStatusTimeout)
	checkoutPath, ok := managedWorktreeCheckoutRootFromGit(ctx, worktree.Path)
	cancel()
	if !ok {
		// workspace 已不存在或 Git 暂时不可用时不能猜 checkout 根；保留旧数据，
		// 让后续状态明确表现为 legacy/unknown，而不是伪造可清理证据。
		return worktree
	}

	now := time.Now().UTC()
	migrated := worktree
	migrated.Version = managedWorktreeRegistryVersion
	migrated.CheckoutPath = checkoutPath
	if migrated.CreatedAt.IsZero() {
		// 旧格式没有可信创建时间；不能把 registry mtime 当成未来清理依据，
		// 统一从迁移时重新开始计算最短保留周期。
		migrated.CreatedAt = now
	}
	if migrated.LastUsedAt.IsZero() {
		// 旧格式没有可靠的最后使用时间；迁移时按“刚使用”处理最保守，未来
		// 即使接入保留策略，也不会因缺失时间戳立即成为删除候选。
		migrated.LastUsedAt = now
	}
	if err := writeManagedWorktreeRegistryFile(file, migrated); err != nil {
		return worktree
	}
	return migrated
}

func managedWorktreeForPathInMap(items map[string]managedWorktree, realPath string) (managedWorktree, bool) {
	var best managedWorktree
	bestDepth := -1
	for _, worktree := range items {
		if !realPathWithin(worktree.Path, realPath) {
			continue
		}
		depth := strings.Count(filepath.Clean(worktree.Path), string(os.PathSeparator))
		if depth > bestDepth {
			best = worktree
			bestDepth = depth
		}
	}
	return best, bestDepth >= 0
}

func workspaceDescriptorForManagedWorktree(worktree managedWorktree) workspaceDescriptor {
	return workspaceDescriptor{
		ID:              workspaceIDForRealPath(worktree.Path),
		Name:            filepath.Base(worktree.Path),
		Path:            worktree.Path,
		RootProjectID:   worktree.RootProject.ID,
		RootProjectName: worktree.RootProject.Name,
		RootProjectPath: worktree.RootProject.Path,
		Trusted:         true,
		CanStartSession: true,
	}
}

func worktreeDescriptorForManagedWorktree(ctx context.Context, worktree managedWorktree) worktreeDescriptor {
	descriptor := worktreeDescriptor{
		Path:            worktree.Path,
		RepositoryPath:  worktree.RepositoryPath,
		Base:            worktree.Base,
		Branch:          worktree.Branch,
		GitState:        worktreeGitStateUnknown,
		RootProjectID:   worktree.RootProject.ID,
		RootProjectName: worktree.RootProject.Name,
		RootProjectPath: worktree.RootProject.Path,
	}
	gitState, ahead, behind, upstream := managedWorktreeGitState(ctx, worktree)
	descriptor.GitState = gitState
	descriptor.Dirty = gitState == worktreeGitStateDirty
	descriptor.Ahead = ahead
	descriptor.Behind = behind
	descriptor.Upstream = upstream
	return descriptor
}

func managedWorktreeGitState(ctx context.Context, worktree managedWorktree) (string, int, int, string) {
	ctx, cancel := context.WithTimeout(ctx, worktreeStatusTimeout)
	defer cancel()

	if _, err := exec.LookPath("git"); err != nil {
		return worktreeGitStateUnknown, 0, 0, ""
	}
	checkoutPath, ok := storedManagedWorktreeCheckoutPath(worktree)
	if !ok {
		checkoutPath, ok = managedWorktreeCheckoutRootFromGit(ctx, worktree.Path)
	}
	if !ok {
		return worktreeGitStateUnknown, 0, 0, ""
	}

	// clean 必须来自完整 checkout 的一次成功 Git 状态检查。不能在项目子目录
	// 带 pathspec 执行，否则同一仓库其他目录的改动会被错误隐藏；命令失败也
	// 不能再折叠为 dirty=false。
	status, _, err := runGitReadOnly(ctx, checkoutPath, 32*1024, "status", "--porcelain=v1", "--untracked-files=all")
	if err != nil {
		return worktreeGitStateUnknown, 0, 0, ""
	}
	gitState := worktreeGitStateClean
	if strings.TrimSpace(status) != "" {
		gitState = worktreeGitStateDirty
	}

	upstreamOutput, _, err := runGitReadOnly(ctx, checkoutPath, 4*1024, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
	if err != nil {
		return gitState, 0, 0, ""
	}
	upstream := strings.TrimSpace(upstreamOutput)
	if upstream == "" {
		return gitState, 0, 0, ""
	}

	counts, _, err := runGitReadOnly(ctx, checkoutPath, 4*1024, "rev-list", "--left-right", "--count", upstream+"...HEAD")
	if err != nil {
		return gitState, 0, 0, upstream
	}
	behind, ahead := parseAheadBehindCounts(counts)
	return gitState, ahead, behind, upstream
}

func parseAheadBehindCounts(output string) (int, int) {
	fields := strings.Fields(output)
	if len(fields) < 2 {
		return 0, 0
	}
	behind, _ := strconv.Atoi(fields[0])
	ahead, _ := strconv.Atoi(fields[1])
	return ahead, behind
}

func (r *Router) worktreesRoot() (string, error) {
	if value := strings.TrimSpace(r.cfg.WorktreesRoot); value != "" {
		abs, err := filepath.Abs(value)
		if err != nil {
			return "", fmt.Errorf("解析 worktrees_root 失败：%w", err)
		}
		return abs, nil
	}
	dir, err := config.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("定位用户配置目录失败：%w", err)
	}
	return filepath.Join(dir, "worktrees"), nil
}

func (r *Router) worktreeBranchList(ctx context.Context, realPath string) (worktreeBranchListResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, gitStatusCommandTimeout)
	defer cancel()

	response := worktreeBranchListResponse{
		Path:     realPath,
		Branches: []worktreeBranchItem{},
	}
	if _, err := exec.LookPath("git"); err != nil {
		return response, fmt.Errorf("git 不可用：%w", err)
	}
	repoRoot, _, err := runGitReadOnly(ctx, realPath, 16*1024, "rev-parse", "--show-toplevel")
	if err != nil {
		if isGitRepositoryMissingError(err) {
			return response, nil
		}
		return response, err
	}
	repoRoot = strings.TrimSpace(repoRoot)
	if repoRoot == "" {
		return response, nil
	}

	currentBranch, _, _ := runGitReadOnly(ctx, repoRoot, 4*1024, "branch", "--show-current")
	response.CurrentBranch = strings.TrimSpace(currentBranch)
	remoteDefault := worktreeRemoteDefaultBranch(ctx, repoRoot)

	// 分支列表只读本机已有 refs，不自动 fetch；移动端展示建议值，但仍允许用户手填任何有效 base。
	items := map[string]worktreeBranchItem{}
	if localOutput, _, err := runGitReadOnly(ctx, repoRoot, 64*1024, "branch", "--format=%(refname:short)|%(HEAD)"); err == nil {
		addWorktreeBranches(items, localOutput, "local", response.CurrentBranch)
	}
	if remoteOutput, _, err := runGitReadOnly(ctx, repoRoot, 64*1024, "branch", "-r", "--format=%(refname:short)|%(HEAD)"); err == nil {
		addWorktreeBranches(items, remoteOutput, "remote", "")
	}

	branches := make([]worktreeBranchItem, 0, len(items))
	for _, item := range items {
		branches = append(branches, item)
	}
	sortWorktreeBranches(branches)
	response.DefaultBase = defaultWorktreeBase(response.CurrentBranch, remoteDefault, branches)
	for i := range branches {
		branches[i].IsDefault = branches[i].Name == response.DefaultBase
	}
	response.Branches = branches
	return response, nil
}

func addWorktreeBranches(items map[string]worktreeBranchItem, output string, kind string, currentBranch string) {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 2)
		name := strings.TrimSpace(parts[0])
		if name == "" || strings.Contains(name, " -> ") || strings.HasSuffix(name, "/HEAD") {
			continue
		}
		key := kind + ":" + name
		if _, exists := items[key]; exists {
			continue
		}
		isCurrent := kind == "local" && name == currentBranch
		if len(parts) > 1 && strings.TrimSpace(parts[1]) == "*" {
			isCurrent = true
		}
		items[key] = worktreeBranchItem{
			Name:      name,
			Kind:      kind,
			IsCurrent: isCurrent,
		}
	}
}

func sortWorktreeBranches(branches []worktreeBranchItem) {
	sort.Slice(branches, func(i, j int) bool {
		if branches[i].IsCurrent != branches[j].IsCurrent {
			return branches[i].IsCurrent
		}
		if branches[i].Kind != branches[j].Kind {
			return branches[i].Kind == "local"
		}
		return branches[i].Name < branches[j].Name
	})
}

func worktreeRemoteDefaultBranch(ctx context.Context, repoRoot string) string {
	output, _, err := runGitReadOnly(ctx, repoRoot, 4*1024, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(output)
}

func defaultWorktreeBase(currentBranch string, remoteDefault string, branches []worktreeBranchItem) string {
	if currentBranch != "" {
		return currentBranch
	}
	if remoteDefault != "" {
		return remoteDefault
	}
	for _, preferred := range []string{"main", "master", "origin/main", "origin/master"} {
		for _, item := range branches {
			if item.Name == preferred {
				return item.Name
			}
		}
	}
	if len(branches) > 0 {
		return branches[0].Name
	}
	return ""
}

func normalizedWorktreeBase(base string) (string, error) {
	value := strings.TrimSpace(base)
	if value == "" {
		return "", fmt.Errorf("base 不能为空")
	}
	if strings.ContainsRune(value, '\x00') || strings.HasPrefix(value, "-") || strings.ContainsAny(value, " \t\r\n") {
		return "", fmt.Errorf("base 不是安全的 Git 引用")
	}
	if len([]rune(value)) > 160 {
		return "", fmt.Errorf("base 过长")
	}
	return value, nil
}

func (r *Router) worktreeBranchName(ctx context.Context, repoRoot string, requested string, fallback string, timestamp string) (string, error) {
	if branch := strings.TrimSpace(requested); branch != "" {
		if err := validateWorktreeBranchName(ctx, repoRoot, branch); err != nil {
			return "", err
		}
		if worktreeBranchExists(ctx, repoRoot, branch) {
			return "", fmt.Errorf("branch 已存在：%s", branch)
		}
		return branch, nil
	}

	slug := sanitizedWorktreeBranchSlug(fallback)
	for i := 1; i <= 100; i++ {
		name := fmt.Sprintf("mimi/%s-%s", slug, timestamp)
		if i > 1 {
			name = fmt.Sprintf("mimi/%s-%s-%d", slug, timestamp, i)
		}
		if err := validateWorktreeBranchName(ctx, repoRoot, name); err != nil {
			return "", err
		}
		if worktreeBranchExists(ctx, repoRoot, name) {
			continue
		}
		return name, nil
	}
	return "", fmt.Errorf("无法生成唯一 Worktree 分支名")
}

func validateWorktreeBranchName(ctx context.Context, repoRoot string, branch string) error {
	value := strings.TrimSpace(branch)
	if value == "" {
		return fmt.Errorf("branch 不能为空")
	}
	if strings.ContainsRune(value, '\x00') || strings.HasPrefix(value, "-") || strings.ContainsAny(value, " \t\r\n") {
		return fmt.Errorf("branch 不是安全的 Git 分支名")
	}
	if _, _, err := runGitReadOnly(ctx, repoRoot, 4*1024, "check-ref-format", "--branch", value); err != nil {
		return fmt.Errorf("branch 不是有效 Git 分支名：%w", err)
	}
	return nil
}

func worktreeBranchExists(ctx context.Context, repoRoot string, branch string) bool {
	_, _, err := runGitReadOnly(ctx, repoRoot, 4*1024, "rev-parse", "--verify", "--quiet", "refs/heads/"+branch)
	return err == nil
}

func sanitizedWorktreeBranchSlug(raw string) string {
	slug := sanitizedWorktreeName(raw)
	slug = strings.Trim(slug, ".")
	if slug == "" {
		return "worktree"
	}
	return slug
}

func sanitizedWorktreeName(raw string) string {
	value := strings.TrimSpace(raw)
	var b strings.Builder
	lastDash := false
	for _, r := range value {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(unicode.ToLower(r))
			lastDash = false
		case r == '-' || r == '_' || r == '.':
			b.WriteRune(r)
			lastDash = false
		default:
			if !lastDash {
				b.WriteByte('-')
				lastDash = true
			}
		}
	}
	out := strings.Trim(b.String(), "-_.")
	if out == "" {
		return "worktree"
	}
	if len([]rune(out)) > 48 {
		return string([]rune(out)[:48])
	}
	return out
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
