package tunnel

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"tailscale.com/tstest/integration"
)

const experimentToken = "tailcat-integration-token"

func TestTailcatCarriesAgentdHTTPWebSocketAndBinaryTraffic(t *testing.T) {
	backend := newAgentdFixture(t)
	backendURL, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}

	derpMap := integration.RunDERPAndSTUN(t, t.Logf, "127.0.0.1")
	temporary := t.TempDir()
	clientIdentityPath := filepath.Join(temporary, "client.json")
	clientPrivate, err := LoadOrCreateClientIdentity(clientIdentityPath)
	if err != nil {
		t.Fatal(err)
	}
	hostConfig := HostConfig{
		TargetAddr:       backendURL.Host,
		RemotePort:       8787,
		IdentityPath:     filepath.Join(temporary, "host.json"),
		AddressPath:      filepath.Join(temporary, "address"),
		AllowedClientKey: clientPrivate.Public().String(),
		Region:           derpMap.Regions[1],
	}

	host, err := StartHost(hostConfig)
	if err != nil {
		t.Fatal(err)
	}
	address := host.Address()
	forwarder := startTestForwarder(t, address, clientIdentityPath)
	assertAgentdTraffic(t, forwarder.Endpoint())
	if err := forwarder.Close(); err != nil {
		t.Fatal(err)
	}
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}

	// 服务端身份同时保存私钥和 DERP 区域，重启后连接地址必须保持不变。
	restartedHost, err := StartHost(hostConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer restartedHost.Close()
	if restartedHost.Address() != address {
		t.Fatalf("服务端重启后地址变化：got %q, want %q", restartedHost.Address(), address)
	}
	restartedForwarder := startTestForwarder(t, address, clientIdentityPath)
	defer restartedForwarder.Close()
	assertAuthorizedRequest(t, restartedForwarder.Endpoint())

	for _, path := range []string{hostConfig.IdentityPath, hostConfig.AddressPath, clientIdentityPath} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if got := info.Mode().Perm(); got != 0o600 {
			t.Fatalf("%s 权限为 %o，预期 600", path, got)
		}
	}
}

func startTestForwarder(t *testing.T, address, identityPath string) *Forwarder {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	forwarder, err := StartForwarder(ctx, ForwarderConfig{
		Address:      address,
		RemotePort:   8787,
		ListenAddr:   "127.0.0.1:0",
		IdentityPath: identityPath,
	})
	if err != nil {
		t.Fatal(err)
	}
	return forwarder
}

func assertAgentdTraffic(t *testing.T, endpoint string) {
	t.Helper()

	response, err := http.Get(endpoint + "/api/readyz")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("未认证请求状态为 %d，预期 401", response.StatusCode)
	}
	assertAuthorizedRequest(t, endpoint)

	payload := bytes.Repeat([]byte("mimi-tailcat-binary\x00"), 64*1024)
	wantDigest := sha256.Sum256(payload)
	request, err := http.NewRequest(http.MethodPost, endpoint+"/api/upload", bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+experimentToken)
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.TrimSpace(string(body)), hex.EncodeToString(wantDigest[:]); got != want {
		t.Fatalf("二进制摘要为 %q，预期 %q", got, want)
	}

	webSocketURL := "ws" + strings.TrimPrefix(endpoint, "http") + "/api/app-server/ws"
	header := http.Header{"Authorization": []string{"Bearer " + experimentToken}}
	connection, response, err := websocket.DefaultDialer.Dial(webSocketURL, header)
	if response != nil && response.Body != nil {
		response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	wantMessage := []byte(`{"method":"thread/list","id":7}`)
	if err := connection.WriteMessage(websocket.BinaryMessage, wantMessage); err != nil {
		t.Fatal(err)
	}
	messageType, gotMessage, err := connection.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if messageType != websocket.BinaryMessage || !bytes.Equal(gotMessage, wantMessage) {
		t.Fatalf("WebSocket 回显类型/内容不一致：type=%d body=%q", messageType, gotMessage)
	}
}

func assertAuthorizedRequest(t *testing.T, endpoint string) {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, endpoint+"/api/readyz", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+experimentToken)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("认证请求状态为 %d，预期 200", response.StatusCode)
	}
}

func newAgentdFixture(t *testing.T) *httptest.Server {
	t.Helper()
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	mux := http.NewServeMux()
	authorized := func(next http.HandlerFunc) http.HandlerFunc {
		return func(response http.ResponseWriter, request *http.Request) {
			if request.Header.Get("Authorization") != "Bearer "+experimentToken {
				http.Error(response, "unauthorized", http.StatusUnauthorized)
				return
			}
			next(response, request)
		}
	}
	mux.HandleFunc("/api/readyz", authorized(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusOK)
	}))
	mux.HandleFunc("/api/upload", authorized(func(response http.ResponseWriter, request *http.Request) {
		digest := sha256.New()
		if _, err := io.Copy(digest, request.Body); err != nil {
			http.Error(response, err.Error(), http.StatusInternalServerError)
			return
		}
		fmt.Fprintln(response, hex.EncodeToString(digest.Sum(nil)))
	}))
	mux.HandleFunc("/api/app-server/ws", authorized(func(response http.ResponseWriter, request *http.Request) {
		connection, err := upgrader.Upgrade(response, request, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		messageType, message, err := connection.ReadMessage()
		if err == nil {
			_ = connection.WriteMessage(messageType, message)
		}
	}))
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}
