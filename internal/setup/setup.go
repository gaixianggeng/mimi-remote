package setup

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const defaultAgentDPort = "8787"
const defaultPairingURLTTL = 10 * time.Minute

type Options struct {
	ConfigPath      string
	ScanRoot        string
	BrowseRoot      string
	Listen          string
	AppServerListen string
	Force           bool
}

type Result struct {
	Created            bool           `json:"created"`
	ConfigPath         string         `json:"config_path"`
	Endpoint           string         `json:"endpoint"`
	Network            PairingNetwork `json:"network,omitempty"`
	Token              string         `json:"token"`
	ConnectURL         string         `json:"connect_url"`
	PairURL            string         `json:"pair_url"`
	PairIssuedAt       string         `json:"pair_issued_at"`
	PairExpiresAt      string         `json:"pair_expires_at"`
	ScanRoot           string         `json:"scan_root"`
	BrowseRoot         string         `json:"browse_root"`
	AppServerListen    string         `json:"app_server_listen"`
	AppServerTokenFile string         `json:"app_server_token_file"`
	Warnings           []string       `json:"warnings"`
}

func Run(ctx context.Context, options Options) (Result, error) {
	return runWithFileOps(ctx, options, defaultSetupFileTransactionOps())
}

func runWithFileOps(ctx context.Context, options Options, fileOps setupFileTransactionOps) (Result, error) {
	cfgPath, err := resolveConfigPath(options.ConfigPath)
	if err != nil {
		return Result{}, err
	}
	configExisted, err := regularFileOrMissing(cfgPath, "配置文件")
	if err != nil {
		return Result{}, err
	}
	if configExisted && !options.Force {
		// 已有配置时默认只读取配对信息，避免误覆盖用户已经绑定到 iPad 的 token。
		result, err := Pair(ctx, cfgPath)
		if err != nil {
			return Result{}, err
		}
		result.Created = false
		return result, nil
	}

	cfgDir := filepath.Dir(cfgPath)
	cfgDirExisted := true
	if info, statErr := os.Stat(cfgDir); statErr != nil {
		if !os.IsNotExist(statErr) {
			return Result{}, fmt.Errorf("读取配置目录状态失败：%w", statErr)
		}
		cfgDirExisted = false
	} else if !info.IsDir() {
		return Result{}, fmt.Errorf("配置目录路径不是目录：%s", cfgDir)
	}
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		return Result{}, fmt.Errorf("创建配置目录失败：%w", err)
	}
	filesCommitted := false
	defer func() {
		if !cfgDirExisted && !filesCommitted {
			// 首次安装失败时只删除本次新建且仍为空的末级目录；并发写入或残留文件会让 Remove 安全失败。
			_ = os.Remove(cfgDir)
		}
	}()
	token, err := randomHex(32)
	if err != nil {
		return Result{}, err
	}
	// 外侧 token 给 iPad 访问 agentd 使用；upstream token 只留在 Mac 本机，避免客户端拿到 app-server 直连凭证。
	appServerToken, err := randomHex(32)
	if err != nil {
		return Result{}, err
	}
	tokenFile := filepath.Join(cfgDir, "app-server-ws-token")

	scanRoot, err := defaultScanRoot(options.ScanRoot)
	if err != nil {
		return Result{}, err
	}
	browseRoot, err := defaultBrowseRoot(options.BrowseRoot)
	if err != nil {
		return Result{}, err
	}
	// 默认生成一个真机可连接的配置：优先 Tailscale；缺失时自动开放局域网。
	// 显式 --listen 仍完全尊重调用方，保留 loopback 模拟器/开发场景。
	listen := strings.TrimSpace(options.Listen)
	allowLAN := false
	if listen == "" {
		listen, allowLAN, err = defaultAgentDNetwork(ctx, defaultPairingNetworkLookups())
		if err != nil {
			return Result{}, err
		}
	}
	appServerListen := strings.TrimSpace(options.AppServerListen)
	if appServerListen == "" {
		appServerListen = "ws://127.0.0.1:4222"
	}

	cfg := config.Config{
		Listen:  listen,
		Network: config.NetworkConfig{AllowLAN: allowLAN},
		Auth: config.AuthConfig{
			Token: token,
		},
		Runtime: config.RuntimeConfig{
			Type: "codex_app_server",
		},
		AppServer: config.AppServerConfig{
			Transport:   "ws",
			Managed:     true,
			Listen:      appServerListen,
			WSTokenFile: tokenFile,
		},
		Codex: config.CodexConfig{
			Bin:         defaultCodexBin(),
			DefaultArgs: []string{"--no-alt-screen"},
			Env: map[string]string{
				"TERM": "xterm-256color",
			},
		},
		Session: config.SessionConfig{
			OutputBufferBytes: 128 * 1024,
		},
		ScanRoots:   []string{scanRoot},
		BrowseRoots: []string{browseRoot},
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return Result{}, fmt.Errorf("编码配置失败：%w", err)
	}
	if err := writeSetupFilesAtomically(
		cfgPath,
		tokenFile,
		append(raw, '\n'),
		[]byte(appServerToken+"\n"),
		fileOps,
	); err != nil {
		return Result{}, fmt.Errorf("原子写入 setup 配置失败：%w", err)
	}
	filesCommitted = true

	result, err := Pair(ctx, cfgPath)
	if err != nil {
		return Result{}, err
	}
	result.Created = true
	result.ScanRoot = scanRoot
	result.BrowseRoot = browseRoot
	result.AppServerListen = appServerListen
	result.AppServerTokenFile = tokenFile
	return result, nil
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
	result, _ := ResultFromConfigForNetwork(ctx, configPath, cfg, PairingNetworkAuto)
	return result
}

