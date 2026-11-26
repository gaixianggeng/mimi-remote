package setup

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// Direct setup has historically been able to produce a LAN link before the
// service starts. With no loopback listener, inspect the local Windows policy
// directly. When a daemon is listening its own executable and ingress decision
// are authoritative; authentication, timeout and incompatible replies fail closed.
func confirmResidentPairingLAN(parent context.Context, cfg config.Config, offline func(context.Context, bool) string, trusted func(context.Context, net.Conn) bool) error {
	ctx, cancel := context.WithTimeout(parent, 25*time.Second)
	defer cancel()
	_, rawPort, err := net.SplitHostPort(cfg.Listen)
	port, parseErr := strconv.Atoi(rawPort)
	if err != nil || parseErr != nil || port < 1 || port > 65535 {
		return pairingLANTrouble("lan_firewall_blocked")
	}
	if strings.TrimSpace(cfg.Auth.Token) == "" {
		return pairingLANTrouble("pair_token_mismatch")
	}
	url := "http://" + net.JoinHostPort("127.0.0.1", strconv.Itoa(port)) + "/api/local/lan-policy"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return pairingLANTrouble("lan_firewall_blocked")
	}
	req.Header.Set("Authorization", "Bearer "+cfg.Auth.Token)
	// Dial and prove ownership before net/http can transmit the bearer.
	// Installation or port changes cannot swap the checked connection.
	untrusted := errors.New("unverified loopback owner")
	tr := &http.Transport{DisableKeepAlives: true, MaxResponseHeaderBytes: 16 << 10}
	tr.DialContext = func(_ context.Context, network, addr string) (net.Conn, error) {
		conn, err := (&net.Dialer{}).DialContext(ctx, "tcp4", addr)
		if err != nil {
			return nil, err
		}
		if !trusted(ctx, conn) {
			_ = conn.Close()
			return nil, untrusted
		}
		return conn, nil
	}
	client := http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return pairingLANTrouble("probe_timeout")
		}
		if errors.Is(err, untrusted) {
			return pairingLANTrouble("service_port_in_use")
		}
		// WSAECONNREFUSED is distinct from syscall.ECONNREFUSED on Windows.
		if errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.Errno(10061)) {
			return pairingLANTrouble(offline(ctx, true))
		}
		return pairingLANTrouble("lan_firewall_blocked")
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusUnauthorized, http.StatusForbidden:
		return pairingLANTrouble("pair_token_mismatch")
	default:
		return pairingLANTrouble("service_version_mismatch")
	}
	var result struct {
		Allowed *bool
		Code    string
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1025))
	if ctx.Err() != nil {
		return pairingLANTrouble("probe_timeout")
	}
	if err != nil || len(b) > 1024 || json.Unmarshal(b, &result) != nil || result.Allowed == nil || *result.Allowed != (result.Code == "") {
		return pairingLANTrouble("service_version_mismatch")
	}
	return pairingLANTrouble(result.Code)
}

func pairingLANTrouble(code string) error {
	if code == "" {
		return nil
	}
	step := "network_lan"
	switch code {
	case "pair_token_mismatch", "service_version_mismatch", "service_port_in_use":
		step = "service_daemon"
	case "lan_public_network_blocked", "lan_firewall_blocked", "probe_timeout":
	default:
		code = "lan_firewall_blocked"
	}
	safe := OnboardingDiagnostic(code, step, "pair", true, "")
	return &PairingDiagnostic{code, step, safe.Message}
}
