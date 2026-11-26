package setup

import (
	"context"
	"crypto/rand"
	"encoding/hex"

	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"

	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

const defaultAgentDPort = "8787"
const defaultPairingURLTTL = 10 * time.Minute

type Options struct {
	ConfigPath                             string
	ScanRoot                               string
	BrowseRoot                             string
	Listen                                 string
	AppServerSSHTarget                     string
	Force                                  bool
	SaveOnly, CreateRoot, PendingWorkspace bool
	RequireExisting                        bool
	RuntimePaths, Assistants               map[string]string
	LegacyPath                             string
	// LocalServiceOnly 用于 up --no-pair：新建或沿用配置后都只返回本机就绪检查需要的
	// Token 与 loopback Endpoint，不要求存在可配对的 Tailscale 或局域网地址（#874）。
	LocalServiceOnly bool
	// CodexBin overrides CLI discovery for embedding integrations and tests.
	CodexBin string
	// ObserveAssistant supplies verified, read-only runtime observations for embedded callers.
	ObserveAssistant func(context.Context, string, config.Config, string, PreflightHost) PreflightObservation
}

type Result struct {
	Migrated            bool           `json:"-"`
	Created             bool           `json:"created"`
	ConfigPath          string         `json:"config_path"`
	Endpoint            string         `json:"endpoint"`
	Network             PairingNetwork `json:"network,omitempty"`
	TailscaleDNSName    string         `json:"tailscale_dns_name,omitempty"`
	TailscaleDeviceName string         `json:"tailscale_device_name,omitempty"`
	Token               string         `json:"token"`
	ConnectURL          string         `json:"connect_url"`
	PairURL             string         `json:"pair_url"`
	PairIssuedAt        string         `json:"pair_issued_at"`
	PairExpiresAt       string         `json:"pair_expires_at"`
	ScanRoot            string         `json:"scan_root"`
	BrowseRoot          string         `json:"browse_root"`
	AppServerSSHTarget  string         `json:"app_server_ssh_target"`
	Warnings            []string       `json:"warnings"`
}

func Run(ctx context.Context, options Options) (Result, error) {
	return runWithFileOps(ctx, options, defaultSetupFileTransactionOps())
}

func normalizeSetupAppServerSSHTarget(raw string) (string, error) {
	value := raw
	if strings.TrimSpace(value) == "" {
		value = os.Getenv("AGENTD_APP_SERVER_SSH_TARGET")
	}
	if strings.TrimSpace(value) == "" {
		value = config.DefaultAppServerSSHTarget()
	}
	if err := appserver.ValidateSSHTarget(value); err != nil {
		return "", fmt.Errorf("app_server.ssh_target 无效：%w", err)
	}
	return value, nil
}

func Pair(ctx context.Context, configPath string) (Result, error) {
	return PairForNetwork(ctx, configPath, PairingNetworkAuto)
}

func PairForNetwork(ctx context.Context, configPath string, network PairingNetwork) (Result, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return Result{}, err
	}
	cfg, err := config.LoadForDoctor(cfgPath)
	if err != nil {
		return Result{}, err
	}
	return ResultFromConfigForNetwork(ctx, cfgPath, cfg, network)
}

func ResultFromConfig(ctx context.Context, configPath string, cfg config.Config) Result {
	result, err := ResultFromConfigForNetwork(ctx, configPath, cfg, PairingNetworkAuto)
	if err == nil {
		return result
	}
	result = localServiceResult(configPath, cfg)
	result.Warnings = []string{err.Error()}
	return result
}

// LocalServiceAccess 只读取本机就绪检查需要的 Token 和 loopback Endpoint，
// 不探测也不要求 Tailscale 或局域网地址。安装器与托盘的 --no-pair 启停只验证服务本身；
// 两种连接方式都关闭时，服务仍须能启动和重启，配对提示留给 pair（#874）。
func LocalServiceAccess(configPath string) (Result, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return Result{}, err
	}
	cfg, err := config.LoadForDoctor(cfgPath)
	if err != nil {
		return Result{}, err
	}
	return localServiceResult(cfgPath, cfg), nil
}

func localServiceResult(configPath string, cfg config.Config) Result {
	_, port := splitListen(cfg.Listen)
	if port == "" {
		port = defaultAgentDPort
	}
	return Result{ConfigPath: configPath, Endpoint: httpEndpoint("127.0.0.1", port), Token: cfg.Auth.Token}
}

func ResultFromConfigForNetwork(
	ctx context.Context,
	configPath string,
	cfg config.Config,
	network PairingNetwork,
) (Result, error) {
	return resultFromConfigForNetwork(ctx, configPath, cfg, network, defaultPairingNetworkLookups())
}

