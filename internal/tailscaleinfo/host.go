package tailscaleinfo

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

const statusOutputLimit = 2 * 1024 * 1024

var (
	tailscaleIPv4Prefix = netip.MustParsePrefix("100.64.0.0/10")
	tailscaleIPv6Prefix = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// Host 描述当前 agentd 所在的 Tailscale 设备。DNSName 是可变路由元数据，
// 不能替代 installation_id 成为客户端身份主键。
type Host struct {
	DNSName    string `json:"tailscale_dns_name,omitempty"`
	DeviceName string `json:"tailscale_device_name,omitempty"`
}

type statusSnapshot struct {
	Self struct {
		DNSName string `json:"DNSName"`
	} `json:"Self"`
}

type statusCommand func(context.Context) ([]byte, error)

// Discover 从本机 Tailscale CLI 读取 MagicDNS 名称。CLI 不可用、MagicDNS
// 未启用或输出异常时返回空值，让 LAN-only 和旧环境继续使用 IP Endpoint。
func Discover(ctx context.Context) Host {
	return inspect(ctx, runStatus)
}

func inspect(ctx context.Context, command statusCommand) Host {
	runCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	output, err := command(runCtx)
	if err != nil || len(output) == 0 || len(output) > statusOutputLimit {
		return Host{}
	}
	var status statusSnapshot
	if err := json.Unmarshal(output, &status); err != nil {
		return Host{}
	}
	dnsName := normalizeDNSName(status.Self.DNSName)
	if dnsName == "" {
		return Host{}
	}
	return Host{
		DNSName:    dnsName,
		DeviceName: strings.SplitN(dnsName, ".", 2)[0],
	}
}

func normalizeDNSName(raw string) string {
	value := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), ".")
	if len(value) == 0 || len(value) > 253 || !strings.Contains(value, ".") {
		return ""
	}
	for _, label := range strings.Split(value, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return ""
		}
		for _, char := range label {
			if (char >= 'a' && char <= 'z') ||
				(char >= '0' && char <= '9') ||
				char == '-' {
				continue
			}
			return ""
		}
	}
	return value
}

// Resolver 对空结果同样做短缓存，避免高频 /api/version 探测反复启动 CLI。
// TTL 到期后会重新读取，从而让设备改名后的 IP 回退连接可以刷新 DNS 路由。
type Resolver struct {
	mu        sync.Mutex
	ttl       time.Duration
	lookup    func(context.Context) Host
	cached    Host
	expiresAt time.Time
}

func NewResolver(ttl time.Duration) *Resolver {
	return newResolver(ttl, Discover)
}

func newResolver(ttl time.Duration, lookup func(context.Context) Host) *Resolver {
	if ttl <= 0 {
		ttl = time.Minute
	}
	return &Resolver{ttl: ttl, lookup: lookup}
}

func (r *Resolver) Lookup(ctx context.Context) Host {
	if r == nil {
		return Host{}
	}
	now := time.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	if now.Before(r.expiresAt) {
		return r.cached
	}
	r.cached = r.lookup(ctx)
	r.expiresAt = now.Add(r.ttl)
	return r.cached
}

func IsTailscaleEndpoint(endpoint string) bool {
	parsed, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil {
		return false
	}
	ip, err := netip.ParseAddr(strings.Trim(parsed.Hostname(), "[]"))
	return err == nil && IsTailscaleAddress(ip)
}

func IsTailscaleAddress(ip netip.Addr) bool {
	ip = ip.Unmap()
	return tailscaleIPv4Prefix.Contains(ip) || tailscaleIPv6Prefix.Contains(ip)
}

func runStatus(ctx context.Context) ([]byte, error) {
	cmd, err := CommandContext(ctx, "status", "--json")
	if err != nil {
		return nil, err
	}
	return cmd.Output()
}

// CommandContext 构造本机 Tailscale CLI 命令，并显式设置 TAILSCALE_BE_CLI=true。
// macOS App Store / GUI 版 Tailscale 在无交互终端（无 TERM/TERM_PROGRAM）的后台环境中
// 默认尝试启动 GUI 而不输出 CLI 结果；强制 CLI 模式可确保后台预检与状态查询稳定生效。
func CommandContext(ctx context.Context, args ...string) (*exec.Cmd, error) {
	bin, err := FindCLI()
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = commandEnv(os.Environ())
	return cmd, nil
}

func commandEnv(base []string) []string {
	env := make([]string, 0, len(base)+1)
	for _, entry := range base {
		key, _, found := strings.Cut(entry, "=")
		if found && strings.EqualFold(key, "TAILSCALE_BE_CLI") {
			continue
		}
		env = append(env, entry)
	}
	return append(env, "TAILSCALE_BE_CLI=true")
}

func FindCLI() (string, error) {
	home, _ := os.UserHomeDir()
	return findCLI(exec.LookPath, os.Stat, runtime.GOOS, home)
}

func findCLI(
	lookPath func(string) (string, error),
	stat func(string) (os.FileInfo, error),
	goos string,
	home string,
) (string, error) {
	if bin, err := lookPath("tailscale"); err == nil {
		return bin, nil
	}
	// macOS GUI / App Store 安装不一定把 CLI 放进后台服务的 PATH；固定应用路径是官方入口。
	if goos == "darwin" {
		candidates := []string{"/Applications/Tailscale.app/Contents/MacOS/Tailscale"}
		if strings.TrimSpace(home) != "" {
			candidates = append(candidates, filepath.Join(home, "Applications", "Tailscale.app", "Contents", "MacOS", "Tailscale"))
		}
		for _, candidate := range candidates {
			if info, err := stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
				return candidate, nil
			}
		}
	}
	return lookPath("tailscale")
}

