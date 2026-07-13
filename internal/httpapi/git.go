package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	gitStatusCommandTimeout = 4 * time.Second
	gitStatusOutputLimit    = 192 * 1024
	gitActionFileLimit      = 50
	gitActionPatchLimit     = 64 * 1024
	gitCommitMessageLimit   = 300
	gitPullRequestBodyLimit = 4000
)

var gitRemoteNamePattern = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)

type gitStatusRequest struct {
	Path string `json:"path"`
}

type gitActionRequest struct {
	Path   string   `json:"path"`
	Action string   `json:"action"`
	Files  []string `json:"files,omitempty"`
	Patch  string   `json:"patch,omitempty"`
}

type gitCommitRequest struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

type gitPushRequest struct {
	Path   string `json:"path"`
	Remote string `json:"remote,omitempty"`
}

type gitPullRequestRequest struct {
	Path  string `json:"path"`
	Title string `json:"title"`
	Body  string `json:"body,omitempty"`
	Draft bool   `json:"draft,omitempty"`
}

type gitPullRequestStatusRequest struct {
	Path string `json:"path"`
}

type gitPushResponse struct {
	Path   string            `json:"path"`
	Remote string            `json:"remote"`
	Branch string            `json:"branch"`
	Output string            `json:"output,omitempty"`
	Status gitStatusResponse `json:"status"`
}

type gitPullRequestResponse struct {
	Path   string `json:"path"`
	Branch string `json:"branch"`
	URL    string `json:"url,omitempty"`
	Output string `json:"output,omitempty"`
}

type gitPullRequestStatusResponse struct {
	Path             string `json:"path"`
	Branch           string `json:"branch"`
	Exists           bool   `json:"exists"`
	Number           int    `json:"number,omitempty"`
	Title            string `json:"title,omitempty"`
	State            string `json:"state,omitempty"`
	URL              string `json:"url,omitempty"`
	IsDraft          bool   `json:"is_draft,omitempty"`
	ReviewDecision   string `json:"review_decision,omitempty"`
	MergeStateStatus string `json:"merge_state_status,omitempty"`
	HeadRefName      string `json:"head_ref_name,omitempty"`
	BaseRefName      string `json:"base_ref_name,omitempty"`
}

type githubPullRequestView struct {
	Number           int    `json:"number"`
	Title            string `json:"title"`
	State            string `json:"state"`
	URL              string `json:"url"`
	IsDraft          bool   `json:"isDraft"`
	ReviewDecision   string `json:"reviewDecision"`
	MergeStateStatus string `json:"mergeStateStatus"`
	HeadRefName      string `json:"headRefName"`
	BaseRefName      string `json:"baseRefName"`
}

type gitFileStatus struct {
	Path      string `json:"path"`
	Code      string `json:"code"`
	Staged    bool   `json:"staged,omitempty"`
	Unstaged  bool   `json:"unstaged,omitempty"`
	Untracked bool   `json:"untracked,omitempty"`
}

type gitStatusResponse struct {
	Path          string          `json:"path"`
	IsRepository  bool            `json:"is_repository"`
	Branch        string          `json:"branch,omitempty"`
	Head          string          `json:"head,omitempty"`
	StatusText    string          `json:"status_text,omitempty"`
	DiffStat      string          `json:"diff_stat,omitempty"`
	UnstagedDiff  string          `json:"unstaged_diff,omitempty"`
	StagedDiff    string          `json:"staged_diff,omitempty"`
	Files         []gitFileStatus `json:"files,omitempty"`
	Truncated     bool            `json:"truncated,omitempty"`
	TruncatedNote string          `json:"truncated_note,omitempty"`
}

func (r *Router) gitStatusHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitStatusRequest
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
	realPath := scope.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是目录")
		return
	}

	status, err := r.gitStatus(req.Context(), realPath)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, status)
}

