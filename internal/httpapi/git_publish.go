package httpapi

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	gitQuickPublishTimeout      = 75 * time.Second
	gitTestFlightPreflightLimit = 16 * 1024
	gitTestFlightOutputLimit    = 192 * 1024
	gitTestFlightRunTimeout     = 45 * time.Minute
	gitTestFlightWhatToTestMax  = 1000
)

type gitQuickPublishRequest struct {
	Path      string `json:"path"`
	Message   string `json:"message"`
	Remote    string `json:"remote,omitempty"`
	Confirmed bool   `json:"confirmed"`
}

type gitQuickPublishResponse struct {
	Path      string            `json:"path"`
	Remote    string            `json:"remote"`
	Branch    string            `json:"branch"`
	Message   string            `json:"message"`
	Committed bool              `json:"committed"`
	Output    string            `json:"output,omitempty"`
	Status    gitStatusResponse `json:"status"`
}

type gitTestFlightStatusRequest struct {
	Path string `json:"path"`
}

type gitTestFlightRunRequest struct {
	Path       string `json:"path"`
	WhatToTest string `json:"what_to_test,omitempty"`
	Confirmed  bool   `json:"confirmed"`
}

type gitTestFlightCapability struct {
	IsIOSProject bool   `json:"is_ios_project"`
	Available    bool   `json:"available"`
	Reason       string `json:"reason"`
	ProjectID    string `json:"project_id,omitempty"`
	Command      string `json:"command,omitempty"`
}

type gitTestFlightJobSnapshot struct {
	ID         string `json:"id"`
	State      string `json:"state"`
	Output     string `json:"output,omitempty"`
	Truncated  bool   `json:"truncated,omitempty"`
	ExitCode   *int   `json:"exit_code,omitempty"`
	StartedAt  string `json:"started_at"`
	FinishedAt string `json:"finished_at,omitempty"`
}

type gitTestFlightStatusResponse struct {
	Path       string                    `json:"path"`
	Capability gitTestFlightCapability   `json:"capability"`
	Job        *gitTestFlightJobSnapshot `json:"job,omitempty"`
}

type gitTestFlightReleaseJob struct {
	id         string
	state      string
	capability gitTestFlightCapability
	startedAt  time.Time
	finishedAt time.Time
	exitCode   *int
	output     *synchronizedCappedBuffer
}

func (r *Router) gitQuickPublishHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitQuickPublishRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	if !payload.Confirmed {
		writeError(w, http.StatusForbidden, "快捷提交需要用户确认后才能执行")
		return
	}
	realPath, ok := r.validatedGitDirectory(w, payload.Path)
	if !ok {
		return
	}
	message, err := normalizedGitCommitMessage(payload.Message)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	remote, err := normalizedGitRemote(payload.Remote)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	response, err := r.gitQuickPublish(req.Context(), realPath, message, remote)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) gitQuickPublish(ctx context.Context, realPath string, message string, remote string) (gitQuickPublishResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, gitQuickPublishTimeout)
	defer cancel()

	status, err := r.gitStatus(ctx, realPath)
	if err != nil {
		return gitQuickPublishResponse{}, err
	}
	if !status.IsRepository {
		return gitQuickPublishResponse{}, fmt.Errorf("当前工作区不是 Git 仓库")
	}
	branch, err := currentGitBranch(ctx, realPath)
	if err != nil {
		return gitQuickPublishResponse{}, err
	}
	if _, _, err := runGitReadOnly(ctx, realPath, 4*1024, "remote", "get-url", remote); err != nil {
		return gitQuickPublishResponse{}, fmt.Errorf("Git remote 不存在或不可用：%w", err)
	}

	committed := len(status.Files) > 0
	var outputParts []string
	if committed {
		// 快捷发布只暂存当前授权工作区内的文件；validateGitCommitScope 会继续阻止 scope 外已有 index 内容混入提交。
		if output, _, err := runGitCommand(ctx, realPath, 32*1024, "add", "--", "."); err != nil {
			return gitQuickPublishResponse{}, err
		} else if text := strings.TrimSpace(output); text != "" {
			outputParts = append(outputParts, text)
		}
		if err := validateGitCommitScope(ctx, realPath); err != nil {
			return gitQuickPublishResponse{}, err
		}
		if output, _, err := runGitCommand(ctx, realPath, 32*1024, "commit", "-m", message); err != nil {
			return gitQuickPublishResponse{}, err
		} else if text := strings.TrimSpace(output); text != "" {
			outputParts = append(outputParts, text)
		}
	}

	// 明确禁止 force push；快捷入口与普通 Push 使用相同的安全边界。
	if output, _, err := runGitCommand(ctx, realPath, 32*1024, "push", "-u", remote, branch); err != nil {
		return gitQuickPublishResponse{}, err
	} else if text := strings.TrimSpace(output); text != "" {
		outputParts = append(outputParts, text)
	}
	status, err = r.gitStatus(ctx, realPath)
	if err != nil {
		return gitQuickPublishResponse{}, err
	}
	return gitQuickPublishResponse{
		Path:      realPath,
		Remote:    remote,
		Branch:    branch,
		Message:   message,
		Committed: committed,
		Output:    strings.Join(outputParts, "\n\n"),
		Status:    status,
	}, nil
}

