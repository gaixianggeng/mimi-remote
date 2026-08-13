package setup

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

type PairingNetwork string

const (
	PairingNetworkAuto      PairingNetwork = "auto"
	PairingNetworkTailscale PairingNetwork = "tailscale"
	PairingNetworkLAN       PairingNetwork = "lan"
)

type pairingNetworkLookups struct {
	tailscaleIP   func(context.Context) string
	tailscaleHost func(context.Context) tailscaleinfo.Host
	lanIP         func() string
}

func defaultPairingNetworkLookups() pairingNetworkLookups {
	return pairingNetworkLookups{
		tailscaleIP:   firstTailscaleIP,
		tailscaleHost: tailscaleinfo.Discover,
		lanIP:         firstLANIPv4,
	}
}

func ParsePairingNetwork(raw string) (PairingNetwork, error) {
	network := PairingNetwork(strings.ToLower(strings.TrimSpace(raw)))
	if network == "" {
		network = PairingNetworkAuto
	}
	switch network {
	case PairingNetworkAuto, PairingNetworkTailscale, PairingNetworkLAN:
		return network, nil
	default:
		return "", fmt.Errorf("配对网络只支持 auto、tailscale 或 lan，实际为 %q", raw)
	}
}

func pairingEndpoint(
	ctx context.Context,
	cfg config.Config,
	network PairingNetwork,
	lookups pairingNetworkLookups,
) (string, []string, error) {
	network, err := ParsePairingNetwork(string(network))
	if err != nil {
		return "", nil, err
	}
	if network == PairingNetworkAuto {
		configuredHost, port := splitListen(cfg.Listen)
		if port == "" {
			port = defaultAgentDPort
		}
		configuredIP := net.ParseIP(strings.Trim(configuredHost, "[]"))
		listensEverywhere := configuredIP != nil && configuredIP.IsUnspecified()

		switch {
		case isTailscaleIPv4(configuredIP):
			if strings.TrimSpace(lookups.tailscaleIP(ctx)) != "" {
				return httpEndpoint(configuredIP.String(), port), nil, nil
			}
			if cfg.Network.AllowLAN {
				return pairingEndpoint(ctx, cfg, PairingNetworkLAN, lookups)
			}
			return "", nil, fmt.Errorf("未检测到 Tailscale IPv4，当前服务也尚未启用局域网访问")
		case isPrivateLANIPv4(configuredIP):
			return pairingEndpoint(ctx, cfg, PairingNetworkLAN, lookups)
		case cfg.Network.AllowLAN || listensEverywhere:
			if host := strings.TrimSpace(lookups.tailscaleIP(ctx)); host != "" {
				return httpEndpoint(host, port), nil, nil
			}
			return pairingEndpoint(ctx, cfg, PairingNetworkLAN, lookups)
		default:
			endpoint, warnings := endpointForListen(ctx, cfg.Listen)
			return endpoint, warnings, nil
		}
	}

	configuredHost, port := splitListen(cfg.Listen)
	if port == "" {
		port = defaultAgentDPort
	}
	configuredIP := net.ParseIP(strings.Trim(configuredHost, "[]"))
	listensEverywhere := configuredIP != nil && configuredIP.IsUnspecified()

	switch network {
	case PairingNetworkTailscale:
		if !cfg.Network.AllowLAN && !listensEverywhere && !isTailscaleIPv4(configuredIP) {
			return "", nil, fmt.Errorf("当前服务未监听 Tailscale；请先调整 agentd 网络配置")
		}
		host := ""
		if isTailscaleIPv4(configuredIP) {
			host = configuredIP.String()
		} else {
			host = strings.TrimSpace(lookups.tailscaleIP(ctx))
		}
		if host == "" {
			return "", nil, fmt.Errorf("未检测到 Tailscale IPv4，请确认 Tailscale 已连接")
		}
		return httpEndpoint(host, port), nil, nil

	case PairingNetworkLAN:
		if !cfg.Network.AllowLAN && !listensEverywhere && !isPrivateLANIPv4(configuredIP) {
			return "", nil, fmt.Errorf("尚未启用局域网访问")
		}
		host := ""
		if isPrivateLANIPv4(configuredIP) {
			host = configuredIP.String()
		} else {
			host = strings.TrimSpace(lookups.lanIP())
		}
		if host == "" {
			return "", nil, fmt.Errorf("未检测到可用的局域网 IPv4，请确认这台电脑已连接 Wi-Fi 或以太网")
		}
		return httpEndpoint(host, port), []string{"局域网配对仅适用于与这台电脑位于同一局域网的设备"}, nil
	}

	return "", nil, fmt.Errorf("不支持的配对网络 %q", network)
}