func ResultFromConfigForNetwork(
	ctx context.Context,
	configPath string,
	cfg config.Config,
	network PairingNetwork,
) (Result, error) {
	endpoint, warnings, err := pairingEndpoint(ctx, cfg, network, defaultPairingNetworkLookups())
	if err != nil {
		return Result{}, err
	}
	token := strings.TrimSpace(cfg.Auth.Token)
	if token == "" {
		warnings = append(warnings, "配置中没有 auth.token，iPad 无法完成鉴权；请重新执行 agentd setup --force")
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
		ConfigPath:         configPath,
		Endpoint:           endpoint,
		Network:            pairingNetworkForEndpoint(endpoint),
		Token:              token,
		ConnectURL:         connectionURL("connect", endpoint, token, now, expiresAt),
		PairURL:            pairingURL(endpoint, token, now, expiresAt),
		PairIssuedAt:       now.Format(time.RFC3339),
		PairExpiresAt:      expiresAt.Format(time.RFC3339),
		ScanRoot:           scanRoot,
		BrowseRoot:         browseRoot,
		AppServerListen:    cfg.AppServer.Listen,
		AppServerTokenFile: cfg.AppServer.WSTokenFile,
		Warnings:           warnings,
	}, nil
}

func ConnectURL(endpoint, token string) string {
	now := time.Now().UTC()
	return connectionURL("connect", endpoint, token, now, now.Add(defaultPairingURLTTL))
}

func PairURL(endpoint, token string) string {
	now := time.Now().UTC()
	return pairingURL(endpoint, token, now, now.Add(defaultPairingURLTTL))
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

func defaultScanRoot(raw string) (string, error) {
	if strings.TrimSpace(raw) != "" {
		return filepath.Abs(raw)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	codeDir := filepath.Join(home, "code")
	if stat, err := os.Stat(codeDir); err == nil && stat.IsDir() {
		return codeDir, nil
	}
	cwd, err := os.Getwd()
	if err == nil && strings.HasPrefix(cwd, home) {
		// 没有 ~/code 时优先使用用户当前运行 setup 的目录，避免默认扫描整个 Home。
		return cwd, nil
	}
	return home, nil
}

// defaultBrowseRoot 决定 iPad 目录浏览/打开 workspace 的授权根。和 scan root 分开：
// scan root 控制项目发现 + gateway 项目 allowlist，browse root 只扩大“可打开的目录”，
// 默认给整个用户 Home，这样 ~/finance 这类不在扫描根里的目录也能打开。
func defaultBrowseRoot(raw string) (string, error) {
	if strings.TrimSpace(raw) != "" {
		return filepath.Abs(raw)
	}
	return os.UserHomeDir()
}

func defaultAgentDNetwork(
	ctx context.Context,
	lookups pairingNetworkLookups,
) (listen string, allowLAN bool, err error) {
	if ip := strings.TrimSpace(lookups.tailscaleIP(ctx)); ip != "" {
		return net.JoinHostPort(ip, defaultAgentDPort), false, nil
	}
	if ip := net.ParseIP(strings.TrimSpace(lookups.lanIP())); isPrivateLANIPv4(ip) {
		// LAN IP 会随 DHCP/Wi-Fi 切换变化，因此监听通配地址并在生成配对码时动态选当前 LAN IP。
		return net.JoinHostPort("0.0.0.0", defaultAgentDPort), true, nil
	}
	return "", false, fmt.Errorf(
		"未检测到 Tailscale 或可用的局域网 IPv4；请先连接 Wi-Fi/以太网，或为本机开发显式传入 --listen 127.0.0.1:%s",
		defaultAgentDPort,
	)
}

func defaultCodexBin() string {
	if path, err := ResolveCodexBin("codex"); err == nil {
		return path
	}
	return "codex"
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
			warnings = append(warnings, "agentd 绑定在所有网卡，但未检测到 Tailscale IP；请确认 iPad 能访问这台 Mac")
		}
	}
	if isLoopbackHost(host) {
		warnings = append(warnings, "当前 Endpoint 是本机地址，只适合 Mac 本机或模拟器；iPad 真机建议先安装并登录 Tailscale，再重新运行 agentd up")
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
	bin, err := exec.LookPath("tailscale")
	if err != nil {
		return ""
	}
	runCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(runCtx, bin, "ip", "-4").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		ip := strings.TrimSpace(line)
		if net.ParseIP(ip) != nil {
			return ip
		}
	}
	return ""
}

func randomHex(bytes int) (string, error) {
	buf := make([]byte, bytes)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("生成随机 token 失败：%w", err)
	}
	return hex.EncodeToString(buf), nil
}
