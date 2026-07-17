package httpapi

import (
	"errors"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
)

const (
	maxConsumedPairingTickets = 256
	localPairingHeader        = "X-Mimi-Local-Pairing"
	localPairingEndpoint      = "http://127.0.0.1:8787"
)

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

func (r *Router) localPairingClaimHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	// Catalyst 和 agentd 处在同一登录用户的本机信任域：TCP 来源与 Host 都必须是
	// loopback，自定义请求头 + 禁止 Origin 用于拦截网页跨站探测。远程/LAN 请求绝不返回 Token。
	// 这不隔离同一 Mac 上的恶意本地进程；单用户开发机是当前 MVP 的明确安全前提。
	if !isLoopbackPairingRequest(req) ||
		req.Header.Get(localPairingHeader) != "1" ||
		strings.TrimSpace(req.Header.Get("Origin")) != "" {
		writeError(w, http.StatusForbidden, "本机自动配对仅允许 Mimi Mac 客户端通过 loopback 发起")
		return
	}
	token := strings.TrimSpace(r.cfg.Auth.Token)
	if token == "" {
		writeError(w, http.StatusServiceUnavailable, "auth.token 未配置")
		return
	}
	writeJSON(w, http.StatusOK, pairingClaimResponse{
		Endpoint: localPairingEndpoint,
		Token:    token,
	})
}

func isLoopbackPairingRequest(req *http.Request) bool {
	remoteIP := net.ParseIP(strings.TrimSpace(requestRemoteHost(req)))
	if remoteIP == nil || !remoteIP.IsLoopback() {
		return false
	}

	host := strings.TrimSpace(req.Host)
	if parsedHost, _, err := net.SplitHostPort(host); err == nil {
		host = parsedHost
	} else {
		host = strings.Trim(host, "[]")
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	hostIP := net.ParseIP(host)
	return hostIP != nil && hostIP.IsLoopback()
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