// FirstIPv4 返回本机当前活跃的 Tailscale IPv4（100.64.0.0/10）。优先通过
// Tailscale CLI（带 TAILSCALE_BE_CLI=true）读取；若 App Store 沙盒未授予 CLI 凭据、
// CLI 不可用或未返回有效地址（且未明确报告已停止/未登录），则回退到活跃 Tailscale 隧道接口。
func FirstIPv4(ctx context.Context) string {
	return firstIPv4(ctx, runIPv4Command, interfaceIPv4)
}

func runIPv4Command(ctx context.Context) ([]byte, []byte, error) {
	runCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	cmd, err := CommandContext(runCtx, "ip", "-4")
	if err != nil {
		return nil, nil, err
	}
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return out, exitErr.Stderr, err
		}
		return out, nil, err
	}
	return out, nil, nil
}

func firstIPv4(
	ctx context.Context,
	runCLI func(context.Context) (stdout []byte, stderr []byte, err error),
	fallback func() string,
) string {
	stdout, stderr, err := runCLI(ctx)
	if err == nil {
		if ip := parseFirstTailscaleIPv4(string(stdout)); ip != "" {
			return ip
		}
	}
	if isExplicitlyStopped(string(stdout) + "\n" + string(stderr)) {
		return ""
	}
	if fallback != nil {
		return fallback()
	}
	return ""
}

func parseFirstTailscaleIPv4(raw string) string {
	for _, line := range strings.Split(raw, "\n") {
		addr, err := netip.ParseAddr(strings.TrimSpace(line))
		if err != nil {
			continue
		}
		addr = addr.Unmap()
		if addr.Is4() && tailscaleIPv4Prefix.Contains(addr) {
			return addr.String()
		}
	}
	return ""
}

func isExplicitlyStopped(output string) bool {
	lower := strings.ToLower(output)
	for _, marker := range []string{
		"tailscale is stopped",
		"logged out",
		"not logged in",
		"needslogin",
		"no state",
	} {
		if strings.Contains(lower, marker) {
			return true
		}
	}
	return false
}

type interfaceSnapshot struct {
	name  string
	flags net.Flags
	addrs []netip.Addr
}

type interfaceIPv4Candidate struct {
	tier int
	name string
	ip   string
}

func interfaceIPv4() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	snapshots := make([]interfaceSnapshot, 0, len(interfaces))
	for _, iface := range interfaces {
		rawAddrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		addrs := make([]netip.Addr, 0, len(rawAddrs))
		for _, raw := range rawAddrs {
			if addr, ok := addrFromNetAddr(raw); ok {
				addrs = append(addrs, addr)
			}
		}
		snapshots = append(snapshots, interfaceSnapshot{
			name:  iface.Name,
			flags: iface.Flags,
			addrs: addrs,
		})
	}
	return selectInterfaceIPv4(snapshots)
}

func addrFromNetAddr(raw net.Addr) (netip.Addr, bool) {
	var ip net.IP
	switch value := raw.(type) {
	case *net.IPNet:
		ip = value.IP
	case *net.IPAddr:
		ip = value.IP
	default:
		return netip.Addr{}, false
	}
	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return netip.Addr{}, false
	}
	return addr.Unmap(), true
}

func selectInterfaceIPv4(interfaces []interfaceSnapshot) string {
	candidates := []interfaceIPv4Candidate{}
	for _, iface := range interfaces {
		if iface.flags&net.FlagUp == 0 || iface.flags&net.FlagLoopback != 0 {
			continue
		}
		v4s := []netip.Addr{}
		hasTailscaleV6 := false
		for _, addr := range iface.addrs {
			addr = addr.Unmap()
			switch {
			case addr.Is4() && tailscaleIPv4Prefix.Contains(addr):
				v4s = append(v4s, addr)
			case addr.Is6() && tailscaleIPv6Prefix.Contains(addr):
				hasTailscaleV6 = true
			}
		}
		if len(v4s) == 0 {
			continue
		}
		lowerName := strings.ToLower(strings.TrimSpace(iface.name))
		tier := -1
		switch {
		case hasTailscaleV6 || strings.Contains(lowerName, "tailscale"):
			tier = 0
		case strings.HasPrefix(lowerName, "utun") || strings.HasPrefix(lowerName, "tun"):
			tier = 1
		default:
			// 普通物理网卡上的 100.64.0.0/10 可能是运营商 CGNAT，不能当成 Tailscale。
			continue
		}
		for _, ip := range v4s {
			candidates = append(candidates, interfaceIPv4Candidate{
				tier: tier,
				name: lowerName,
				ip:   ip.String(),
			})
		}
	}
	if len(candidates) == 0 {
		return ""
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].tier != candidates[j].tier {
			return candidates[i].tier < candidates[j].tier
		}
		if candidates[i].name != candidates[j].name {
			return candidates[i].name < candidates[j].name
		}
		return candidates[i].ip < candidates[j].ip
	})
	return candidates[0].ip
}
