package systemproxy

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// startEchoServer 模拟 HTTPS 目标：CONNECT 隧道建好后原样回显字节。
func startEchoServer(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()
	return listener.Addr().String()
}

func startTestRelay(t *testing.T, resolve Resolver) *Relay {
	t.Helper()
	relay, err := StartRelay(resolve)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = relay.Close() })
	return relay
}

func direct(context.Context, string, string) (*url.URL, error) { return nil, nil }

// connectThrough 走 relay 建立 CONNECT 隧道，返回连接和状态码。
func connectThrough(t *testing.T, relayURL string, target string, credentials bool) (net.Conn, int) {
	t.Helper()
	parsed, _ := url.Parse(relayURL)
	conn, err := net.DialTimeout("tcp", parsed.Host, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	request := "CONNECT " + target + " HTTP/1.1\r\nHost: " + target + "\r\n"
	if credentials {
		password, _ := parsed.User.Password()
		request += "Proxy-Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte(parsed.User.Username()+":"+password)) + "\r\n"
	}
	if _, err := io.WriteString(conn, request+"\r\n"); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	return &bufferedConn{Conn: conn, reader: reader}, response.StatusCode
}

func assertEcho(t *testing.T, conn net.Conn) {
	t.Helper()
	defer conn.Close()
	if _, err := io.WriteString(conn, "ping"); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 4)
	if _, err := io.ReadFull(conn, reply); err != nil || string(reply) != "ping" {
		t.Fatalf("tunnel echo = %q, %v", reply, err)
	}
}

func TestRelayTunnelsDirectlyWhenSystemProxyIsOff(t *testing.T) {
	target := startEchoServer(t)
	relay := startTestRelay(t, direct)
	conn, status := connectThrough(t, relay.URL(), target, true)
	if status != http.StatusOK {
		t.Fatalf("CONNECT status = %d", status)
	}
	assertEcho(t, conn)
}

func TestRelayRejectsRequestsWithoutItsCredentials(t *testing.T) {
	relay := startTestRelay(t, direct)
	conn, status := connectThrough(t, relay.URL(), startEchoServer(t), false)
	conn.Close()
	if status != http.StatusProxyAuthRequired {
		t.Fatalf("unauthenticated CONNECT status = %d, want 407", status)
	}
	wrong, _ := url.Parse(relay.URL())
	wrong.User = url.UserPassword(relayUser, "wrong")
	conn, status = connectThrough(t, wrong.String(), startEchoServer(t), true)
	conn.Close()
	if status != http.StatusProxyAuthRequired {
		t.Fatalf("wrong-password CONNECT status = %d, want 407", status)
	}
}

// startUpstreamHTTPProxy 模拟代理软件：记录 CONNECT 目标后连到真实目标。
func startUpstreamHTTPProxy(t *testing.T) (string, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var targets []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodConnect {
			http.Error(w, "connect only", http.StatusMethodNotAllowed)
			return
		}
		mu.Lock()
		targets = append(targets, req.Host)
		mu.Unlock()
		upstream, err := net.Dial("tcp", req.Host)
		if err != nil {
			http.Error(w, "dial failed", http.StatusBadGateway)
			return
		}
		client, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			upstream.Close()
			return
		}
		_, _ = io.WriteString(client, "HTTP/1.1 200 OK\r\n\r\n")
		pipe(client, upstream)
	}))
	t.Cleanup(server.Close)
	return strings.TrimPrefix(server.URL, "http://"), func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), targets...)
	}
}

func TestRelayChainsThroughCurrentSystemProxy(t *testing.T) {
	target := startEchoServer(t)
	upstream, seen := startUpstreamHTTPProxy(t)
	var schemes []string
	relay := startTestRelay(t, func(_ context.Context, scheme string, hostport string) (*url.URL, error) {
		schemes = append(schemes, scheme)
		return &url.URL{Scheme: "http", Host: upstream}, nil
	})
	conn, status := connectThrough(t, relay.URL(), target, true)
	if status != http.StatusOK {
		t.Fatalf("CONNECT status = %d", status)
	}
	assertEcho(t, conn)
	if got := seen(); len(got) != 1 || got[0] != target {
		t.Fatalf("upstream proxy saw %v, want %s", got, target)
	}
	if len(schemes) != 1 || schemes[0] != "https" {
		t.Fatalf("CONNECT must resolve the proxy for https, got %v", schemes)
	}
}

