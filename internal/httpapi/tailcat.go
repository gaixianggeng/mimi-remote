package httpapi

import (
	"context"
	"crypto/subtle"
	"errors"
	"net/http"
	"strings"
	"time"

	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

type tailcatControlRequest struct {
	Action     string `json:"action"`
	DERPMapURL string `json:"derp_map_url,omitempty"`
}

func (r *Router) tailcatLocalHandler(w http.ResponseWriter, req *http.Request) {
	if !r.isAuthorizedTailcatLocalRequest(req) {
		writeError(w, http.StatusForbidden, "Tailcat 实验只允许本机 Mimi 客户端控制")
		return
	}
	if r.tailcat == nil {
		writeError(w, http.StatusServiceUnavailable, "Tailcat 管理器未初始化")
		return
	}
	switch req.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, r.decorateTailcatStatus(r.tailcat.Status(req.Context())))
	case http.MethodPost:
		r.tailcatLocalAction(w, req)
	default:
		methodNotAllowed(w)
	}
}

func (r *Router) tailcatLocalAction(w http.ResponseWriter, req *http.Request) {
	var payload tailcatControlRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	r.tailcatControlMu.Lock()
	defer r.tailcatControlMu.Unlock()
	switch strings.ToLower(strings.TrimSpace(payload.Action)) {
	case "enable":
		if failure := r.enableTailcat(req.Context()); failure != nil {
			writeError(w, failure.status, failure.err.Error())
			return
		}
		writeJSON(w, http.StatusOK, r.decorateTailcatStatus(r.tailcat.Status(req.Context())))
	case "disable":
		if _, err := agentsetup.ConfigureTailcat(r.configPath, false); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if err := r.tailcat.Stop(req.Context()); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, r.decorateTailcatStatus(r.tailcat.Status(req.Context())))
	case "pair":
		status, failure := r.pairTailcat(req.Context())
		if failure != nil {
			writeError(w, failure.status, failure.err.Error())
			return
		}
		writeJSON(w, http.StatusOK, status)
	case "reset":
		var managedResetErr error
		if r.managedPairing != nil {
			managedResetContext, cancel := context.WithTimeout(context.WithoutCancel(req.Context()), 10*time.Second)
			managedResetErr = r.managedPairing.Reset(managedResetContext)
			cancel()
		}
		// 显式重置必须同时移除托管授权和 clients.json 中的免费授权。
		// 即使请求已取消或托管状态落盘失败，也不能跳过底层 Tailcat 身份重置。
		tailcatResetContext, cancel := context.WithTimeout(context.WithoutCancel(req.Context()), 10*time.Second)
		status, tailcatResetErr := r.tailcat.Reset(tailcatResetContext)
		cancel()
		if err := errors.Join(managedResetErr, tailcatResetErr); err != nil {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, r.decorateTailcatStatus(status))
	case "enter-managed", "exit-managed":
		if r.managedPairing == nil {
			writeError(w, http.StatusServiceUnavailable, "Mimi 托管连接尚未初始化")
			return
		}
		status, err := r.managedPairing.ConfigureMode(req.Context(), strings.TrimSpace(strings.ToLower(payload.Action)) == "enter-managed")
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, r.decorateTailcatStatus(status))
	case "configure":
		status, err := r.tailcat.ConfigureDERPMap(req.Context(), payload.DERPMapURL)
		if err != nil {
			if errors.Is(err, errTailcatManagedRelayLocked) {
				writeJSON(w, http.StatusConflict, map[string]string{"code": "tailcat_managed_relay_locked", "error": err.Error()})
				return
			}
			if r.managedPairing != nil {
				// 配置失败可能已经回滚并重启旧 sidecar。新进程内存中没有
				// 托管白名单，必须立即重放最后有效策略，不能等待五分钟轮询。
				reconcileContext, cancel := context.WithTimeout(context.WithoutCancel(req.Context()), 10*time.Second)
				err = errors.Join(err, r.managedPairing.Sync(reconcileContext))
				cancel()
			}
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, r.decorateTailcatStatus(status))
	default:
		writeError(w, http.StatusBadRequest, "Tailcat action 只支持 enable、disable、pair、reset、configure、enter-managed 或 exit-managed")
	}
}

func (r *Router) decorateTailcatStatus(status tailcatStatus) tailcatStatus {
	status.MacInstallationID = strings.TrimSpace(r.installationID)
	return status
}

func (r *Router) isAuthorizedTailcatLocalRequest(req *http.Request) bool {
	if !isLoopbackPairingRequest(req) || strings.TrimSpace(req.Header.Get("Origin")) != "" {
		return false
	}
	expected := strings.TrimSpace(r.tailcatLocalToken)
	provided := strings.TrimSpace(req.Header.Get(TailcatLocalControlHeader))
	if expected == "" || len(expected) != len(provided) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(expected), []byte(provided)) == 1
}