func (r *Router) gitTestFlightStatusHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitTestFlightStatusRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	realPath, ok := r.validatedGitDirectory(w, payload.Path)
	if !ok {
		return
	}
	repoRoot, err := gitRepositoryRoot(req.Context(), realPath)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	job, runningCapability := r.gitTestFlightJobStatus(repoRoot)
	var capability gitTestFlightCapability
	if runningCapability != nil {
		// 发布进行中时沿用启动前已经通过的预检，轮询只读任务状态，不反复访问 Keychain 和文件系统。
		capability = *runningCapability
	} else {
		capability = gitTestFlightCapabilityForPath(req.Context(), repoRoot)
	}
	response := gitTestFlightStatusResponse{Path: realPath, Capability: capability, Job: job}
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) gitTestFlightRunHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload gitTestFlightRunRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	if !payload.Confirmed {
		writeError(w, http.StatusForbidden, "TestFlight 发布需要用户确认后才能执行")
		return
	}
	whatToTest, err := normalizedTestFlightWhatToTest(payload.WhatToTest)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	realPath, ok := r.validatedGitDirectory(w, payload.Path)
	if !ok {
		return
	}
	repoRoot, err := gitRepositoryRoot(req.Context(), realPath)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	capability := gitTestFlightCapabilityForPath(req.Context(), repoRoot)
	if !capability.Available {
		writeError(w, http.StatusPreconditionFailed, capability.Reason)
		return
	}
	statusText, _, err := runGitReadOnly(req.Context(), repoRoot, 32*1024, "status", "--porcelain=v1")
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if strings.TrimSpace(statusText) != "" {
		writeError(w, http.StatusConflict, "工作区仍有未提交变更，请先完成提交并推送")
		return
	}

	job, started := r.startGitTestFlightJob(repoRoot, whatToTest, capability)
	if !started {
		writeJSON(w, http.StatusConflict, gitTestFlightStatusResponse{
			Path:       realPath,
			Capability: capability,
			Job:        job,
		})
		return
	}
	writeJSON(w, http.StatusAccepted, gitTestFlightStatusResponse{
		Path:       realPath,
		Capability: capability,
		Job:        job,
	})
}

func gitRepositoryRoot(ctx context.Context, realPath string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, gitStatusCommandTimeout)
	defer cancel()
	root, _, err := runGitReadOnly(ctx, realPath, 16*1024, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", fmt.Errorf("无法读取 Git 仓库根目录：%w", err)
	}
	resolved, err := filepath.EvalSymlinks(strings.TrimSpace(root))
	if err != nil {
		return "", fmt.Errorf("无法解析 Git 仓库根目录：%w", err)
	}
	return resolved, nil
}

func gitTestFlightCapabilityForPath(ctx context.Context, repoRoot string) gitTestFlightCapability {
	isIOS := looksLikeIOSRepository(repoRoot)
	capability := gitTestFlightCapability{
		IsIOSProject: isIOS,
		Available:    false,
		Reason:       "未识别到 iOS 工程",
	}
	if !isIOS {
		return capability
	}

	configText, _, configErr := runGitReadOnly(ctx, repoRoot, 32*1024, "show", "HEAD:config/release/ios-testflight.local.env")
	if configErr == nil {
		capability.ProjectID = shellAssignmentValue(configText, "IOS_RELEASE_PROJECT_ID")
	}
	preflightCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	executable, ok := gitTestFlightExecutable(repoRoot)
	if !ok {
		capability.Reason = "主机未安装 git-testflight-push，且仓库内没有可执行的 scripts/git-testflight-push"
		return capability
	}
	output, _, err := runCommand(preflightCtx, repoRoot, gitTestFlightPreflightLimit, executable, "--check")
	if err != nil {
		capability.Reason = shortenedReleaseReason(err.Error())
		return capability
	}
	capability.Available = true
	capability.Reason = "主机本地 TestFlight 发布预检通过"
	capability.Command = displayTestFlightCommand(executable, repoRoot)
	if capability.ProjectID == "" {
		capability.ProjectID = shellAssignmentValue(output, "IOS_RELEASE_PROJECT_ID")
	}
	return capability
}