func (r *Router) gitActionHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitActionRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	action := strings.TrimSpace(payload.Action)
	var files []string
	var patch string
	var err error
	if isGitPatchAction(action) {
		patch, err = normalizedGitPatch(payload.Patch)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
	} else {
		files, err = normalizedGitActionFiles(payload.Files)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	realPath := scope.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是目录")
		return
	}

	status, err := r.gitAction(req.Context(), realPath, action, files, patch)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, status)
}

func (r *Router) gitCommitHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitCommitRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	message, err := normalizedGitCommitMessage(payload.Message)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	realPath := scope.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是目录")
		return
	}

	status, err := r.gitCommit(req.Context(), realPath, message)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, status)
}

func (r *Router) gitPushHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitPushRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	realPath, ok := r.validatedGitDirectory(w, payload.Path)
	if !ok {
		return
	}
	remote, err := normalizedGitRemote(payload.Remote)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	response, err := r.gitPush(req.Context(), realPath, remote)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) gitPullRequestHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitPullRequestRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	realPath, ok := r.validatedGitDirectory(w, payload.Path)
	if !ok {
		return
	}
	title, body, err := normalizedPullRequestText(payload.Title, payload.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	response, err := r.gitCreatePullRequest(req.Context(), realPath, title, body, payload.Draft)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) gitPullRequestStatusHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitPullRequestStatusRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	realPath, ok := r.validatedGitDirectory(w, payload.Path)
	if !ok {
		return
	}
	response, err := r.gitPullRequestStatus(req.Context(), realPath)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) validatedGitDirectory(w http.ResponseWriter, rawPath string) (string, bool) {
	path := strings.TrimSpace(rawPath)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return "", false
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return "", false
	}
	realPath := scope.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return "", false
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是目录")
		return "", false
	}
	return realPath, true
}

func (r *Router) gitStatus(ctx context.Context, realPath string) (gitStatusResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, gitStatusCommandTimeout)
	defer cancel()

	if _, err := exec.LookPath("git"); err != nil {
		return gitStatusResponse{}, fmt.Errorf("git 不可用：%w", err)
	}

	if _, _, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "rev-parse", "--is-inside-work-tree"); err != nil {
		if isGitRepositoryMissingError(err) {
			return gitStatusResponse{
				Path:         realPath,
				IsRepository: false,
			}, nil
		}
		return gitStatusResponse{}, err
	}

	var truncated bool
	statusText, cut, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "status", "--short", "--", ".")
	if err != nil {
		return gitStatusResponse{}, err
	}
	truncated = truncated || cut

	statusPorcelain, cut, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "status", "--porcelain=v1", "-z", "--", ".")
	if err != nil {
		return gitStatusResponse{}, err
	}
	truncated = truncated || cut

	diffStat, cut, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "diff", "--stat", "--", ".")
	if err != nil {
		return gitStatusResponse{}, err
	}
	truncated = truncated || cut

	unstagedDiff, cut, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "diff", "--", ".")
	if err != nil {
		return gitStatusResponse{}, err
	}
	truncated = truncated || cut

	stagedDiff, cut, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "diff", "--cached", "--", ".")
	if err != nil {
		return gitStatusResponse{}, err
	}
	truncated = truncated || cut

	branch, _, _ := runGitReadOnly(ctx, realPath, 4*1024, "branch", "--show-current")
	head, _, _ := runGitReadOnly(ctx, realPath, 4*1024, "rev-parse", "--short", "HEAD")

	response := gitStatusResponse{
		Path:         realPath,
		IsRepository: true,
		Branch:       strings.TrimSpace(branch),
		Head:         strings.TrimSpace(head),
		StatusText:   strings.TrimSpace(statusText),
		DiffStat:     strings.TrimSpace(diffStat),
		UnstagedDiff: strings.TrimSpace(unstagedDiff),
		StagedDiff:   strings.TrimSpace(stagedDiff),
		Files:        parseGitFileStatuses(statusPorcelain),
		Truncated:    truncated,
	}
	if truncated {
		response.TruncatedNote = "Git 输出过长，已截断展示。"
	}
	return response, nil
}

