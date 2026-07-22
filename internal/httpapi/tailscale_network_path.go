package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"time"
)

const tailscaleStatusOutputLimit = 2 * 1024 * 1024

var (
	tailscaleIPv4Prefix = netip.MustParsePrefix("100.64.0.0/10")
	tailscaleIPv6Prefix = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

type tailscaleNetworkPathKind string

const (
	tailscaleNetworkPathDirect       tailscaleNetworkPathKind = "direct"
	tailscaleNetworkPathPeerRelay    tailscaleNetworkPathKind = "peer_relay"
	tailscaleNetworkPathDERP         tailscaleNetworkPathKind = "derp"
	tailscaleNetworkPathNotTailscale tailscaleNetworkPathKind = "not_tailscale"
	tailscaleNetworkPathUnknown      tailscaleNetworkPathKind = "unknown"
	tailscaleNetworkPathUnavailable  tailscaleNetworkPathKind = "unavailable"
)

type tailscaleNetworkPathResponse struct {
	Kind        tailscaleNetworkPathKind `json:"kind"`
	ObservedAt  time.Time                `json:"observed_at"`
	RelayRegion string                   `json:"relay_region,omitempty"`
}

type tailscaleNetworkPathLookup func(context.Context, string) tailscaleNetworkPathResponse
type tailscaleStatusCommand func(context.Context) ([]byte, error)

type tailscaleStatusSnapshot struct {
	Peer map[string]tailscalePeerStatus `json:"Peer"`
}

type tailscalePeerStatus struct {
	TailscaleIPs []string `json:"TailscaleIPs"`
	CurAddr      string   `json:"CurAddr"`
	Relay        string   `json:"Relay"`
	PeerRelay    string   `json:"PeerRelay"`
	Active       bool     `json:"Active"`
}

func (r *Router) tailscaleNetworkPathHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	lookup := r.tailscalePathLookup
	if lookup == nil {
		lookup = defaultTailscaleNetworkPathLookup
	}
	writeJSON(w, http.StatusOK, lookup(req.Context(), requestRemoteHost(req)))
}

func defaultTailscaleNetworkPathLookup(ctx context.Context, remoteHost string) tailscaleNetworkPathResponse {
	return inspectTailscaleNetworkPath(ctx, remoteHost, runTailscaleStatus)
}

func inspectTailscaleNetworkPath(ctx context.Context, remoteHost string, statusCommand tailscaleStatusCommand) tailscaleNetworkPathResponse {
	response := tailscaleNetworkPathResponse{
		Kind:       tailscaleNetworkPathUnknown,
		ObservedAt: time.Now().UTC(),
	}
	remoteIP, err := netip.ParseAddr(strings.TrimSpace(strings.Trim(remoteHost, "[]")))
	if err != nil {
		return response
	}
	remoteIP = remoteIP.Unmap()
	if !isTailscaleAddress(remoteIP) {
		response.Kind = tailscaleNetworkPathNotTailscale
		return response
	}

	runCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	output, err := statusCommand(runCtx)
	if err != nil || len(output) == 0 || len(output) > tailscaleStatusOutputLimit {
		response.Kind = tailscaleNetworkPathUnavailable
		return response
	}

	var status tailscaleStatusSnapshot
	if err := json.Unmarshal(output, &status); err != nil {
		response.Kind = tailscaleNetworkPathUnavailable
		return response
	}
	for _, peer := range status.Peer {
		if !tailscalePeerContainsIP(peer, remoteIP) {
			continue
		}
		// Tailscale 的文本状态也只为 active peer 展示连接类型；空闲 peer 的旧地址不能
		// 当作本次测速证据，否则网络切换后可能把过期直连误报为当前路径。
		if !peer.Active {
			return response
		}
		switch {
		case strings.TrimSpace(peer.CurAddr) != "":
			response.Kind = tailscaleNetworkPathDirect
		case strings.TrimSpace(peer.PeerRelay) != "":
			response.Kind = tailscaleNetworkPathPeerRelay
		case strings.TrimSpace(peer.Relay) != "":
			response.Kind = tailscaleNetworkPathDERP
			response.RelayRegion = strings.ToLower(strings.TrimSpace(peer.Relay))
		}
		return response
	}
	return response
}

func tailscalePeerContainsIP(peer tailscalePeerStatus, target netip.Addr) bool {
	for _, rawIP := range peer.TailscaleIPs {
		ip, err := netip.ParseAddr(strings.TrimSpace(rawIP))
		if err == nil && ip.Unmap() == target {
			return true
		}
	}
	return false
}

func isTailscaleAddress(ip netip.Addr) bool {
	return tailscaleIPv4Prefix.Contains(ip) || tailscaleIPv6Prefix.Contains(ip)
}

func runTailscaleStatus(ctx context.Context) ([]byte, error) {
	bin, err := findTailscaleCLI()
	if err != nil {
		return nil, err
	}
	return exec.CommandContext(ctx, bin, "status", "--json").Output()
}

func findTailscaleCLI() (string, error) {
	if bin, err := exec.LookPath("tailscale"); err == nil {
		return bin, nil
	}
	// macOS GUI 安装不一定把 CLI 放进后台服务的 PATH；固定应用路径是官方安装包的入口。
	const macOSAppCLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
	if info, err := os.Stat(macOSAppCLI); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
		return macOSAppCLI, nil
	}
	return exec.LookPath("tailscale")
}