func TestRelayReportsBadGatewayWhenUpstreamRefuses(t *testing.T) {
	refusing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "blocked", http.StatusForbidden)
	}))
	t.Cleanup(refusing.Close)
	relay := startTestRelay(t, func(context.Context, string, string) (*url.URL, error) {
		return url.Parse(refusing.URL)
	})
	conn, status := connectThrough(t, relay.URL(), startEchoServer(t), true)
	conn.Close()
	if status != http.StatusBadGateway {
		t.Fatalf("refused upstream CONNECT status = %d, want 502", status)
	}
}

func TestRelayFallsBackToDirectWhenSettingsCannotBeRead(t *testing.T) {
	relay := startTestRelay(t, func(context.Context, string, string) (*url.URL, error) {
		return nil, errors.New("registry unavailable")
	})
	conn, status := connectThrough(t, relay.URL(), startEchoServer(t), true)
	if status != http.StatusOK {
		t.Fatalf("CONNECT status = %d", status)
	}
	assertEcho(t, conn)
}

func TestRelayTunnelsThroughSOCKS5Proxy(t *testing.T) {
	target := startEchoServer(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	requested := make(chan string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		greeting := make([]byte, 3)
		if _, err := io.ReadFull(conn, greeting); err != nil {
			return
		}
		_, _ = conn.Write([]byte{5, 0})
		header := make([]byte, 5)
		if _, err := io.ReadFull(conn, header); err != nil {
			return
		}
		rest := make([]byte, int(header[4])+2)
		if _, err := io.ReadFull(conn, rest); err != nil {
			return
		}
		host := string(rest[:header[4]])
		port := int(rest[header[4]])<<8 | int(rest[header[4]+1])
		address := net.JoinHostPort(host, strconv.Itoa(port))
		requested <- address
		upstream, err := net.Dial("tcp", address)
		if err != nil {
			return
		}
		_, _ = conn.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 0})
		pipe(conn, upstream)
	}()
	relay := startTestRelay(t, func(context.Context, string, string) (*url.URL, error) {
		return &url.URL{Scheme: "socks5", Host: listener.Addr().String()}, nil
	})
	conn, status := connectThrough(t, relay.URL(), target, true)
	if status != http.StatusOK {
		t.Fatalf("CONNECT status = %d", status)
	}
	assertEcho(t, conn)
	select {
	case got := <-requested:
		if got != target {
			t.Fatalf("SOCKS proxy was asked for %s, want %s", got, target)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the tunnel did not go through the SOCKS proxy")
	}
}

func TestRelayForwardsPlainHTTPWithoutLeakingItsCredentials(t *testing.T) {
	var gotAuthorization string
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		gotAuthorization = req.Header.Get("Proxy-Authorization")
		_, _ = io.WriteString(w, "plain ok")
	}))
	t.Cleanup(origin.Close)
	relay := startTestRelay(t, direct)
	relayURL, _ := url.Parse(relay.URL())
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(relayURL)}, Timeout: 10 * time.Second}
	response, err := client.Get(origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK || string(body) != "plain ok" {
		t.Fatalf("plain HTTP through relay = %d %q", response.StatusCode, body)
	}
	if gotAuthorization != "" {
		t.Fatal("relay forwarded its own Proxy-Authorization to the origin")
	}
}

func TestRelayRejectsNonProxyRequests(t *testing.T) {
	relay := startTestRelay(t, direct)
	parsed, _ := url.Parse(relay.URL())
	request, _ := http.NewRequest(http.MethodGet, "http://"+parsed.Host+"/", nil)
	password, _ := parsed.User.Password()
	request.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(relayUser+":"+password)))
	response, err := http.DefaultTransport.RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("origin-form request status = %d, want 400", response.StatusCode)
	}
}
