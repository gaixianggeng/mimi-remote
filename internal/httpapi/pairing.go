package httpapi

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
	"github.com/google/uuid"
)

const (
	localPairingHeader   = "X-Mimi-Local-Pairing"
	localPairingEndpoint = "http://127.0.0.1:8787"
)

type pairingClaimRequest struct {
	Endpoint         string `json:"endpoint"`
	IssuedAt         string `json:"issued_at"`
	ExpiresAt        string `json:"expires_at"`
	Signature        string `json:"pair_sig"`
	TailcatClientKey string `json:"tailcat_client_key,omitempty"`
	ManagedSessionID string `json:"managed_pairing_session_id,omitempty"`
	ManagedGrant     string `json:"managed_pairing_grant,omitempty"`
}

type pairingClaimResponse struct {
	Endpoint            string `json:"endpoint"`
	Token               string `json:"token"`
	TailscaleDNSName    string `json:"tailscale_dns_name,omitempty"`
	TailscaleDeviceName string `json:"tailscale_device_name,omitempty"`
	TailcatAddress      string `json:"tailcat_address,omitempty"`
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
	if failure := r.pairingGateFor(req.Context(), nil, passivePairing, ""); failure != nil {
		writePairingFailure(w, failure)
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
		writeTicketError(w, err)
		return
	}
	token := strings.TrimSpace(r.cfg.Auth.Token)
	if token == "" {
		writeError(w, http.StatusServiceUnavailable, "auth.token 未配置")
		return
	}
	// 配对票据在签名覆盖的 expires_at 之前可重复兑换，便于同一二维码或复制链接
	// 连续配对多台设备及安全重试。这里保持无状态，过期、篡改和未来时间仍由
	// ValidatePairingTicket 统一 fail-closed；设备身份与传输边界继续由客户端后续校验。
	response := pairingClaimResponse{
		Endpoint: strings.TrimSpace(payload.Endpoint),
		Token:    token,
	}
	publicKey := strings.TrimSpace(payload.TailcatClientKey)
	managedSessionID := strings.TrimSpace(payload.ManagedSessionID)
	managedGrant := strings.TrimSpace(payload.ManagedGrant)
	if publicKey != "" {
		// 自建白名单写入不能越过远程升级的设备数检查。
		r.tailcatControlMu.Lock()
		defer r.tailcatControlMu.Unlock()
	}
	if managedSessionID != "" || managedGrant != "" {
		if r.tailcat == nil || r.tailcat.Status(req.Context()).Mode != config.TailcatModeManaged {
			writeManagedModeRequired(w)
			return
		}
	} else if publicKey != "" && r.tailcat != nil {
		// 不带托管授权的设备走免费节点，托管节点不会放行它。免费节点还没就绪时不能写白名单，
		// 否则设备拿不到能用的地址。
		if status := r.tailcat.Status(req.Context()); status.Mode == config.TailcatModeManaged && status.FreeAddress == "" {
			writeManagedGrantRequired(w)
			return
		}
	}
	if publicKey != "" && r.tailcat == nil {
		markPairingFailure(w, "tailcat_relay_unreachable", "network_tailcat")
		writeError(w, http.StatusServiceUnavailable, "Tailcat 未启用")
		return
	}
	if (managedSessionID == "") != (managedGrant == "") {
		writeError(w, http.StatusBadRequest, "托管配对会话和授权必须同时提供")
		return
	}
	if publicKey == "" && managedGrant != "" {
		writeError(w, http.StatusBadRequest, "托管配对必须提供 Tailcat 客户端公钥")
		return
	}
	if managedGrant != "" {
		session, parseErr := uuid.Parse(managedSessionID)
		_, grantErr := decodeManagedDeviceToken(managedGrant)
		if parseErr != nil || session.Version() != 4 || grantErr != nil || !validManagedTailcatPublicKey(publicKey) {
			writeError(w, http.StatusBadRequest, "托管配对信息无效")
			return
		}
	}
	if publicKey != "" && (ticket.Endpoint != localPairingEndpoint || !validManagedTailcatPublicKey(publicKey)) {
		writeError(w, http.StatusBadRequest, "Tailcat 配对信息无效")
		return
	}
	// 票据仍只签名短期 IP Endpoint；名称来自当前本机 CLI，避免把可变 DNSName
	// 放进二维码或当作信任依据。LAN/loopback 票据不会附带 Tailscale 路由。
	if tailscaleinfo.IsTailscaleEndpoint(response.Endpoint) && r.tailscaleHostLookup != nil {
		host := r.tailscaleHostLookup(req.Context())
		response.TailscaleDNSName = host.DNSName
		response.TailscaleDeviceName = host.DeviceName
	}
	var generation string
	if publicKey != "" {
		generation = r.currentPairingGeneration(req.Context())
		if generation == "" {
			writePairingFailure(w, pairingFailure("service_version_mismatch", "service_daemon"))
			return
		}
	}
	failure := r.pairingGateFor(req.Context(), func(ctx context.Context) *tailcatActionFailure {
		if publicKey != "" {
			return r.tailcatRoute(ctx)
		}
		return r.directRoute(ctx, ticket.Endpoint)
	}, explicitPairing, generation)
	if err := auth.ValidatePairingTicket(token, ticket, time.Now()); err != nil {
		writeTicketError(w, err)
		return
	}
	if failure != nil {
		writePairingFailure(w, failure)
		return
	}
	if publicKey != "" {
		var status tailcatStatus
		var err error
		if managedSessionID != "" {
			if r.managedPairing == nil {
				writeError(w, http.StatusServiceUnavailable, "Mimi 中转尚未初始化")
				return
			}
			status, err = r.managedPairing.Complete(
				req.Context(),
				managedSessionID,
				managedGrant,
				publicKey,
			)
		} else {
			status, err = r.tailcat.AllowClient(req.Context(), publicKey)
		}
		if errors.Is(err, errTailcatManagedModeRequired) {
			writeManagedModeRequired(w)
			return
		}
		if errors.Is(err, errTailcatManagedGrantRequired) {
			writeManagedGrantRequired(w)
			return
		}
		if err != nil || !status.Running || strings.TrimSpace(status.Address) == "" {
			if err != nil {
				writeTailcatClaimFailure(w, err)
			} else {
				writeError(w, http.StatusServiceUnavailable, "Tailcat 稳定连接尚未就绪")
			}
			return
		}
		// Cloud authorization or a sidecar write can outlast the original observation.
		failure = r.pairingGateFor(req.Context(), r.tailcatRoute, explicitPairing, generation)
		if err := auth.ValidatePairingTicket(token, ticket, time.Now()); err != nil {
			writeTicketError(w, err)
			return
		}
		if failure != nil {
			writePairingFailure(w, failure)
			return
		}
		response.TailcatAddress = status.Address
		if managedSessionID == "" && status.Mode == config.TailcatModeManaged {
			response.TailcatAddress = status.FreeAddress
		}
		if strings.TrimSpace(response.TailcatAddress) == "" {
			writeManagedGrantRequired(w)
			return
		}
	}
	writeJSON(w, http.StatusOK, response)
}