func (r *Router) gitAction(ctx context.Context, realPath string, action string, files []string, patch string) (gitStatusResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, gitStatusCommandTimeout)
	defer cancel()

	if _, err := exec.LookPath("git"); err != nil {
		return gitStatusResponse{}, fmt.Errorf("git 不可用：%w", err)
	}
	if _, _, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "rev-parse", "--is-inside-work-tree"); err != nil {
		if isGitRepositoryMissingError(err) {
			return gitStatusResponse{}, fmt.Errorf("当前工作区不是 Git 仓库")
		}
		return gitStatusResponse{}, err
	}

	switch action {
	case "stage":
		if _, _, err := runGitCommand(ctx, realPath, 16*1024, append([]string{"add", "--"}, files...)...); err != nil {
			return gitStatusResponse{}, err
		}
	case "unstage":
		if _, _, err := runGitCommand(ctx, realPath, 16*1024, append([]string{"reset", "--"}, files...)...); err != nil {
			return gitStatusResponse{}, err
		}
	case "revert":
		// revert 只撤销已跟踪文件的工作区改动，不删除未跟踪文件，避免移动端误触造成数据丢失。
		if _, _, err := runGitCommand(ctx, realPath, 16*1024, append([]string{"checkout", "--"}, files...)...); err != nil {
			return gitStatusResponse{}, err
		}
	case "stage_patch":
		// 单 hunk stage 用 git apply --cached，只修改 index，不碰工作区内容。
		if _, _, err := runGitCommandWithInput(ctx, realPath, patch, 16*1024, "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn"); err != nil {
			return gitStatusResponse{}, err
		}
	case "unstage_patch":
		// 单 hunk unstage 是 stage patch 的反向操作，只回退 index 中对应 hunk。
		if _, _, err := runGitCommandWithInput(ctx, realPath, patch, 16*1024, "apply", "--cached", "--reverse", "--unidiff-zero", "--whitespace=nowarn"); err != nil {
			return gitStatusResponse{}, err
		}
	case "revert_patch":
		// 单 hunk revert 只回滚工作区里的对应 hunk；patch 入口会先做路径和数量限制。
		if _, _, err := runGitCommandWithInput(ctx, realPath, patch, 16*1024, "apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn"); err != nil {
			return gitStatusResponse{}, err
		}
	default:
		return gitStatusResponse{}, fmt.Errorf("不支持的 Git 动作：%s", action)
	}
	return r.gitStatus(ctx, realPath)
}

func (r *Router) gitCommit(ctx context.Context, realPath string, message string) (gitStatusResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	if _, err := exec.LookPath("git"); err != nil {
		return gitStatusResponse{}, fmt.Errorf("git 不可用：%w", err)
	}
	if _, _, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "rev-parse", "--is-inside-work-tree"); err != nil {
		if isGitRepositoryMissingError(err) {
			return gitStatusResponse{}, fmt.Errorf("当前工作区不是 Git 仓库")
		}
		return gitStatusResponse{}, err
	}

	// commit 只提交 index 中已有内容；用户必须先显式 stage，避免把工作区改动一股脑写进历史。
	if err := validateGitCommitScope(ctx, realPath); err != nil {
		return gitStatusResponse{}, err
	}
	if _, _, err := runGitCommand(ctx, realPath, 32*1024, "commit", "-m", message); err != nil {
		return gitStatusResponse{}, err
	}
	return r.gitStatus(ctx, realPath)
}

