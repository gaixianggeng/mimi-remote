package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"runtime"
	"strconv"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

func requestPairIssue(parent context.Context, path string, network agentsetup.PairingNetwork) (agentsetup.Result, error) {
	return requestPairIssueWithDial(parent, path, network, coreDialForConfig(config.ExpandPath(path)))
}

func requestPairIssueWithDial(parent context.Context, path string, network agentsetup.PairingNetwork, dial coreDialFunc) (agentsetup.Result, error) {
	var result agentsetup.Result
	ctx, cancel := context.WithTimeout(parent, 25*time.Second)
	defer cancel()
	path = config.ExpandPath(path)
	cfg, err := config.LoadForLocalControl(path)
	if err != nil {
		return result, err
	}
	if network == agentsetup.PairingNetworkAuto && cfg.HasNetworkModuleControls() && !cfg.TailscaleAccessEnabled() && !cfg.LANAccessEnabled() {
		return result, agentsetup.NoPairingNetworkError(runtime.GOOS)
	}
	_, port, err := net.SplitHostPort(cfg.Listen)
	number, numberErr := strconv.Atoi(port)
	if err != nil || numberErr != nil || number <= 0 || number > 65535 {
		return result, onboardingFailure("config_invalid", "config_store", true, errors.New("服务监听端口无效"))
	}
	localToken, err := httpapi.ReadTailcatLocalControlToken(path)
	if err != nil {
		return result, onboardingFailure("service_not_running", "service_daemon", true, errors.New("本机配对控制尚未就绪"))
	}
	raw, err := json.Marshal(map[string]string{"network": string(network), "generation": cfg.SourceGeneration(), "version": version})
	if err != nil {
		return result, err
	}
	target := "http://" + net.JoinHostPort("127.0.0.1", port) + "/api/local/pair/issue"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(raw))
	if err != nil {
		return result, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.Auth.Token)
	req.Header.Set(httpapi.TailcatLocalControlHeader, localToken)
	client := coreHTTPClientWithDial(ctx, dial)
	defer client.CloseIdleConnections()
	resp, err := client.Do(req)
	if err != nil {
		code := "service_not_running"
		var ownerErr agentsetup.PreflightHostError
		if errors.As(err, &ownerErr) {
			code = string(ownerErr)
		} else if ctx.Err() != nil {
			code = "probe_timeout"
		}
		return result, onboardingFailure(code, "service_daemon", true, errors.New("无法连接已验证的本机服务"))
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, (64<<10)+1))
	if err != nil || len(data) > 64<<10 {
		return result, onboardingFailure("pair_host_unreachable", "service_daemon", true, errors.New("无法读取本机配对响应"))
	}
	if resp.StatusCode != http.StatusOK {
		var failure struct{ Code, Step string }
		if json.Unmarshal(data, &failure) != nil || failure.Code == "" || failure.Step == "" {
			failure.Code, failure.Step = "service_version_mismatch", "service_daemon"
			if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusUnauthorized {
				failure.Code = "pair_token_mismatch"
			}
		}
		diagnostic := agentsetup.OnboardingDiagnostic(failure.Code, failure.Step, "pair", true, "")
		return result, onboardingFailure(diagnostic.Code, diagnostic.Step, true, errors.New(diagnostic.Message))
	}
	if json.Unmarshal(data, &result) != nil || !validIssuedPair(cfg.Auth.Token, port, network, result) {
		return agentsetup.Result{}, onboardingFailure("pair_host_unreachable", "service_daemon", true, errors.New("本机服务未返回当前连接方式的有效配对票据"))
	}
	return result, nil
}

func validIssuedPair(token, port string, selected agentsetup.PairingNetwork, result agentsetup.Result) bool {
	link, err := url.Parse(result.PairURL)
	if err != nil || link.Scheme != "mimiremote" || link.Host != "pair" {
		return false
	}
	q := link.Query()
	if q.Has("token") || q.Get("endpoint") != result.Endpoint || q.Get("expires_at") != result.PairExpiresAt {
		return false
	}
	ticket := auth.PairingTicket{Endpoint: result.Endpoint, IssuedAt: q.Get("issued_at"), ExpiresAt: q.Get("expires_at"), Signature: q.Get("pair_sig")}
	if auth.ValidatePairingTicket(token, ticket, time.Now()) != nil || (selected != agentsetup.PairingNetworkAuto && selected != result.Network) {
		return false
	}
	if result.Network == agentsetup.PairingNetworkTailcat {
		return selected == agentsetup.PairingNetworkTailcat && q.Get("transport") == "tailcat" && q.Get("tailcat_pair_address") != "" && result.Endpoint == "http://127.0.0.1:8787"
	}
	endpoint, err := url.Parse(result.Endpoint)
	if err != nil || endpoint.Scheme != "http" || endpoint.Port() != port || endpoint.User != nil || endpoint.Path != "" || endpoint.RawQuery != "" || endpoint.Fragment != "" || q.Get("transport") != "" {
		return false
	}
	ip, err := netip.ParseAddr(endpoint.Hostname())
	if err != nil {
		return false
	}
	switch result.Network {
	case agentsetup.PairingNetworkTailscale:
		return tailscaleinfo.IsTailscaleAddress(ip)
	case agentsetup.PairingNetworkLAN:
		return ip.Is4() && ip.IsPrivate()
	default:
		return false
	}
}
