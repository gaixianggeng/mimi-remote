package httpapi

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const (
	commandActionDefaultTimeout = 20 * time.Second
	commandActionMaxOutputBytes = 64 * 1024
)

type commandActionListRequest struct {
	Path string `json:"path"`
}

type commandActionRunRequest struct {
	Path      string `json:"path"`
	ID        string `json:"id"`
	Confirmed bool   `json:"confirmed,omitempty"`
}

type commandActionDescriptor struct {
	ID                   string   `json:"id"`
	Name                 string   `json:"name"`
	Command              string   `json:"command"`
	Args                 []string `json:"args,omitempty"`
	WorkingDir           string   `json:"working_dir"`
	TimeoutSeconds       int      `json:"timeout_seconds"`
	RequiresConfirmation bool     `json:"requires_confirmation,omitempty"`
}

type commandActionListResponse struct {
	Path    string                    `json:"path"`
	Actions []commandActionDescriptor `json:"actions"`
}

type commandActionRunResponse struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Path           string   `json:"path"`
	WorkingDir     string   `json:"working_dir"`
	Command        string   `json:"command"`
	Args           []string `json:"args,omitempty"`
	Success        bool     `json:"success"`
	ExitCode       int      `json:"exit_code"`
	Output         string   `json:"output,omitempty"`
	Truncated      bool     `json:"truncated,omitempty"`
	TimedOut       bool     `json:"timed_out,omitempty"`
	DurationMillis int64    `json:"duration_ms"`
}

func (r *Router) commandActionListHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload commandActionListRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	realPath, scope, ok := r.validatedActionBaseDirectory(w, payload.Path)
	if !ok {
		return
	}
	actions := make([]commandActionDescriptor, 0, len(r.cfg.Actions))
	for _, action := range r.cfg.Actions {
		workingDir, ok := r.commandActionWorkingDir(scope, action)
		if !ok {
			continue
		}
		actions = append(actions, commandActionDescriptor{
			ID:                   strings.TrimSpace(action.ID),
			Name:                 strings.TrimSpace(action.Name),
			Command:              strings.TrimSpace(action.Command),
			Args:                 append([]string(nil), action.Args...),
			WorkingDir:           workingDir,
			TimeoutSeconds:       commandActionTimeoutSeconds(action),
			RequiresConfirmation: action.RequiresConfirmation,
		})
	}
	writeJSON(w, http.StatusOK, commandActionListResponse{
		Path:    realPath,
		Actions: actions,
	})
}

func (r *Router) commandActionRunHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload commandActionRunRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	id := strings.TrimSpace(payload.ID)
	if id == "" {
		writeError(w, http.StatusBadRequest, "id 不能为空")
		return
	}
	action, ok := r.commandActionByID(id)
	if !ok {
		writeError(w, http.StatusNotFound, "action 不存在")
		return
	}
	if action.RequiresConfirmation && !payload.Confirmed {
		writeError(w, http.StatusForbidden, "action 需要确认后才能执行")
		return
	}
	realPath, scope, ok := r.validatedActionBaseDirectory(w, payload.Path)
	if !ok {
		return
	}
	workingDir, ok := r.commandActionWorkingDir(scope, action)
	if !ok {
		writeError(w, http.StatusForbidden, "action working_dir 不在当前工作区授权范围内或不可访问")
		return
	}

	start := time.Now()
	result := runConfiguredCommandAction(req.Context(), action, workingDir)
	result.ID = strings.TrimSpace(action.ID)
	result.Name = strings.TrimSpace(action.Name)
	result.Path = realPath
	result.WorkingDir = workingDir
	result.Command = strings.TrimSpace(action.Command)
	result.Args = append([]string(nil), action.Args...)
	result.DurationMillis = time.Since(start).Milliseconds()
	writeJSON(w, http.StatusOK, result)
}

