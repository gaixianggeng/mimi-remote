package httpapi

import (
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
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
	// 配对票据在签名覆盖的 expires_at 之前可重复兑换，便于同一二维码或复制链接
	// 连续配对多台设备及安全重试。这里保持无状态，过期、篡改和未来时间仍由
	// ValidatePairingTicket 统一 fail-closed；设备身份与传输边界继续由客户端后续校验。
	response := pairingClaimResponse{
		Endpoint: strings.TrimSpace(payload.Endpoint),
		Token:    token,
	}
	if publicKey := strings.TrimSpace(payload.TailcatClientKey); publicKey != "" {
		if r.tailcat == nil {
			writeError(w, http.StatusServiceUnavailable, "Tailcat 实验未启用")
			return
		}
		managedSessionID := strings.TrimSpace(payload.ManagedSessionID)
		managedGrant := strings.TrimSpace(payload.ManagedGrant)
		if (managedSessionID == "") != (managedGrant == "") {
			writeError(w, http.StatusBadRequest, "托管配对会话和授权必须同时提供")
			return
		}
		var status tailcatStatus
		var err error
		if managedSessionID != "" {
			if r.managedPairing == nil {
				writeError(w, http.StatusServiceUnavailable, "Mimi 托管连接尚未初始化")
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
		if err != nil || !status.Running || strings.TrimSpace(status.Address) == "" {
			if err != nil {
				writeError(w, http.StatusServiceUnavailable, err.Error())
			} else {
				writeError(w, http.StatusServiceUnavailable, "Tailcat 稳定连接尚未就绪")
			}
			return
		}
		response.TailcatAddress = status.Address
	} else if strings.TrimSpace(payload.ManagedSessionID) != "" || strings.TrimSpace(payload.ManagedGrant) != "" {
		writeError(w, http.StatusBadRequest, "托管配对必须提供 Tailcat 客户端公钥")
		return
	}
	// 票据仍只签名短期 IP Endpoint；名称来自当前本机 CLI，避免把可变 DNSName
	// 放进二维码或当作信任依据。LAN/loopback 票据不会附带 Tailscale 路由。
	if tailscaleinfo.IsTailscaleEndpoint(response.Endpoint) && r.tailscaleHostLookup != nil {
		host := r.tailscaleHostLookup(req.Context())
		response.TailscaleDNSName = host.DNSName
		response.TailscaleDeviceName = host.DeviceName
	}
	writeJSON(w, http.StatusOK, response)
}