func httpEndpoint(host string, port string) string {
	return (&url.URL{Scheme: "http", Host: net.JoinHostPort(host, port)}).String()
}

func pairingNetworkForEndpoint(endpoint string) PairingNetwork {
	parsed, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil {
		return ""
	}
	ip := net.ParseIP(strings.Trim(parsed.Hostname(), "[]"))
	switch {
	case isTailscaleIPv4(ip):
		return PairingNetworkTailscale
	case isPrivateLANIPv4(ip):
		return PairingNetworkLAN
	default:
		return ""
	}
}

func isTailscaleIPv4(ip net.IP) bool {
	v4 := ip.To4()
	if v4 == nil {
		return false
	}
	// Tailscale IPv4 来自 100.64.0.0/10。
	return v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127
}

func isPrivateLANIPv4(ip net.IP) bool {
	v4 := ip.To4()
	return v4 != nil && v4.IsPrivate() && !isTailscaleIPv4(v4)
}

func firstLANIPv4() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	preferredIP := preferredOutboundLANIPv4()
	candidates := []lanIPv4Candidate{}
	for _, item := range interfaces {
		if item.Flags&net.FlagUp == 0 || item.Flags&net.FlagLoopback != 0 {
			continue
		}
		name := strings.ToLower(item.Name)
		addresses, err := item.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			var ip net.IP
			switch value := address.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if !isPrivateLANIPv4(ip) {
				continue
			}
			candidates = append(candidates, lanIPv4Candidate{
				ip:      ip.String(),
				name:    name,
				score:   lanInterfaceScore(name, ip.String() == preferredIP),
				virtual: likelyVirtualLANInterface(name),
			})
		}
	}
	return selectLANIPv4Candidate(candidates)
}

type lanIPv4Candidate struct {
	ip      string
	name    string
	score   int
	virtual bool
}

func preferredOutboundLANIPv4() string {
	// UDP connect 不会发送数据，只让内核根据当前路由表选择出口地址。相比按网卡名称
	// 排序，它能在 Windows 上避开排在 WLAN 前面的 Hyper-V/WSL 私有地址。
	conn, err := net.DialUDP("udp4", nil, &net.UDPAddr{
		IP:   net.IPv4(8, 8, 8, 8),
		Port: 53,
	})
	if err != nil {
		return ""
	}
	defer conn.Close()
	local, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok || !isPrivateLANIPv4(local.IP) {
		return ""
	}
	return local.IP.String()
}

func lanInterfaceScore(name string, preferred bool) int {
	score := 20
	switch {
	case name == "en0" || name == "en1",
		name == "wlan",
		strings.Contains(name, "wi-fi"),
		strings.Contains(name, "wifi"):
		score = 0
	case strings.HasPrefix(name, "en"),
		strings.Contains(name, "ethernet"):
		score = 5
	case likelyVirtualLANInterface(name):
		score = 100
	}
	if preferred && !likelyVirtualLANInterface(name) {
		score -= 1000
	}
	return score
}

func likelyVirtualLANInterface(name string) bool {
	name = strings.ToLower(strings.TrimSpace(name))
	for _, marker := range []string{
		"vethernet",
		"hyper-v",
		"default switch",
		"wsl",
		"virtualbox",
		"vmware",
		"docker",
		"vmenet",
		"utun",
		"awdl",
		"llw",
		"ipsec",
		"ppp",
	} {
		if strings.Contains(name, marker) {
			return true
		}
	}
	return strings.HasPrefix(name, "bridge")
}

