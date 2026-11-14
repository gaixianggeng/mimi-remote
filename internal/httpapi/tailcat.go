package httpapi

import (
	"context"
	"crypto/subtle"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

type tailcatControlRequest struct {
	Action     string `json:"action"`
	DERPMapURL string `json:"derp_map_url,omitempty"`
	// relay-set 专用：default / custom / mimi。
	Choice string `json:"choice,omitempty"`
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
			writeError(w, http.StatusServiceUnavailable, "Mimi 中转尚未初始化")
			return
		}
		status, err := r.managedPairing.ConfigureMode(req.Context(), strings.TrimSpace(strings.ToLower(payload.Action)) == "enter-managed")
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, r.decorateTailcatStatus(status))
	case "relay-set":
		status, failure := r.setTailcatRelay(req.Context(), payload.Choice, payload.DERPMapURL)
		if failure != nil {
			writeJSON(w, failure.status, map[string]string{"code": failure.code, "error": failure.err.Error()})
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
		writeError(w, http.StatusBadRequest, "Tailcat action 只支持 enable、disable、pair、reset、configure、enter-managed、exit-managed 或 relay-set")
	}
}

// setTailcatRelay 把“选择中转”这件多步操作收敛成一条命令，Mac 和 Windows 客户端
// 只调它，不再各写一遍编排。退出托管和更换中继必须共享一次事务，保留连接开关并回读。
func (r *Router) setTailcatRelay(ctx context.Context, choice, rawURL string) (tailcatStatus, *tailcatActionFailure) {
	choice = strings.ToLower(strings.TrimSpace(choice))
	switch choice {
	case "default", "custom", "mimi":
	default:
		return tailcatStatus{}, &tailcatActionFailure{
			status: http.StatusBadRequest,
			code:   "tailcat_relay_choice_invalid",
			err:    errors.New("中转选择只支持 default、custom 或 mimi"),
		}
	}

	relayURL := ""
	if choice == "custom" {
		normalized, err := config.NormalizeTailcatDERPMapURL(rawURL)
		if err != nil {
			return tailcatStatus{}, &tailcatActionFailure{status: http.StatusBadRequest, code: "tailcat_relay_url_invalid", err: err}
		}
		if normalized == "" {
			return tailcatStatus{}, &tailcatActionFailure{
				status: http.StatusBadRequest,
				code:   "tailcat_relay_url_invalid",
				err:    errors.New("请输入完整的 DERP Map HTTPS 地址"),
			}
		}
		if normalized == r.managedRelayURL() {
			return tailcatStatus{}, &tailcatActionFailure{
				status: http.StatusBadRequest,
				code:   "tailcat_relay_url_invalid",
				err:    errors.New("使用 Mimi 中转时，请直接选择 Mimi 中转"),
			}
		}
		relayURL = normalized
	}

	wasEnabled := r.tailcat.Status(ctx).Enabled
	// 已有托管控制器时由它保护注册与身份回滚；旧入口继续保留兼容。
	if choice == "mimi" || r.tailcat.Status(ctx).Mode == config.TailcatModeManaged {
		if r.managedPairing == nil {
			return tailcatStatus{}, &tailcatActionFailure{
				status: http.StatusServiceUnavailable,
				code:   "tailcat_managed_unavailable",
				err:    errors.New("Mimi 托管连接尚未初始化"),
			}
		}
		var status tailcatStatus
		var err error
		if choice == "mimi" {
			status, err = r.managedPairing.ConfigureMode(ctx, true)
		} else {
			status, err = r.managedPairing.ConfigureRelay(ctx, relayURL)
		}
		if err != nil {
			return status, &tailcatActionFailure{status: http.StatusServiceUnavailable, code: "tailcat_managed_mode_failed", err: err}
		}
	} else {
		status, err := r.tailcat.ConfigureDERPMap(ctx, relayURL)
		if err != nil {
			if r.managedPairing != nil {
				// 配置失败可能已经回滚并重启旧 sidecar，必须立即重放最后有效策略。
				reconcileContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
				err = errors.Join(err, r.managedPairing.Sync(reconcileContext))
				cancel()
			}
			return status, &tailcatActionFailure{status: http.StatusInternalServerError, code: "tailcat_relay_configure_failed", err: err}
		}
	}

	if wasEnabled {
		if failure := r.enableTailcat(ctx); failure != nil {
			return tailcatStatus{}, failure
		}
	}

	status := r.tailcat.Status(ctx)
	if (choice == "mimi" && status.Mode != config.TailcatModeManaged) ||
		(choice != "mimi" && (status.Mode == config.TailcatModeManaged || status.DERPMapURL != relayURL)) {
		return status, &tailcatActionFailure{
			status: http.StatusInternalServerError,
			code:   "tailcat_relay_not_applied",
			err:    errors.New("中转配置尚未生效，请刷新后重试"),
		}
	}
	return status, nil
}

// managedRelayURL 返回当前环境认定的 Mimi 中继地址：配置里覆盖过就用配置的，
// 否则回退到内置默认值。客户端把官方地址填进“自建中转”时必须被挡住，
// 否则会生成一张注定被拒的二维码。
func (r *Router) managedRelayURL() string {
	configured := strings.TrimSpace(r.cfg.Tailcat.ManagedDERPMapURL)
	if configured == "" {
		return config.DefaultManagedTailcatDERPMapURL
	}
	return configured
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
