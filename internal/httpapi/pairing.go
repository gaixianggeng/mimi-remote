package httpapi

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
)

const maxConsumedPairingTickets = 256

var (
	errPairingTicketConsumed = errors.New("配对票据已使用，请在 Mac 上重新生成二维码")
	errPairingClaimStoreFull = errors.New("短期配对请求过多，请稍后重新生成二维码")
)

type pairingClaimRequest struct {
	Endpoint  string `json:"endpoint"`
	IssuedAt  string `json:"issued_at"`
	ExpiresAt string `json:"expires_at"`
	Signature string `json:"pair_sig"`
}

type pairingClaimResponse struct {
	Endpoint string `json:"endpoint"`
	Token    string `json:"token"`
}

func (r *Router) pairingClaimHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	var payload pairingClaimRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	ticket := auth.PairingTicket{
		Endpoint:  payload.Endpoint,
		IssuedAt:  payload.IssuedAt,
		ExpiresAt: payload.ExpiresAt,
		Signature: payload.Signature,
	}
	now := time.Now().UTC()
	if err := auth.ValidatePairingTicket(r.cfg.Auth.Token, ticket, now); err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	token := strings.TrimSpace(r.cfg.Auth.Token)
	if token == "" {
		writeError(w, http.StatusServiceUnavailable, "auth.token 未配置")
		return
	}
	if err := r.consumePairingTicket(ticket, now); err != nil {
		// 已通过签名校验但发生重放时使用 Conflict，客户端可明确提示重新生成二维码；
		// 响应不包含长期 Token，也不区分具体已消费时间。
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, pairingClaimResponse{
		Endpoint: strings.TrimSpace(payload.Endpoint),
		Token:    token,
	})
}

func (r *Router) consumePairingTicket(ticket auth.PairingTicket, now time.Time) error {
	expiresAt, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(ticket.ExpiresAt))
	if err != nil {
		// 调用方必须先完成 ValidatePairingTicket；这里仍 fail-closed，避免未来复用时绕过校验。
		return errPairingTicketConsumed
	}
	signature := strings.TrimSpace(ticket.Signature)
	if signature == "" {
		return errPairingTicketConsumed
	}

	r.pairingClaimsMu.Lock()
	defer r.pairingClaimsMu.Unlock()
	if r.pairingClaims == nil {
		r.pairingClaims = make(map[string]time.Time)
	}
	for consumedSignature, expiry := range r.pairingClaims {
		if !now.Before(expiry) {
			delete(r.pairingClaims, consumedSignature)
		}
	}
	if _, exists := r.pairingClaims[signature]; exists {
		return errPairingTicketConsumed
	}
	// 容量满时拒绝新兑换而不是驱逐尚未过期的记录，否则被驱逐票据会重新变成可兑换。
	if len(r.pairingClaims) >= maxConsumedPairingTickets {
		return errPairingClaimStoreFull
	}
	r.pairingClaims[signature] = expiresAt
	return nil
}