func selectLANIPv4Candidate(candidates []lanIPv4Candidate) string {
	sort.Slice(candidates, func(left, right int) bool {
		if candidates[left].score != candidates[right].score {
			return candidates[left].score < candidates[right].score
		}
		if candidates[left].name != candidates[right].name {
			return candidates[left].name < candidates[right].name
		}
		return candidates[left].ip < candidates[right].ip
	})
	if len(candidates) == 0 {
		return ""
	}
	// 只有虚拟交换机/容器/VPN 私网时不发布 LAN 配对地址。该地址通常只能被本机
	// 虚拟机访问，发给手机或平板只会产生一个看似合理、实际不可达的二维码。
	if candidates[0].virtual {
		return ""
	}
	return candidates[0].ip
}

// SetLANAccess 只修改 network.allow_lan，保留 token、项目、动作和未来新增字段。
// 配置采用 0600 临时文件 + rename 原子提交，避免切换网络时损坏现有配置。
func SetLANAccess(configPath string, enabled bool) (bool, error) {
	cfgPath, err := resolveConfigPath(configPath)
	if err != nil {
		return false, err
	}
	info, err := os.Lstat(cfgPath)
	if err != nil {
		return false, fmt.Errorf("读取配置文件状态失败：%w", err)
	}
	if !info.Mode().IsRegular() {
		return false, fmt.Errorf("配置文件必须是 regular file，不能是目录或符号链接")
	}

	cfg, err := config.LoadForDoctor(cfgPath)
	if err != nil {
		return false, err
	}
	originalListen := cfg.Listen
	cfg.Network.AllowLAN = enabled
	if !enabled {
		host, port := splitListen(cfg.Listen)
		ip := net.ParseIP(strings.Trim(host, "[]"))
		if ip != nil && ip.IsUnspecified() {
			if port == "" {
				port = defaultAgentDPort
			}
			cfg.Listen = net.JoinHostPort("127.0.0.1", port)
		}
	}
	if err := cfg.Validate(); err != nil {
		return false, fmt.Errorf("新的网络配置无效：%w", err)
	}

	original, err := os.ReadFile(cfgPath)
	if err != nil {
		return false, fmt.Errorf("读取配置文件失败：%w", err)
	}
	document := map[string]json.RawMessage{}
	if err := json.Unmarshal(original, &document); err != nil {
		return false, fmt.Errorf("解析配置文件失败：%w", err)
	}
	if document == nil {
		return false, fmt.Errorf("配置文件必须是 JSON object")
	}

	networkDocument := map[string]json.RawMessage{}
	if rawNetwork, ok := document["network"]; ok && string(rawNetwork) != "null" {
		if err := json.Unmarshal(rawNetwork, &networkDocument); err != nil {
			return false, fmt.Errorf("解析 network 配置失败：%w", err)
		}
	}
	current := false
	if rawAllowLAN, ok := networkDocument["allow_lan"]; ok {
		if err := json.Unmarshal(rawAllowLAN, &current); err != nil {
			return false, fmt.Errorf("解析 network.allow_lan 失败：%w", err)
		}
	}
	updatedListen := cfg.Listen
	if current == enabled && updatedListen == originalListen {
		return false, nil
	}

	encodedEnabled, err := json.Marshal(enabled)
	if err != nil {
		return false, fmt.Errorf("编码 network.allow_lan 失败：%w", err)
	}
	networkDocument["allow_lan"] = encodedEnabled
	encodedNetwork, err := json.Marshal(networkDocument)
	if err != nil {
		return false, fmt.Errorf("编码 network 配置失败：%w", err)
	}
	document["network"] = encodedNetwork
	if updatedListen != originalListen {
		encodedListen, err := json.Marshal(updatedListen)
		if err != nil {
			return false, fmt.Errorf("编码 listen 配置失败：%w", err)
		}
		document["listen"] = encodedListen
	}
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return false, fmt.Errorf("编码配置文件失败：%w", err)
	}
	if err := writePrivateFileAtomicallyCAS(cfgPath, original, append(updated, '\n')); err != nil {
		return false, fmt.Errorf("原子更新配置文件失败：%w", err)
	}
	return true, nil
}