func validateGitCommitScope(ctx context.Context, realPath string) error {
	repoRootRaw, _, err := runGitReadOnly(ctx, realPath, 16*1024, "rev-parse", "--show-toplevel")
	if err != nil {
		return err
	}
	repoRoot, err := filepath.EvalSymlinks(strings.TrimSpace(repoRootRaw))
	if err != nil {
		return fmt.Errorf("无法解析 Git 仓库根目录：%w", err)
	}
	scopeRoot, err := filepath.EvalSymlinks(realPath)
	if err != nil {
		return fmt.Errorf("无法解析当前工作区目录：%w", err)
	}
	scopeRel, err := filepath.Rel(repoRoot, scopeRoot)
	if err != nil || scopeRel == ".." || strings.HasPrefix(scopeRel, ".."+string(os.PathSeparator)) {
		return fmt.Errorf("当前工作区不在 Git 仓库内")
	}
	stagedRaw, _, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "diff", "--cached", "--name-only", "-z")
	if err != nil {
		return err
	}
	stagedFiles := parseGitNULPaths(stagedRaw)
	if len(stagedFiles) == 0 {
		return fmt.Errorf("没有已暂存改动可提交")
	}
	if scopeRel == "." {
		return nil
	}
	scopePrefix := filepath.ToSlash(filepath.Clean(scopeRel))
	for _, path := range stagedFiles {
		clean := filepath.ToSlash(filepath.Clean(path))
		if clean == scopePrefix || strings.HasPrefix(clean, scopePrefix+"/") {
			continue
		}
		// git commit 默认提交整个 index；从子目录或工作区视角提交前必须挡住 scope 外的暂存内容。
		return fmt.Errorf("已暂存文件 %s 不在当前工作区范围内，请先取消暂存或切到仓库根目录提交", path)
	}
	return nil
}

func parseGitNULPaths(raw string) []string {
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, "\x00")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		path := strings.TrimSpace(part)
		if path == "" {
			continue
		}
		out = append(out, path)
	}
	return out
}

func (r *Router) gitPush(ctx context.Context, realPath string, remote string) (gitPushResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if _, err := exec.LookPath("git"); err != nil {
		return gitPushResponse{}, fmt.Errorf("git 不可用：%w", err)
	}
	if _, _, err := runGitReadOnly(ctx, realPath, gitStatusOutputLimit, "rev-parse", "--is-inside-work-tree"); err != nil {
		if isGitRepositoryMissingError(err) {
			return gitPushResponse{}, fmt.Errorf("当前工作区不是 Git 仓库")
		}
		return gitPushResponse{}, err
	}
	branch, err := currentGitBranch(ctx, realPath)
	if err != nil {
		return gitPushResponse{}, err
	}
	if _, _, err := runGitReadOnly(ctx, realPath, 4*1024, "remote", "get-url", remote); err != nil {
		return gitPushResponse{}, fmt.Errorf("Git remote 不存在或不可用：%w", err)
	}

	// 不开放 force push；移动端只做普通 push 和 upstream 绑定，冲突交给 Git 自己拒绝。
	output, _, err := runGitCommand(ctx, realPath, 32*1024, "push", "-u", remote, branch)
	if err != nil {
		return gitPushResponse{}, err
	}
	status, err := r.gitStatus(ctx, realPath)
	if err != nil {
		return gitPushResponse{}, err
	}
	return gitPushResponse{
		Path:   realPath,
		Remote: remote,
		Branch: branch,
		Output: strings.TrimSpace(output),
		Status: status,
	}, nil
}

func (r *Router) gitCreatePullRequest(ctx context.Context, realPath string, title string, body string, draft bool) (gitPullRequestResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if _, err := exec.LookPath("gh"); err != nil {
		return gitPullRequestResponse{}, fmt.Errorf("gh 不可用，请先在本机安装并登录 GitHub CLI")
	}
	branch, err := currentGitBranch(ctx, realPath)
	if err != nil {
		return gitPullRequestResponse{}, err
	}
	args := []string{"pr", "create", "--title", title, "--body", body}
	if draft {
		args = append(args, "--draft")
	}
	output, _, err := runCommand(ctx, realPath, 32*1024, "gh", args...)
	if err != nil {
		return gitPullRequestResponse{}, err
	}
	text := strings.TrimSpace(output)
	return gitPullRequestResponse{
		Path:   realPath,
		Branch: branch,
		URL:    firstURL(text),
		Output: text,
	}, nil
}

