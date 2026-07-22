package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestInspectTailscaleNetworkPathClassifiesActivePeer(t *testing.T) {
	tests := []struct {
		name       string
		peerFields string
		wantKind   tailscaleNetworkPathKind
		wantRegion string
	}{
		{
			name:       "direct takes precedence over home DERP",
			peerFields: `"CurAddr":"203.0.113.10:41641","Relay":"hkg"`,
			wantKind:   tailscaleNetworkPathDirect,
		},
		{
			name:       "peer relay",
			peerFields: `"PeerRelay":"100.88.0.9:40000:vni:7","Relay":"hkg"`,
			wantKind:   tailscaleNetworkPathPeerRelay,
		},
		{
			name:       "DERP relay",
			peerFields: `"Relay":"HKG"`,
			wantKind:   tailscaleNetworkPathDERP,
			wantRegion: "hkg",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			status := `{"Peer":{"nodekey:test":{"TailscaleIPs":["100.101.102.103"],"Active":true,` + test.peerFields + `}}}`
			response := inspectTailscaleNetworkPath(context.Background(), "100.101.102.103", func(context.Context) ([]byte, error) {
				return []byte(status), nil
			})
			if response.Kind != test.wantKind || response.RelayRegion != test.wantRegion {
				t.Fatalf("路径判断错误：got=%+v want_kind=%s want_region=%q", response, test.wantKind, test.wantRegion)
			}
		})
	}
}

func TestInspectTailscaleNetworkPathDoesNotUseStaleIdlePeer(t *testing.T) {
	status := `{"Peer":{"nodekey:test":{"TailscaleIPs":["100.101.102.103"],"Active":false,"CurAddr":"203.0.113.10:41641"}}}`
	response := inspectTailscaleNetworkPath(context.Background(), "100.101.102.103", func(context.Context) ([]byte, error) {
		return []byte(status), nil
	})
	if response.Kind != tailscaleNetworkPathUnknown {
		t.Fatalf("空闲 peer 的旧地址不能作为本次测速路径：%+v", response)
	}
}

func TestInspectTailscaleNetworkPathSkipsCLIForNonTailscaleClient(t *testing.T) {
	called := false
	response := inspectTailscaleNetworkPath(context.Background(), "192.168.1.20", func(context.Context) ([]byte, error) {
		called = true
		return nil, nil
	})
	if called {
		t.Fatal("局域网客户端不应启动 tailscale CLI")
	}
	if response.Kind != tailscaleNetworkPathNotTailscale {
		t.Fatalf("局域网客户端应明确标记为非 Tailscale：%+v", response)
	}
}

func TestInspectTailscaleNetworkPathDegradesWhenStatusUnavailable(t *testing.T) {
	response := inspectTailscaleNetworkPath(context.Background(), "100.101.102.103", func(context.Context) ([]byte, error) {
		return nil, errors.New("tailscale unavailable")
	})
	if response.Kind != tailscaleNetworkPathUnavailable {
		t.Fatalf("CLI 失败不应让测速接口失败：%+v", response)
	}
}

func TestTailscaleNetworkPathHandlerUsesRequestRemoteAddress(t *testing.T) {
	router := &Router{
		tailscalePathLookup: func(_ context.Context, remoteHost string) tailscaleNetworkPathResponse {
			if remoteHost != "100.101.102.103" {
				t.Fatalf("应使用 HTTP 请求来源匹配 Tailscale peer，got=%q", remoteHost)
			}
			return tailscaleNetworkPathResponse{Kind: tailscaleNetworkPathPeerRelay}
		},
	}
	req := httptest.NewRequest(http.MethodGet, "/api/diagnostics/tailscale-path", nil)
	req.RemoteAddr = "100.101.102.103:54321"
	rec := httptest.NewRecorder()

	router.tailscaleNetworkPathHandler(rec, req)

	var response tailscaleNetworkPathResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("响应不是合法 JSON：%v", err)
	}
	if rec.Code != http.StatusOK || response.Kind != tailscaleNetworkPathPeerRelay {
		t.Fatalf("响应异常：status=%d body=%s", rec.Code, rec.Body.String())
	}
}
