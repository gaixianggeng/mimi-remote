package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func (r *Router) tailcatActivationRollbackHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	id := strings.TrimSuffix(strings.TrimPrefix(req.URL.Path, tailcatActivationPath+"/"), "/rollback")
	s := &r.tailcatActivation
	s.mu.Lock()
	op := s.operations[id]
	if op == nil || time.Now().After(op.expires) {
		s.mu.Unlock()
		writeError(w, http.StatusNotFound, "启用记录已过期")
		return
	}
	if op.rolledBack || op.result.State == "failed" && op.result.Code != "tailcat_activation_rollback_failed" {
		s.mu.Unlock()
		writeJSON(w, http.StatusOK, map[string]string{"state": "rolled_back"})
		return
	}
	if op.result.State == "pending" {
		op.rollbackRequested = true
		op.cancel()
		s.mu.Unlock()
		writeJSON(w, http.StatusAccepted, map[string]string{"state": "rolling_back"})
		return
	}
	if op.rollingBack || !r.tailcatControlMu.TryLock() {
		s.mu.Unlock()
		writeJSON(w, http.StatusConflict, map[string]string{"code": "tailcat_operation_in_progress", "error": "连接设置正在更新，请稍后重试"})
		return
	}
	op.rollingBack = true
	previous, activated := op.previous, op.activated
	s.mu.Unlock()
	defer r.tailcatControlMu.Unlock()
	defer func() { s.mu.Lock(); op.rollingBack = false; s.mu.Unlock() }()
	if r.tailcat == nil || r.managedPairing == nil {
		writeError(w, http.StatusServiceUnavailable, "Mimi 中转尚未初始化")
		return
	}
	current := r.tailcat.Status(req.Context())
	// 后来的配对或电脑上的手动切换不属于本次失败，迟到的回滚不能覆盖它们。
	if current.Mode == config.TailcatModeManaged &&
		(current.PublicKey != activated.PublicKey || current.PairPublicKey != activated.PairPublicKey) {
		writeJSON(w, http.StatusConflict, map[string]string{"code": "tailcat_operation_superseded", "error": "电脑的连接设置已变化"})
		return
	}
	err := r.restoreTailcatActivation(req.Context(), previous)
	s.mu.Lock()
	if err == nil {
		op.rolledBack = true
		op.result.State, op.result.Code, op.result.Message = "failed", "tailcat_activation_rolled_back", "未启用中转，已恢复原连接"
	}
	s.mu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"code": "tailcat_activation_rollback_failed", "error": "恢复原连接设置失败，请在电脑上检查"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": "rolled_back"})
}

func (r *Router) restoreTailcatActivation(ctx context.Context, previous tailcatStatus) error {
	// 请求可能随线路切换断开，恢复本次改动仍需完成；原来就在用 Mimi 的电脑不被全局停用。
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	var rollbackErr error
	if previous.Mode != config.TailcatModeManaged && r.tailcat.Status(cleanup).Mode == config.TailcatModeManaged {
		_, rollbackErr = r.managedPairing.ConfigureMode(cleanup, false)
	}
	if !previous.Enabled && r.tailcat.Status(cleanup).Enabled {
		_, configErr := agentsetup.ConfigureTailcat(r.configPath, false)
		rollbackErr = errors.Join(rollbackErr, configErr, r.tailcat.Stop(cleanup))
	}
	return rollbackErr
}