func (r *Router) gitPullRequestStatus(ctx context.Context, realPath string) (gitPullRequestStatusResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	if _, err := exec.LookPath("gh"); err != nil {
		return gitPullRequestStatusResponse{}, fmt.Errorf("gh 不可用，请先在本机安装并登录 GitHub CLI")
	}
	branch, err := currentGitBranch(ctx, realPath)
	if err != nil {
		return gitPullRequestStatusResponse{}, err
	}
	output, _, err := runCommand(ctx, realPath, 32*1024, "gh", "pr", "view", "--json", "number,title,state,url,isDraft,reviewDecision,mergeStateStatus,headRefName,baseRefName")
	if err != nil {
		if isGitHubNoPullRequestError(err) {
			return gitPullRequestStatusResponse{Path: realPath, Branch: branch, Exists: false}, nil
		}
		return gitPullRequestStatusResponse{}, err
	}
	var view githubPullRequestView
	if err := json.Unmarshal([]byte(output), &view); err != nil {
		return gitPullRequestStatusResponse{}, fmt.Errorf("gh PR 状态响应不是合法 JSON：%w", err)
	}
	return gitPullRequestStatusResponse{
		Path:             realPath,
		Branch:           branch,
		Exists:           true,
		Number:           view.Number,
		Title:            strings.TrimSpace(view.Title),
		State:            strings.TrimSpace(view.State),
		URL:              strings.TrimSpace(view.URL),
		IsDraft:          view.IsDraft,
		ReviewDecision:   strings.TrimSpace(view.ReviewDecision),
		MergeStateStatus: strings.TrimSpace(view.MergeStateStatus),
		HeadRefName:      strings.TrimSpace(view.HeadRefName),
		BaseRefName:      strings.TrimSpace(view.BaseRefName),
	}, nil
}

func isGitHubNoPullRequestError(err error) bool {
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "no pull requests found") ||
		strings.Contains(text, "no open pull requests") ||
		strings.Contains(text, "could not find") ||
		strings.Contains(text, "not found")
}

func runGitReadOnly(ctx context.Context, dir string, limit int, args ...string) (string, bool, error) {
	return runGitCommand(ctx, dir, limit, args...)
}

func runGitCommand(ctx context.Context, dir string, limit int, args ...string) (string, bool, error) {
	return runCommand(ctx, dir, limit, "git", append([]string{"-C", dir}, args...)...)
}

func runGitCommandWithInput(ctx context.Context, dir string, input string, limit int, args ...string) (string, bool, error) {
	return runCommandWithInput(ctx, dir, input, limit, "git", append([]string{"-C", dir}, args...)...)
}

func runCommand(ctx context.Context, dir string, limit int, name string, args ...string) (string, bool, error) {
	return runCommandWithInput(ctx, dir, "", limit, name, args...)
}

func runCommandWithInput(ctx context.Context, dir string, input string, limit int, name string, args ...string) (string, bool, error) {
	stdout := &cappedBuffer{limit: limit}
	stderr := &cappedBuffer{limit: 8 * 1024}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	if input != "" {
		cmd.Stdin = strings.NewReader(input)
	}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return "", false, fmt.Errorf("git 命令超时")
		}
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return "", false, gitCommandError{message: message}
	}
	return stdout.String(), stdout.truncated, nil
}

func isGitPatchAction(action string) bool {
	switch action {
	case "stage_patch", "unstage_patch", "revert_patch":
		return true
	default:
		return false
	}
}

func currentGitBranch(ctx context.Context, realPath string) (string, error) {
	branch, _, err := runGitReadOnly(ctx, realPath, 4*1024, "branch", "--show-current")
	if err != nil {
		return "", err
	}
	name := strings.TrimSpace(branch)
	if name == "" {
		return "", fmt.Errorf("当前 Git HEAD 是 detached，无法执行该动作")
	}
	return name, nil
}