func gitTestFlightExecutable(repoRoot string) (string, bool) {
	// 仓库自带的发布入口与项目配置同版本，优先于主机上可能尚未升级的通用安装副本。
	candidate := filepath.Join(repoRoot, "scripts", "git-testflight-push")
	if executableFile(candidate) {
		return candidate, true
	}
	if command, err := exec.LookPath("git-testflight-push"); err == nil && executableFile(command) {
		return command, true
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidate = filepath.Join(home, ".local", "bin", "git-testflight-push")
		if executableFile(candidate) {
			return candidate, true
		}
	}
	return "", false
}

func executableFile(path string) bool {
	stat, err := os.Stat(path)
	return err == nil && stat.Mode().IsRegular() && stat.Mode().Perm()&0o111 != 0
}

func displayTestFlightCommand(executable string, repoRoot string) string {
	if executable == filepath.Join(repoRoot, "scripts", "git-testflight-push") {
		return "scripts/git-testflight-push"
	}
	return "git testflight-push"
}

func looksLikeIOSRepository(repoRoot string) bool {
	if _, err := os.Stat(filepath.Join(repoRoot, "config", "release", "ios-testflight.local.env")); err == nil {
		return true
	}
	found := false
	_ = filepath.WalkDir(repoRoot, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || found {
			return nil
		}
		rel, relErr := filepath.Rel(repoRoot, path)
		if relErr != nil {
			return nil
		}
		depth := 0
		if rel != "." {
			depth = len(strings.Split(filepath.ToSlash(rel), "/"))
		}
		if entry.IsDir() {
			name := entry.Name()
			if name == ".git" || name == ".build" || name == "build" || name == "DerivedData" {
				return filepath.SkipDir
			}
			if strings.HasSuffix(name, ".xcodeproj") || strings.HasSuffix(name, ".xcworkspace") {
				found = true
				return filepath.SkipDir
			}
			if depth > 5 {
				return filepath.SkipDir
			}
			return nil
		}
		lowerRel := strings.ToLower(filepath.ToSlash(rel))
		if entry.Name() == "project.yml" && strings.Contains(lowerRel, "ios/") {
			found = true
		}
		return nil
	})
	return found
}

func shellAssignmentValue(content string, key string) string {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "export "))
		name, value, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(name) != key {
			continue
		}
		value = strings.TrimSpace(value)
		if len(value) >= 2 && ((value[0] == '\'' && value[len(value)-1] == '\'') || (value[0] == '"' && value[len(value)-1] == '"')) {
			value = value[1 : len(value)-1]
		}
		return strings.TrimSpace(value)
	}
	return ""
}

func shortenedReleaseReason(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "主机本地 TestFlight 发布预检失败"
	}
	runes := []rune(text)
	if len(runes) > 600 {
		text = string(runes[:600]) + "…"
	}
	return text
}

func normalizedTestFlightWhatToTest(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if strings.ContainsRune(value, '\x00') {
		return "", fmt.Errorf("what_to_test 不能包含非法字符")
	}
	if len([]rune(value)) > gitTestFlightWhatToTestMax {
		return "", fmt.Errorf("what_to_test 最多 %d 个字符", gitTestFlightWhatToTestMax)
	}
	return value, nil
}

