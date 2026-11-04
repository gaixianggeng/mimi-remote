package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
	"github.com/google/uuid"
)

const tailcatActivationPath = "/api/tailcat/managed-pairing-operations"

type tailcatActivationResult struct {
	ID      string                             `json:"id"`
	State   string                             `json:"state"`
	Result  *tailcatManagedPairingLinkResponse `json:"result,omitempty"`
	Code    string                             `json:"code,omitempty"`
	Message string                             `json:"message,omitempty"`
}

type tailcatActivationOperation struct {
	result  tailcatActivationResult
	expires time.Time
	cancel  context.CancelFunc
}

// 只保存本机短期操作。重启后客户端重新发起即可；不新增持久任务系统。
type tailcatActivationStore struct {
	mu         sync.Mutex
	closed     bool
	operations map[string]*tailcatActivationOperation
	wg         sync.WaitGroup
}

func (s *tailcatActivationStore) close() {
	s.mu.Lock()
	s.closed = true
	for _, op := range s.operations {
		op.cancel()
	}
	s.mu.Unlock()
	s.wg.Wait()
}

func (r *Router) tailcatActivationHandler(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	s := &r.tailcatActivation
	if req.Method == http.MethodGet && strings.HasPrefix(req.URL.Path, tailcatActivationPath+"/") {
		id := strings.TrimPrefix(req.URL.Path, tailcatActivationPath+"/")
		s.mu.Lock()
		op := s.operations[id]
		if op == nil || time.Now().After(op.expires) {
			s.mu.Unlock()
			writeJSON(w, http.StatusNotFound, map[string]string{"code": "tailcat_operation_expired", "error": "启用记录已过期，请重试"})
			return
		}
		result := op.result
		s.mu.Unlock()
		writeJSON(w, http.StatusOK, result)
		return
	}
	if req.Method != http.MethodPost || req.URL.Path != tailcatActivationPath {
		methodNotAllowed(w)
		return
	}
	var payload struct {
		RequestID string `json:"request_id"`
	}
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	if _, err := uuid.Parse(payload.RequestID); err != nil {
		writeError(w, http.StatusBadRequest, "request_id 必须是 UUID")
		return
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		writeError(w, http.StatusServiceUnavailable, "服务正在关闭")
		return
	}
	if op := s.operations[payload.RequestID]; op != nil && time.Now().Before(op.expires) {
		result := op.result
		s.mu.Unlock()
		writeJSON(w, http.StatusAccepted, result)
		return
	}
	for id, op := range s.operations {
		if time.Now().After(op.expires) {
			delete(s.operations, id)
		}
	}
	// 上限和过期一起约束配对链接的存活范围；不会挤掉另一台手机正在取回的结果。
	if len(s.operations) >= 16 {
		s.mu.Unlock()
		writeError(w, http.StatusTooManyRequests, "请稍后重试")
		return
	}
	if !r.tailcatControlMu.TryLock() {
		s.mu.Unlock()
		writeJSON(w, http.StatusConflict, map[string]string{"code": "tailcat_operation_in_progress", "error": "连接设置正在更新，请稍后重试"})
		return
	}
	// 切换辅助程序会断开当前 Tailcat HTTP 请求。操作由 Router 管理，不能随这个请求取消而回滚。
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	op := &tailcatActivationOperation{result: tailcatActivationResult{ID: payload.RequestID, State: "pending"}, expires: time.Now().Add(10 * time.Minute), cancel: cancel}
	if s.operations == nil {
		s.operations = make(map[string]*tailcatActivationOperation)
	}
	s.operations[payload.RequestID] = op
	s.wg.Add(1)
	s.mu.Unlock()
	writeJSON(w, http.StatusAccepted, op.result)
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
	go func() {
		defer s.wg.Done()
		defer cancel()
		defer r.tailcatControlMu.Unlock()
		result, failure := r.activateTailcatRelay(ctx)
		s.mu.Lock()
		defer s.mu.Unlock()
		if failure != nil {
			op.result.State, op.result.Code, op.result.Message = "failed", failure.code, failure.err.Error()
		} else {
			op.result.State, op.result.Result = "completed", &result
		}
	}()
}

func (r *Router) activateTailcatRelay(ctx context.Context) (tailcatManagedPairingLinkResponse, *tailcatActionFailure) {
	var previous tailcatStatus
	if r.tailcat != nil {
		previous = r.tailcat.Status(ctx)
	}
	result, failure := r.createTailcatManagedPairingLink(ctx, tailcatManagedPairingLinkRequest{})
	if failure == nil || r.tailcat == nil || r.managedPairing == nil {
		return result, failure
	}
	// 新启用失败要恢复本次改动；已经在用中转的电脑不因一次二维码失败而被全局停用。
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
	if rollbackErr != nil {
		failure = &tailcatActionFailure{status: http.StatusServiceUnavailable, code: "tailcat_activation_rollback_failed",
			err: errors.New("启用未完成，恢复原连接设置失败，请在电脑上检查")}
	}
	return result, failure
}

// 已拥有电脑访问凭据的设备可以登记自己的免费节点。它不读取或修改官方中转白名单。
func (r *Router) tailcatFreeRouteHandler(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload struct {
		ClientKey string `json:"client_key"`
	}
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	if !validManagedTailcatPublicKey(payload.ClientKey) {
		writeError(w, http.StatusBadRequest, "设备公钥无效")
		return
	}
	if !r.tailcatControlMu.TryLock() {
		writeError(w, http.StatusConflict, "连接设置正在更新，请稍后重试")
		return
	}
	defer r.tailcatControlMu.Unlock()
	if r.tailcat == nil {
		writeError(w, http.StatusServiceUnavailable, "内置连接未启用")
		return
	}
	status := r.tailcat.Status(req.Context())
	if !status.Enabled || !status.Running || (status.Mode == config.TailcatModeManaged && status.FreeAddress == "") {
		writeError(w, http.StatusServiceUnavailable, "免费连接尚未就绪")
		return
	}
	status, err := r.tailcat.AllowClient(req.Context(), payload.ClientKey)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "无法准备免费连接，请重试")
		return
	}
	address := status.Address
	if status.Mode == config.TailcatModeManaged {
		address = status.FreeAddress
	}
	if address == "" {
		writeError(w, http.StatusServiceUnavailable, "免费连接尚未就绪")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"tailcat_address": address})
}