func normalizedGitActionFiles(files []string) ([]string, error) {
	if len(files) == 0 {
		return nil, fmt.Errorf("files 不能为空")
	}
	if len(files) > gitActionFileLimit {
		return nil, fmt.Errorf("一次最多处理 %d 个文件", gitActionFileLimit)
	}

	normalized := make([]string, 0, len(files))
	seen := map[string]struct{}{}
	for _, file := range files {
		candidate := strings.TrimSpace(file)
		if candidate == "" {
			return nil, fmt.Errorf("files 不能包含空路径")
		}
		if strings.ContainsRune(candidate, '\x00') {
			return nil, fmt.Errorf("files 不能包含非法路径")
		}
		if filepath.IsAbs(candidate) {
			return nil, fmt.Errorf("files 必须是相对路径")
		}
		clean := filepath.Clean(candidate)
		if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return nil, fmt.Errorf("files 不能越过工作区")
		}
		clean = filepath.ToSlash(clean)
		if _, ok := seen[clean]; ok {
			continue
		}
		seen[clean] = struct{}{}
		normalized = append(normalized, clean)
	}
	return normalized, nil
}

func normalizedGitPatch(raw string) (string, error) {
	if strings.TrimSpace(raw) == "" {
		return "", fmt.Errorf("patch 不能为空")
	}
	if len(raw) > gitActionPatchLimit {
		return "", fmt.Errorf("patch 最多 %d 字节", gitActionPatchLimit)
	}
	if strings.ContainsRune(raw, '\x00') {
		return "", fmt.Errorf("patch 不能包含非法字符")
	}
	normalized := strings.ReplaceAll(raw, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	if !strings.HasSuffix(normalized, "\n") {
		normalized += "\n"
	}

	hunkCount := 0
	paths := map[string]struct{}{}
	for _, line := range strings.Split(normalized, "\n") {
		if strings.HasPrefix(line, "@@ ") || strings.HasPrefix(line, "@@ -") {
			hunkCount++
		}
		for _, candidate := range gitPatchPathsFromHeader(line) {
			path, err := normalizedGitPatchPath(candidate)
			if err != nil {
				return "", err
			}
			if path != "" {
				paths[path] = struct{}{}
			}
		}
	}
	if hunkCount != 1 {
		return "", fmt.Errorf("patch 必须只包含一个 hunk")
	}
	if len(paths) == 0 {
		return "", fmt.Errorf("patch 缺少文件路径")
	}
	if len(paths) > 1 {
		return "", fmt.Errorf("patch 只能修改一个文件")
	}
	return normalized, nil
}

func gitPatchPathsFromHeader(line string) []string {
	switch {
	case strings.HasPrefix(line, "--- "):
		return []string{strings.TrimSpace(strings.TrimPrefix(line, "--- "))}
	case strings.HasPrefix(line, "+++ "):
		return []string{strings.TrimSpace(strings.TrimPrefix(line, "+++ "))}
	case strings.HasPrefix(line, "diff --git "):
		rest := strings.TrimSpace(strings.TrimPrefix(line, "diff --git "))
		if first, second, ok := strings.Cut(rest, " b/"); ok {
			return []string{first, "b/" + second}
		}
		return strings.Fields(rest)
	default:
		return nil
	}
}

func normalizedGitPatchPath(candidate string) (string, error) {
	path := strings.TrimSpace(candidate)
	if path == "" || path == "/dev/null" {
		return "", nil
	}
	if index := strings.IndexByte(path, '\t'); index >= 0 {
		path = path[:index]
	}
	path = strings.Trim(path, "\"")
	path = strings.TrimPrefix(path, "a/")
	path = strings.TrimPrefix(path, "b/")
	if path == "" || path == "/dev/null" {
		return "", nil
	}
	if strings.ContainsRune(path, '\x00') || strings.HasPrefix(path, "-") || filepath.IsAbs(path) {
		return "", fmt.Errorf("patch 包含不安全文件路径")
	}
	clean := filepath.Clean(path)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("patch 不能越过工作区")
	}
	return filepath.ToSlash(clean), nil
}

