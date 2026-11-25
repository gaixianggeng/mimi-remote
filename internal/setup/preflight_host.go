package setup

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type PreflightHostError string

func (e PreflightHostError) Error() string { return string(e) }

// The configured listen address contributes only a port. Never send the host
// credential to a configured remote address, proxy, or redirect destination.
func FetchPreflightHost(parent context.Context, cfg config.Config) (PreflightHost, error) {
	var host PreflightHost
	_, port, err := net.SplitHostPort(cfg.Listen)
	number, parseErr := strconv.Atoi(port)
	if err != nil || parseErr != nil || number < 1 || number > 65535 {
		return host, PreflightHostError("service_not_running")
	}
	if strings.TrimSpace(cfg.Auth.Token) == "" {
		return host, PreflightHostError("pair_token_mismatch")
	}
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+net.JoinHostPort("127.0.0.1", strconv.Itoa(number))+"/api/local/preflight", nil)
	if err != nil {
		return host, PreflightHostError("service_not_running")
	}
	req.Header.Set("Authorization", "Bearer "+cfg.Auth.Token)
	client := http.Client{Transport: &http.Transport{DisableKeepAlives: true, MaxResponseHeaderBytes: 16 << 10}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return host, PreflightHostError("probe_timeout")
		}
		return host, PreflightHostError("service_not_running")
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusUnauthorized, http.StatusForbidden:
		return host, PreflightHostError("pair_token_mismatch")
	case http.StatusNotFound:
		return host, PreflightHostError("service_version_mismatch")
	default:
		return host, PreflightHostError("service_start_failed")
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, (16<<10)+1))
	if ctx.Err() != nil {
		return host, PreflightHostError("probe_timeout")
	}
	if err != nil || len(raw) > 16<<10 || json.Unmarshal(raw, &host) != nil || host.Version == "" || host.Assistants == nil || host.Networks == nil {
		return PreflightHost{}, PreflightHostError("service_version_mismatch")
	}
	return host, nil
}
