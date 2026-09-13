package tunnel

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"tailscale.com/tstest/integration"
)

func TestForwarderRecoversAfterHostRestartWithoutChangingEndpoint(t *testing.T) {
	t.Setenv("TS_DEBUG_ALWAYS_USE_DERP", "1")
	for _, trigger := range []string{"http", "disco-ping", "established-websocket"} {
		t.Run(trigger, func(t *testing.T) {
			backend := newAgentdFixture(t)
			target, err := url.Parse(backend.URL)
			if err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			identityPath := filepath.Join(root, "client.json")
			identity, err := LoadOrCreateClientIdentity(identityPath)
			if err != nil {
				t.Fatal(err)
			}
			region := integration.RunDERPAndSTUN(t, t.Logf, "127.0.0.1").Regions[1]
			config := HostConfig{
				TargetAddr: target.Host, RemotePort: 8787,
				IdentityPath: filepath.Join(root, "host.json"), AddressPath: filepath.Join(root, "address"),
				AllowedClientKeys: []string{identity.Public().String()}, Region: region,
			}
			host, err := StartHost(config)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { host.Close() }()
			address := host.Address()
			forwarder := startTestForwarder(t, address, identityPath)
			defer forwarder.Close()
			endpoint := forwarder.Endpoint()
			transport := &http.Transport{DisableKeepAlives: true}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 8 * time.Second}
			checkHTTP := func() error {
				req, err := http.NewRequest(http.MethodGet, endpoint+"/api/readyz", nil)
				if err != nil {
					return err
				}
				req.Header.Set("Authorization", "Bearer "+experimentToken)
				response, err := client.Do(req)
				if err != nil {
					return err
				}
				defer response.Body.Close()
				if response.StatusCode != http.StatusOK {
					return fmt.Errorf("unexpected status %d", response.StatusCode)
				}
				_, err = io.Copy(io.Discard, response.Body)
				return err
			}
			if err := checkHTTP(); err != nil {
				t.Fatal(err)
			}
			// 连续重启两次，确认恢复不是只对首次握手生效。Forwarder 与本地端点始终保留。
			for restart := 0; restart < 2; restart++ {
				var established *websocket.Conn
				if trigger == "established-websocket" {
					dialer := websocket.Dialer{HandshakeTimeout: 5 * time.Second}
					established, _, err = dialer.Dial("ws"+strings.TrimPrefix(endpoint, "http")+"/api/app-server/ws", http.Header{"Authorization": []string{"Bearer " + experimentToken}})
					if err != nil {
						t.Fatal(err)
					}
					defer established.Close()
				}
				if err := host.Close(); err != nil {
					t.Fatal(err)
				}
				host, err = StartHost(config)
				if err != nil {
					t.Fatal(err)
				}
				if host.Address() != address {
					t.Fatal("重启改变了服务端地址")
				}
				started := time.Now()
				if established != nil {
					// 不新建请求、不手动测速；旧 WebSocket 必须退出等待，供 App 自动重连。
					established.SetReadDeadline(time.Now().Add(20 * time.Second))
					_, _, readErr := established.ReadMessage()
					established.Close()
					if readErr == nil {
						t.Fatal("服务重启后旧 WebSocket 没有断开")
					}
					if timeout, ok := readErr.(net.Error); ok && timeout.Timeout() {
						t.Fatal("旧 WebSocket 一直挂起，自动探测未释放连接")
					}
				} else if trigger == "disco-ping" {
					ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
					result, pingErr := forwarder.DiscoPing(ctx)
					cancel()
					if pingErr != nil {
						t.Fatal(pingErr)
					}
					if result.Path == "unknown" {
						t.Fatal("恢复后仍无法诊断路径")
					}
				} else {
					// 多条新连接同时失败，必须共用恢复，不能相互抢占同身份 DERP 连接。
					failures := make(chan error, 4)
					for i := 0; i < 4; i++ {
						go func() { failures <- checkHTTP() }()
					}
					for i := 0; i < 4; i++ {
						if err := <-failures; err != nil {
							t.Fatal(err)
						}
					}
				}
				if err := checkHTTP(); err != nil {
					t.Fatal(err)
				}
				if forwarder.Endpoint() != endpoint {
					t.Fatal("恢复改变了 App 使用的本地端点")
				}
				t.Logf("restart=%d trigger=%s recovered=%s", restart+1, trigger, time.Since(started).Round(time.Millisecond))
				dialer := websocket.Dialer{HandshakeTimeout: 5 * time.Second}
				ws, response, err := dialer.Dial("ws"+strings.TrimPrefix(endpoint, "http")+"/api/app-server/ws", http.Header{"Authorization": []string{"Bearer " + experimentToken}})
				if response != nil && response.Body != nil {
					response.Body.Close()
				}
				if err != nil {
					t.Fatal(err)
				}
				ws.SetReadDeadline(time.Now().Add(5 * time.Second))
				payload := []byte(`{"method":"thread/list","id":7}`)
				if err := ws.WriteMessage(websocket.TextMessage, payload); err != nil {
					ws.Close()
					t.Fatal(err)
				}
				_, got, err := ws.ReadMessage()
				ws.Close()
				if err != nil {
					t.Fatal(err)
				}
				if string(got) != string(payload) {
					t.Fatal("恢复后 WebSocket 内容不一致")
				}
			}
		})
	}
}