func normalizedGitCommitMessage(message string) (string, error) {
	normalized := strings.TrimSpace(message)
	if normalized == "" {
		return "", fmt.Errorf("message 不能为空")
	}
	if strings.ContainsRune(normalized, '\x00') {
		return "", fmt.Errorf("message 不能包含非法字符")
	}
	if len([]rune(normalized)) > gitCommitMessageLimit {
		return "", fmt.Errorf("message 最多 %d 个字符", gitCommitMessageLimit)
	}
	return normalized, nil
}

func normalizedGitRemote(remote string) (string, error) {
	value := strings.TrimSpace(remote)
	if value == "" {
		value = "origin"
	}
	if strings.ContainsRune(value, '\x00') || strings.HasPrefix(value, "-") || !gitRemoteNamePattern.MatchString(value) {
		return "", fmt.Errorf("remote 不是安全的 Git remote 名称")
	}
	return value, nil
}

func normalizedPullRequestText(title string, body string) (string, string, error) {
	normalizedTitle := strings.TrimSpace(title)
	if normalizedTitle == "" {
		return "", "", fmt.Errorf("title 不能为空")
	}
	if strings.ContainsRune(normalizedTitle, '\x00') {
		return "", "", fmt.Errorf("title 不能包含非法字符")
	}
	if len([]rune(normalizedTitle)) > gitCommitMessageLimit {
		return "", "", fmt.Errorf("title 最多 %d 个字符", gitCommitMessageLimit)
	}
	normalizedBody := strings.TrimSpace(body)
	if strings.ContainsRune(normalizedBody, '\x00') {
		return "", "", fmt.Errorf("body 不能包含非法字符")
	}
	if len([]rune(normalizedBody)) > gitPullRequestBodyLimit {
		return "", "", fmt.Errorf("body 最多 %d 个字符", gitPullRequestBodyLimit)
	}
	return normalizedTitle, normalizedBody, nil
}

func firstURL(text string) string {
	for _, field := range strings.Fields(text) {
		candidate := strings.Trim(field, ".,;()[]{}<>\"'")
		if strings.HasPrefix(candidate, "http://") || strings.HasPrefix(candidate, "https://") {
			return candidate
		}
	}
	return ""
}

func parseGitFileStatuses(raw string) []gitFileStatus {
	entries := strings.Split(raw, "\x00")
	files := make([]gitFileStatus, 0, len(entries))
	for i := 0; i < len(entries); i++ {
		entry := entries[i]
		if len(entry) < 4 {
			continue
		}
		code := entry[:2]
		path := strings.TrimSpace(entry[3:])
		if path == "" {
			continue
		}
		if code[0] == 'R' || code[0] == 'C' {
			// porcelain -z 的 rename/copy 会额外带一个原路径字段；当前动作面向新路径。
			i++
		}
		file := gitFileStatus{
			Path:      path,
			Code:      code,
			Staged:    code[0] != ' ' && code[0] != '?',
			Unstaged:  code[1] != ' ',
			Untracked: code == "??",
		}
		files = append(files, file)
	}
	return files
}

type gitCommandError struct {
	message string
}

func (e gitCommandError) Error() string {
	return e.message
}

func isGitRepositoryMissingError(err error) bool {
	var gitErr gitCommandError
	if !errors.As(err, &gitErr) {
		return false
	}
	message := strings.ToLower(gitErr.message)
	return strings.Contains(message, "not a git repository") ||
		strings.Contains(message, "not a git work tree")
}

type cappedBuffer struct {
	buf       bytes.Buffer
	limit     int
	truncated bool
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if b.limit <= 0 {
		b.truncated = true
		return len(p), nil
	}
	remaining := b.limit - b.buf.Len()
	if remaining > 0 {
		if len(p) > remaining {
			_, _ = b.buf.Write(p[:remaining])
			b.truncated = true
		} else {
			_, _ = b.buf.Write(p)
		}
	} else if len(p) > 0 {
		b.truncated = true
	}
	return len(p), nil
}

func (b *cappedBuffer) String() string {
	return b.buf.String()
}