func resultFromConfigForNetwork(
	ctx context.Context,
	configPath string,
	cfg config.Config,
	network PairingNetwork,
	lookups pairingNetworkLookups,
) (Result, error) {
	if !cfg.HasEnabledAgent() {
		return Result{}, &PairingDiagnostic{"no_enabled_assistant", "assistant_any", "全部 AI 编程助手已关闭，请先启用至少一个助手"}
	}
	endpoint, warnings, err := pairingEndpoint(ctx, cfg, network, lookups)
	if err != nil {
		return Result{}, err
	}
	host := tailscaleinfo.Host{}
	if pairingNetworkForEndpoint(endpoint) == PairingNetworkTailscale && lookups.tailscaleHost != nil {
		host = lookups.tailscaleHost(ctx)
	}
	token := strings.TrimSpace(cfg.Auth.Token)
	if token == "" {
		warnings = append(warnings, "配置中没有 auth.token，移动设备无法完成鉴权；请在本机检查保留的配置")
	}
	scanRoot := ""
	if len(cfg.ScanRoots) > 0 {
		scanRoot = cfg.ScanRoots[0]
	}
	browseRoot := ""
	if len(cfg.BrowseRoots) > 0 {
		browseRoot = cfg.BrowseRoots[0]
	}
	now := time.Now().UTC()
	expiresAt := now.Add(defaultPairingURLTTL)
	return Result{
		ConfigPath:          configPath,
		Endpoint:            endpoint,
		Network:             pairingNetworkForEndpoint(endpoint),
		TailscaleDNSName:    host.DNSName,
		TailscaleDeviceName: host.DeviceName,
		Token:               token,
		ConnectURL:          connectionURL("connect", endpoint, token, now, expiresAt),
		PairURL:             pairingURL(endpoint, token, now, expiresAt),
		PairIssuedAt:        now.Format(time.RFC3339),
		PairExpiresAt:       expiresAt.Format(time.RFC3339),
		ScanRoot:            scanRoot,
		BrowseRoot:          browseRoot,
		AppServerSSHTarget:  cfg.AppServer.SSHTarget,
		Warnings:            warnings,
	}, nil
}

func connectionURL(route, endpoint, token string, issuedAt, expiresAt time.Time) string {
	values := url.Values{}
	values.Set("endpoint", endpoint)
	values.Set("token", token)
	if !issuedAt.IsZero() {
		values.Set("issued_at", issuedAt.UTC().Format(time.RFC3339))
	}
	if !expiresAt.IsZero() {
		values.Set("expires_at", expiresAt.UTC().Format(time.RFC3339))
	}
	return "mimiremote://" + route + "?" + values.Encode()
}

func pairingURL(endpoint, token string, issuedAt, expiresAt time.Time) string {
	ticket := auth.NewPairingTicket(endpoint, token, issuedAt, expiresAt)
	values := url.Values{}
	values.Set("endpoint", ticket.Endpoint)
	values.Set("issued_at", ticket.IssuedAt)
	values.Set("expires_at", ticket.ExpiresAt)
	values.Set("pair_sig", ticket.Signature)
	return "mimiremote://pair?" + values.Encode()
}

func resolveConfigPath(path string) (string, error) {
	value := strings.TrimSpace(path)
	if value == "" {
		value = config.DefaultPath()
	}
	if strings.HasPrefix(value, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		value = filepath.Join(home, strings.TrimPrefix(value, "~/"))
	}
	abs, err := filepath.Abs(value)
	if err != nil {
		return "", fmt.Errorf("解析配置路径失败：%w", err)
	}
	return abs, nil
}

func endpointForListen(ctx context.Context, listen string) (string, []string) {
	host, port := splitListen(listen)
	warnings := []string{}
	if port == "" {
		port = defaultAgentDPort
	}
	if host == "" {
		host = "127.0.0.1"
	}
	if host == "0.0.0.0" || host == "::" || host == "[::]" {
		if ip := firstTailscaleIP(ctx); ip != "" {
			host = ip
		} else {
			host = "127.0.0.1"
			warnings = append(warnings, "agentd 绑定在所有网卡，但未检测到 Tailscale IP；请确认移动设备能访问这台电脑")
		}
	}
	if isLoopbackHost(host) {
		warnings = append(warnings, "当前 Endpoint 是本机地址，只适合这台电脑本机或模拟器；移动设备连接前建议先安装并登录 Tailscale，或显式启用受限的局域网访问")
	}
	return (&url.URL{Scheme: "http", Host: net.JoinHostPort(host, port)}).String(), warnings
}

func splitListen(listen string) (string, string) {
	value := strings.TrimSpace(listen)
	if value == "" {
		return "", ""
	}
	if strings.Contains(value, "://") {
		if parsed, err := url.Parse(value); err == nil {
			value = parsed.Host
		}
	}
	host, port, err := net.SplitHostPort(value)
	if err == nil {
		return strings.Trim(host, "[]"), port
	}
	if strings.Count(value, ":") == 0 {
		return value, ""
	}
	return "", ""
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

func firstTailscaleIP(ctx context.Context) string {
	return tailscaleinfo.FirstIPv4(ctx)
}

func randomHex(bytes int) (string, error) {
	buf := make([]byte, bytes)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("生成随机 token 失败：%w", err)
	}
	return hex.EncodeToString(buf), nil
}
