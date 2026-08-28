package httpapi

import (
	"crypto/subtle"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const remoteGatewayMaxConnections = 1

// RemoteGatewayHandler 是给 `codex --remote` 使用的独立根路径 WebSocket。
// 监听器由 agentd 单独绑定 loopback；这里再次验证 peer 和 token，避免配置漂移扩大边界。
func (r *Router) RemoteGatewayHandler() http.Handler {
	return http.HandlerFunc(r.remoteGatewayWS)
}

func (r *Router) remoteGatewayWS(w http.ResponseWriter, req *http.Request) {
	if req.URL.Path != "/" {
		http.NotFound(w, req)
		return
	}
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !remoteGatewayPeerIsLoopback(req.RemoteAddr) {
		writeError(w, http.StatusForbidden, "remote gateway 只接受 loopback peer")
		return
	}
	if !sameOriginOrNoOrigin(req) {
		writeError(w, http.StatusForbidden, "Origin 不允许访问 remote gateway")
		return
	}
	if !websocket.IsWebSocketUpgrade(req) {
		writeError(w, http.StatusBadRequest, "remote gateway 需要 WebSocket Upgrade")
		return
	}
	token, err := r.readRemoteGatewayToken()
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "remote gateway 鉴权配置不可用，请运行 agentd doctor")
		return
	}
	if subtle.ConstantTimeCompare([]byte(remoteGatewayBearerToken(req.Header.Get("Authorization"))), []byte(token)) != 1 {
		w.Header().Set("WWW-Authenticate", "Bearer")
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if !r.acquireRemoteGatewaySlot() {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "remote gateway 已有客户端连接")
		return
	}
	defer r.releaseRemoteGatewaySlot()

	upstreamURL, err := r.appServerUpstreamWebSocketURL()
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "Codex app-server 上游配置不可用，请运行 agentd doctor")
		return
	}
	upstreamHeaders, err := r.appServerUpstreamHeaders()
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "Codex app-server 上游鉴权不可用，请运行 agentd doctor")
		return
	}
	dialer, err := r.appServerUpstreamDialer(4 * time.Second)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "Codex app-server 上游配置不可用，请运行 agentd doctor")
		return
	}
	client, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("remote gateway ws upgrade failed err=%v", err)
		return
	}
	defer client.Close()
	dialStart := time.Now()
	upstream, _, err := dialer.DialContext(req.Context(), upstreamURL, upstreamHeaders)
	dialDuration := time.Since(dialStart)
	if err != nil {
		r.monitor.recordGatewayDialFailure(dialDuration, err)
		writeCodexGatewayRuntimeError(client, "CODEX_UPSTREAM_UNAVAILABLE", "Codex app-server 暂时不可用，请稍后重试")
		return
	}
	defer upstream.Close()
	monitor := r.monitor.startGatewayConnection(requestRemoteHost(req), req.Host, sanitizeGatewayURL(upstreamURL), dialDuration)
	r.proxyAppServerGateway(req.Context(), client, upstream, monitor, appServerGatewayClientRemoteCLI)
}

func (r *Router) readRemoteGatewayToken() (string, error) {
	path := strings.TrimSpace(r.cfg.AppServer.RemoteGateway.TokenFile)
	if path == "" {
		return "", fmt.Errorf("remote gateway token file 未配置")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("remote gateway token file 不是 regular file")
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return "", fmt.Errorf("remote gateway token file 权限必须是 0600")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(raw))
	if len(token) < 32 {
		return "", fmt.Errorf("remote gateway token 太短")
	}
	if token == strings.TrimSpace(r.cfg.Auth.Token) {
		return "", fmt.Errorf("remote gateway token 不能复用 agentd token")
	}
	if upstreamHeaders, err := r.appServerUpstreamHeaders(); err == nil &&
		remoteGatewayBearerToken(upstreamHeaders.Get("Authorization")) == token {
		return "", fmt.Errorf("remote gateway token 不能复用 app-server upstream token")
	}
	return token, nil
}

func remoteGatewayBearerToken(raw string) string {
	parts := strings.SplitN(raw, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}

func remoteGatewayPeerIsLoopback(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(strings.TrimSpace(remoteAddr))
	if err != nil {
		return false
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

func (r *Router) acquireRemoteGatewaySlot() bool {
	r.remoteGatewayMu.Lock()
	defer r.remoteGatewayMu.Unlock()
	if r.activeRemoteGateway >= remoteGatewayMaxConnections {
		return false
	}
	r.activeRemoteGateway++
	return true
}

func (r *Router) releaseRemoteGatewaySlot() {
	r.remoteGatewayMu.Lock()
	if r.activeRemoteGateway > 0 {
		r.activeRemoteGateway--
	}
	r.remoteGatewayMu.Unlock()
}
