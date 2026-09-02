package httpapi

import (
	"crypto/subtle"
	"net/http"
	"strings"

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
		writeJSON(w, http.StatusOK, r.tailcat.Status(req.Context()))
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
	switch strings.ToLower(strings.TrimSpace(payload.Action)) {
	case "enable":
		if _, err := agentsetup.ConfigureTailcat(r.configPath, true); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if err := r.tailcat.Start(req.Context()); err != nil {
			_, _ = agentsetup.ConfigureTailcat(r.configPath, false)
			_ = r.tailcat.Stop(req.Context())
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, r.tailcat.Status(req.Context()))
	case "disable":
		if _, err := agentsetup.ConfigureTailcat(r.configPath, false); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if err := r.tailcat.Stop(req.Context()); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, r.tailcat.Status(req.Context()))
	case "pair":
		status, err := r.tailcat.Pair(req.Context())
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, status)
	case "reset":
		status, err := r.tailcat.Reset(req.Context())
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, status)
	case "configure":
		status, err := r.tailcat.ConfigureDERPMap(req.Context(), payload.DERPMapURL)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, status)
	default:
		writeError(w, http.StatusBadRequest, "Tailcat action 只支持 enable、disable、pair、reset 或 configure")
	}
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
