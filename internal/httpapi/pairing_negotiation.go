package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"strconv"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

const pairingErrorMediaType = "application/vnd.mimi.onboarding.v1+json"

func pairingHTTPPath(path string) bool {
	switch path {
	case "/api/pair/claim", "/api/pair/local", "/api/tailcat/managed-pairing-link", tailcatActivationPath, "/api/tailcat/free-route":
		return true
	}
	return strings.HasPrefix(path, tailcatActivationPath+"/")
}

// Older clients commonly accept */*. Only an explicit supported version
// opts into the onboarding representation.
func acceptsPairingErrors(h http.Header) bool {
	var vendor, legacy float64
	for _, line := range h.Values("Accept") {
		for _, item := range strings.Split(line, ",") {
			media, params, err := mime.ParseMediaType(strings.TrimSpace(item))
			if err != nil {
				continue
			}
			q := 1.0
			if value, ok := params["q"]; ok {
				q, err = strconv.ParseFloat(value, 64)
				if err != nil || !(q > 0 && q <= 1) {
					continue
				}
			}
			switch media {
			case pairingErrorMediaType:
				vendor = max(vendor, q)
			case "application/json":
				legacy = max(legacy, q)
			}
		}
	}
	return vendor > 0 && vendor >= legacy
}

func negotiatePairingErrors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if !pairingHTTPPath(req.URL.Path) {
			next.ServeHTTP(w, req)
			return
		}
		w.Header().Add("Vary", "Accept")
		if !acceptsPairingErrors(req.Header) {
			next.ServeHTTP(w, req)
			return
		}

		writer := &pairingErrorWriter{ResponseWriter: w}
		next.ServeHTTP(writer, req)
		if writer.status >= 400 {
			writer.finish(req.URL.Path)
		}
	})
}

// Keep success responses, including flushed activation acknowledgements, streaming
// normally. Only errors need translation after auth, protocol and input checks.
type pairingErrorWriter struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
	code   string
	step   string
}

func (w *pairingErrorWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	if status < 400 {
		w.ResponseWriter.WriteHeader(status)
	}
}

func (w *pairingErrorWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if w.status >= 400 {
		return w.body.Write(b)
	}
	return w.ResponseWriter.Write(b)
}

func (w *pairingErrorWriter) Flush() {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if w.status < 400 {
		_ = http.NewResponseController(w.ResponseWriter).Flush()
	}
}

func markPairingFailure(w http.ResponseWriter, code, step string) {
	if writer, ok := w.(*pairingErrorWriter); ok {
		writer.code, writer.step = code, step
	}
}

func (w *pairingErrorWriter) finish(path string) {
	code, step := w.code, w.step
	if code == "" {
		var legacy struct {
			Code string `json:"code"`
		}
		_ = json.Unmarshal(w.body.Bytes(), &legacy)
		code, step = pairingFallbackDiagnostic(path, w.status, legacy.Code)
	}
	code, step = pairingPublicDiagnostic(code, step)
	w.Header().Del("Content-Length")
	w.Header().Set("Content-Type", pairingErrorMediaType)
	w.ResponseWriter.WriteHeader(w.status)
	_ = json.NewEncoder(w.ResponseWriter).Encode(struct {
		OK    bool                  `json:"ok"`
		Error setup.OnboardingError `json:"error"`
	}{Error: setup.OnboardingDiagnostic(code, step, "pair", true, "")})
}

// The local CLI has additional diagnostics about files, listeners and service
// installation. Remote callers receive only tuples registered for HTTP.
func pairingPublicDiagnostic(code, step string) (string, string) {
	switch code {
	case "no_enabled_assistant":
		return code, "assistant_any"
	case "workspace_confirmation_required":
		return code, "workspace_root"
	case "tailcat_relay_unreachable", "tailcat_busy", "pair_managed_entitlement_required", "pair_managed_grant_conflict":
		return code, "network_tailcat"
	case "pair_host_unreachable", "pair_token_mismatch", "pair_local_forbidden":
		return code, "service_daemon"
	case "pair_ticket_expired", "pair_ticket_invalid", "pair_clock_skew", "invalid_request":
		return code, "network_any"
	case "probe_timeout", "internal_error":
		return code, step
	}
	switch step {
	case "network_tailcat":
		return "tailcat_relay_unreachable", "network_tailcat"
	case "workspace_root", "service_daemon", "network_tailscale", "network_lan", "network_any":
		return "pair_host_unreachable", "service_daemon"
	}
	return "internal_error", "network_any"
}

func pairingFallbackDiagnostic(path string, status int, legacy string) (string, string) {
	switch legacy {
	case "tailcat_managed_mode_required", "tailcat_managed_grant_required":
		return "pair_managed_grant_conflict", "network_tailcat"
	case "tailcat_agents_disabled":
		return "no_enabled_assistant", "assistant_any"
	case "tailcat_operation_in_progress":
		return "tailcat_busy", "network_tailcat"
	case "tailcat_managed_pairing_unavailable", "tailcat_enable_failed", "tailcat_enable_rollback_failed",
		"tailcat_managed_mode_failed", "tailcat_activation_rollback_failed", "tailcat_operation_superseded",
		"tailcat_status_unavailable", "tailcat_pair_failed", "tailcat_operation_expired":
		return "tailcat_relay_unreachable", "network_tailcat"
	}
	switch status {
	case http.StatusBadRequest, http.StatusMethodNotAllowed, http.StatusRequestEntityTooLarge:
		return "invalid_request", "network_any"
	case http.StatusUnauthorized:
		if path == "/api/pair/claim" {
			return "pair_ticket_invalid", "network_any"
		}
		return "pair_token_mismatch", "service_daemon"
	case http.StatusForbidden:
		if path == "/api/pair/local" {
			return "pair_local_forbidden", "service_daemon"
		}
	case http.StatusConflict, http.StatusTooManyRequests:
		if strings.HasPrefix(path, "/api/tailcat/") {
			return "tailcat_busy", "network_tailcat"
		}
	case http.StatusServiceUnavailable:
		if strings.HasPrefix(path, "/api/tailcat/") {
			return "tailcat_relay_unreachable", "network_tailcat"
		}
	}
	return "internal_error", "network_any"
}

func writeTicketError(w http.ResponseWriter, err error) {
	code := "pair_ticket_invalid"
	switch {
	case errors.Is(err, auth.ErrPairTicketExpired):
		code = "pair_ticket_expired"
	case errors.Is(err, auth.ErrPairClockSkew):
		code = "pair_clock_skew"
	}
	markPairingFailure(w, code, "network_any")
	writeError(w, http.StatusUnauthorized, err.Error())
}