func writeManagedModeRequired(w http.ResponseWriter) {
	writeJSON(w, http.StatusConflict, map[string]string{"code": "tailcat_managed_mode_required", "error": errTailcatManagedModeRequired.Error()})
}

func writeManagedGrantRequired(w http.ResponseWriter) {
	writeJSON(w, http.StatusConflict, map[string]string{"code": "tailcat_managed_grant_required", "error": errTailcatManagedGrantRequired.Error()})
}

func writeTailcatClaimFailure(w http.ResponseWriter, err error) {
	var cloud *managedCloudError
	_, negotiated := w.(*pairingErrorWriter)
	if negotiated && errors.As(err, &cloud) {
		switch cloud.Code {
		case "no_current_entitlement", "subscription_required":
			markPairingFailure(w, "pair_managed_entitlement_required", "network_tailcat")
			writeError(w, http.StatusForbidden, "此托管连接需要有效的订阅权益")
			return
		case "pairing_grant_invalid", "pairing_session_expired", "pairing_not_authorized":
			writeManagedGrantRequired(w)
			return
		}
	}
	// Preserve public legacy reasons without reflecting a filesystem, sidecar
	// or cloud error containing a path, identifier or credential.
	if !negotiated {
		switch msg := err.Error(); msg {
		case "Tailcat 稳定连接尚未就绪", "Tailcat 控制通道不可用", "托管配对公钥与已授权移动设备不一致",
			"Mimi 中转尚未初始化", "Mimi 中转策略已经失效", "Mimi 中转策略身份或版本无效", "Mimi 中转策略版本发生回退",
			"no_current_entitlement", "subscription_required", "pairing_grant_invalid", "pairing_session_expired", "pairing_not_authorized":
			writeError(w, http.StatusServiceUnavailable, msg)
			return
		}
	}
	markPairingFailure(w, "tailcat_relay_unreachable", "network_tailcat")
	writeError(w, http.StatusServiceUnavailable, "Tailcat 连接尚未就绪")
}
