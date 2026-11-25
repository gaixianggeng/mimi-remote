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
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type PreflightHostError string

func (e PreflightHostError) Error() string { return string(e) }

// The configured listen address contributes only a port. Never send the host
// credential to a configured remote address, proxy, or redirect destination.
func FetchPreflightHost(parent context.Context, cfg config.Config) (PreflightHost, error) {
	return fetchPreflightHost(parent, cfg, nil)
}

func fetchPreflightHost(parent context.Context, cfg config.Config, dial func(context.Context, string, string) (net.Conn, error)) (PreflightHost, error) {
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
	transport := &http.Transport{DisableKeepAlives: true, MaxResponseHeaderBytes: 16 << 10}
	if dial != nil {
		transport.DialContext = func(_ context.Context, network, addr string) (net.Conn, error) { return dial(ctx, network, addr) }
	}
	client := http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		var ownerErr PreflightHostError
		if errors.As(err, &ownerErr) {
			return host, ownerErr
		}
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
	// A healthy owner may still be serving the previous saved configuration.
	// Its applied module flags are authoritative, but its account and permission
	// observations do not describe the document currently under inspection.
	if host.Generation == "" || host.Generation != cfg.SourceGeneration() {
		host.Accounts = nil
		host.FolderDenied = false
	}
	return host, nil
}

// AgentVersionsCompatible applies the same version policy to active and passive readiness checks.
func AgentVersionsCompatible(expectedVersion string, runningVersion string) bool {
	expected := strings.TrimSpace(expectedVersion)
	running := strings.TrimSpace(runningVersion)
	if isDevelopmentAgentVersion(expected) || running == expected {
		return true
	}
	// 独立安装的正式 CLI 只有 marketing version，应能检查同版本的 Mac 构建。
	// 反向不放宽：App 内嵌版本含 mac build，必须精确识别覆盖安装后的旧进程。
	return !strings.Contains(expected, "+") &&
		strings.HasPrefix(running, expected+"+mac.")
}

func isDevelopmentAgentVersion(value string) bool {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" || normalized == "devel" || normalized == "(devel)" {
		return true
	}
	// GoReleaser/本地 make 会把提交摘要追加成 devel-<sha>；它和裸 devel
	// 一样没有可用于部署一致性判断的正式版本，不能误报 App 托管服务过旧。
	return strings.HasPrefix(normalized, "devel-") ||
		strings.Contains(normalized, "-next") ||
		strings.Contains(normalized, "dirty")
}