func (r *Router) validatedActionBaseDirectory(w http.ResponseWriter, rawPath string) (string, gatewayScope, bool) {
	path := strings.TrimSpace(rawPath)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return "", gatewayScope{}, false
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return "", gatewayScope{}, false
	}
	realPath := scope.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return "", gatewayScope{}, false
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是目录")
		return "", gatewayScope{}, false
	}
	return realPath, scope, true
}

func (r *Router) commandActionByID(id string) (config.ActionConfig, bool) {
	for _, action := range r.cfg.Actions {
		if strings.TrimSpace(action.ID) == id {
			return action, true
		}
	}
	return config.ActionConfig{}, false
}

func (r *Router) commandActionWorkingDir(scope gatewayScope, action config.ActionConfig) (string, bool) {
	root := r.commandActionScopeRoot(scope)
	if root == "" {
		return "", false
	}
	base := scope.realPath
	if base == "" {
		base = root
	}
	raw := strings.TrimSpace(action.WorkingDir)
	candidate := base
	if raw != "" {
		if filepath.IsAbs(raw) {
			candidate = raw
		} else {
			candidate = filepath.Join(base, raw)
		}
	}
	abs, err := filepath.Abs(candidate)
	if err != nil {
		return "", false
	}
	realDir, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", false
	}
	if !realPathWithin(root, realDir) {
		return "", false
	}
	stat, err := os.Stat(realDir)
	if err != nil || !stat.IsDir() {
		return "", false
	}
	return realDir, true
}

func (r *Router) commandActionScopeRoot(scope gatewayScope) string {
	if scope.managed {
		if worktree, ok := r.managedWorktreeForPath(scope.realPath); ok {
			return worktree.Path
		}
	}
	if !scope.browse && scope.project.RealPath != "" {
		return scope.project.RealPath
	}
	return scope.realPath
}

func runConfiguredCommandAction(ctx context.Context, action config.ActionConfig, dir string) commandActionRunResponse {
	timeout := commandActionTimeout(action)
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	stdout := &cappedBuffer{limit: commandActionMaxOutputBytes}
	stderr := &cappedBuffer{limit: 16 * 1024}
	cmd := exec.CommandContext(ctx, strings.TrimSpace(action.Command), action.Args...)
	cmd.Dir = dir
	cmd.Stdout = stdout
	cmd.Stderr = stderr

	err := cmd.Run()
	response := commandActionRunResponse{
		Success:   err == nil,
		ExitCode:  0,
		Output:    combinedCommandActionOutput(stdout.String(), stderr.String()),
		Truncated: stdout.truncated || stderr.truncated,
	}
	if err == nil {
		return response
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		response.TimedOut = true
		response.ExitCode = -1
		response.Output = appendCommandActionOutput(response.Output, fmt.Sprintf("命令超过 %d 秒后已停止。", int(timeout.Seconds())))
		return response
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		response.ExitCode = exitError.ExitCode()
		return response
	}
	response.ExitCode = -1
	response.Output = appendCommandActionOutput(response.Output, err.Error())
	return response
}

func commandActionTimeout(action config.ActionConfig) time.Duration {
	if action.TimeoutSeconds <= 0 {
		return commandActionDefaultTimeout
	}
	return time.Duration(action.TimeoutSeconds) * time.Second
}

func commandActionTimeoutSeconds(action config.ActionConfig) int {
	return int(commandActionTimeout(action).Seconds())
}

func combinedCommandActionOutput(stdout string, stderr string) string {
	output := strings.TrimSpace(stdout)
	stderr = strings.TrimSpace(stderr)
	if stderr == "" {
		return output
	}
	if output == "" {
		return stderr
	}
	return output + "\n\nstderr:\n" + stderr
}

func appendCommandActionOutput(output string, line string) string {
	line = strings.TrimSpace(line)
	if line == "" {
		return output
	}
	if strings.TrimSpace(output) == "" {
		return line
	}
	return output + "\n" + line
}