func (r *Router) startGitTestFlightJob(repoRoot string, whatToTest string, capability gitTestFlightCapability) (*gitTestFlightJobSnapshot, bool) {
	r.gitTestFlightMu.Lock()
	if existing := r.gitTestFlightJobs[repoRoot]; existing != nil && existing.state == "running" {
		snapshot := snapshotGitTestFlightJob(existing)
		r.gitTestFlightMu.Unlock()
		return snapshot, false
	}
	job := &gitTestFlightReleaseJob{
		id:         fmt.Sprintf("testflight-%d", time.Now().UnixNano()),
		state:      "running",
		capability: capability,
		startedAt:  time.Now().UTC(),
		output:     &synchronizedCappedBuffer{limit: gitTestFlightOutputLimit},
	}
	r.gitTestFlightJobs[repoRoot] = job
	snapshot := snapshotGitTestFlightJob(job)
	r.gitTestFlightMu.Unlock()

	go r.runGitTestFlightJob(repoRoot, whatToTest, job)
	return snapshot, true
}

func (r *Router) runGitTestFlightJob(repoRoot string, whatToTest string, job *gitTestFlightReleaseJob) {
	ctx, cancel := context.WithTimeout(context.Background(), gitTestFlightRunTimeout)
	defer cancel()
	executable, ok := gitTestFlightExecutable(repoRoot)
	if !ok {
		r.finishGitTestFlightJob(job, fmt.Errorf("主机 TestFlight 发布命令已不可用"), nil)
		return
	}
	args := make([]string, 0, 2)
	if whatToTest != "" {
		args = append(args, "--what-to-test", whatToTest)
	}
	cmd := exec.CommandContext(ctx, executable, args...)
	cmd.Dir = repoRoot
	cmd.Stdout = job.output
	cmd.Stderr = job.output
	err := cmd.Run()

	r.finishGitTestFlightJob(job, err, ctx.Err())
}

func (r *Router) finishGitTestFlightJob(job *gitTestFlightReleaseJob, err error, contextErr error) {
	exitCode := 0
	state := "succeeded"
	if err != nil {
		state = "failed"
		exitCode = -1
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			exitCode = exitError.ExitCode()
		}
		if errors.Is(contextErr, context.DeadlineExceeded) {
			_, _ = job.output.Write([]byte("\nTestFlight 发布超过 45 分钟，主机已停止该任务。\n"))
		} else {
			_, _ = job.output.Write([]byte("\n" + err.Error() + "\n"))
		}
	}
	r.gitTestFlightMu.Lock()
	job.state = state
	job.finishedAt = time.Now().UTC()
	job.exitCode = &exitCode
	r.gitTestFlightMu.Unlock()
}

func (r *Router) gitTestFlightJobSnapshot(repoRoot string) *gitTestFlightJobSnapshot {
	r.gitTestFlightMu.Lock()
	defer r.gitTestFlightMu.Unlock()
	job := r.gitTestFlightJobs[repoRoot]
	if job == nil {
		return nil
	}
	return snapshotGitTestFlightJob(job)
}

func (r *Router) gitTestFlightJobStatus(repoRoot string) (*gitTestFlightJobSnapshot, *gitTestFlightCapability) {
	r.gitTestFlightMu.Lock()
	defer r.gitTestFlightMu.Unlock()
	job := r.gitTestFlightJobs[repoRoot]
	if job == nil {
		return nil, nil
	}
	snapshot := snapshotGitTestFlightJob(job)
	if job.state != "running" {
		return snapshot, nil
	}
	capability := job.capability
	return snapshot, &capability
}

func snapshotGitTestFlightJob(job *gitTestFlightReleaseJob) *gitTestFlightJobSnapshot {
	if job == nil {
		return nil
	}
	snapshot := &gitTestFlightJobSnapshot{
		ID:        job.id,
		State:     job.state,
		Output:    strings.TrimSpace(job.output.String()),
		Truncated: job.output.Truncated(),
		ExitCode:  job.exitCode,
		StartedAt: job.startedAt.Format(time.RFC3339),
	}
	if !job.finishedAt.IsZero() {
		snapshot.FinishedAt = job.finishedAt.Format(time.RFC3339)
	}
	return snapshot
}

type synchronizedCappedBuffer struct {
	mu        sync.Mutex
	buf       bytes.Buffer
	limit     int
	truncated bool
}

func (b *synchronizedCappedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	originalLength := len(p)
	remaining := b.limit - b.buf.Len()
	if remaining <= 0 {
		b.truncated = true
		return originalLength, nil
	}
	if len(p) > remaining {
		p = p[:remaining]
		b.truncated = true
	}
	_, _ = b.buf.Write(p)
	return originalLength, nil
}

func (b *synchronizedCappedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *synchronizedCappedBuffer) Truncated() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.truncated
}
