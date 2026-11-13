// Package systemproxy 让 agentd 启动的 Codex 与 Claude 适配器沿用 Windows 系统代理。
//
// 这些子进程只认 HTTPS_PROXY 等环境变量，不读取 WinINET 系统代理；而代理软件常在 agentd
// 之后才启动，也会随时开关系统代理，启动时把地址写进环境就会长期失效。agentd 因此在回环
// 地址上开一个带随机凭据的中转，子进程固定指向它；每个连接按当时的系统代理设置转发或直连。
package systemproxy

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Resolver 返回访问 hostport 应使用的上游代理；nil 表示直连。scheme 是目标协议：
// CONNECT 隧道按 https 处理，绝对地址的普通请求按 http 处理。
type Resolver func(ctx context.Context, scheme string, hostport string) (*url.URL, error)

const (
	relayUser          = "mimi"
	upstreamDialBudget = 15 * time.Second
)

// Relay 只监听回环地址，只接受带本进程随机凭据的请求。
type Relay struct {
	listener net.Listener
	server   *http.Server
	resolve  Resolver
	password string
	dialer   net.Dialer
	forward  *httputil.ReverseProxy

	resolveErrorOnce sync.Once
}

func StartRelay(resolve Resolver) (*Relay, error) {
	if resolve == nil {
		return nil, errors.New("系统代理中转缺少解析器")
	}
	secret := make([]byte, 16)
	if _, err := rand.Read(secret); err != nil {
		return nil, fmt.Errorf("生成系统代理中转凭据：%w", err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("监听系统代理中转：%w", err)
	}
	relay := &Relay{
		listener: listener,
		resolve:  resolve,
		password: hex.EncodeToString(secret),
		dialer:   net.Dialer{Timeout: upstreamDialBudget, KeepAlive: 30 * time.Second},
	}
	transport := &http.Transport{
		Proxy: func(req *http.Request) (*url.URL, error) {
			return relay.upstream(req.Context(), "http", canonicalHostPort(req.URL))
		},
		DialContext:           relay.dialer.DialContext,
		ForceAttemptHTTP2:     false,
		MaxIdleConns:          16,
		IdleConnTimeout:       90 * time.Second,
		ResponseHeaderTimeout: 0,
	}
	relay.forward = &httputil.ReverseProxy{
		Rewrite: func(request *httputil.ProxyRequest) {
			request.Out.URL = request.In.URL
			request.Out.Host = request.In.Host
		},
		Transport:     transport,
		FlushInterval: -1,
		ErrorLog:      log.New(io.Discard, "", 0),
	}
	relay.server = &http.Server{Handler: http.HandlerFunc(relay.serveHTTP), ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = relay.server.Serve(listener) }()
	return relay, nil
}

// URL 是交给子进程的代理地址，含本进程的随机凭据。
func (r *Relay) URL() string {
	return (&url.URL{Scheme: "http", User: url.UserPassword(relayUser, r.password), Host: r.listener.Addr().String()}).String()
}

func (r *Relay) Close() error {
	return r.server.Close()
}

func (r *Relay) serveHTTP(w http.ResponseWriter, req *http.Request) {
	if !r.authorized(req.Header.Get("Proxy-Authorization")) {
		w.Header().Set("Proxy-Authenticate", `Basic realm="mimi-remote"`)
		http.Error(w, "proxy authentication required", http.StatusProxyAuthRequired)
		return
	}
	if req.Method == http.MethodConnect {
		r.serveConnect(w, req)
		return
	}
	// 只转发代理形式（绝对地址）的普通 HTTP 请求，拒绝把中转当成普通网站访问。
	if !req.URL.IsAbs() || !strings.EqualFold(req.URL.Scheme, "http") {
		http.Error(w, "only proxy requests are supported", http.StatusBadRequest)
		return
	}
	r.forward.ServeHTTP(w, req)
}

func (r *Relay) authorized(header string) bool {
	encoded, ok := strings.CutPrefix(strings.TrimSpace(header), "Basic ")
	if !ok {
		return false
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return false
	}
	user, password, ok := strings.Cut(string(decoded), ":")
	return ok && user == relayUser && subtle.ConstantTimeCompare([]byte(password), []byte(r.password)) == 1
}

func (r *Relay) serveConnect(w http.ResponseWriter, req *http.Request) {
	target := req.Host
	if _, port, err := net.SplitHostPort(target); err != nil || port == "" {
		http.Error(w, "invalid CONNECT target", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), upstreamDialBudget)
	upstream, err := r.dialTarget(ctx, target)
	cancel()
	if err != nil {
		http.Error(w, "upstream connection failed", http.StatusBadGateway)
		return
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		_ = upstream.Close()
		http.Error(w, "connection hijacking unsupported", http.StatusInternalServerError)
		return
	}
	client, buffered, err := hijacker.Hijack()
	if err != nil {
		_ = upstream.Close()
		return
	}
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		_ = client.Close()
		_ = upstream.Close()
		return
	}
	// 客户端可能不等 200 就发出 TLS 握手，已读入缓冲区的字节要先转给上游。
	if pending := buffered.Reader.Buffered(); pending > 0 {
		data, _ := buffered.Reader.Peek(pending)
		if _, err := upstream.Write(data); err != nil {
			_ = client.Close()
			_ = upstream.Close()
			return
		}
	}
	pipe(client, upstream)
}

func (r *Relay) dialTarget(ctx context.Context, target string) (net.Conn, error) {
	proxyURL, err := r.upstream(ctx, "https", target)
	if err != nil {
		return nil, err
	}
	if proxyURL == nil {
		return r.dialer.DialContext(ctx, "tcp", target)
	}
	switch strings.ToLower(proxyURL.Scheme) {
	case "http":
		return dialHTTPConnect(ctx, &r.dialer, proxyURL, target)
	case "socks", "socks5", "socks5h":
		return dialSOCKS5(ctx, &r.dialer, proxyURL.Host, target)
	default:
		return nil, fmt.Errorf("不支持的系统代理协议 %q", proxyURL.Scheme)
	}
}

// upstream 读取当时的系统代理。读取失败时直连，与系统代理关闭时的行为一致；
// 代理地址属于用户本机配置，日志只记录一次失败原因，不记录地址。
func (r *Relay) upstream(ctx context.Context, scheme string, hostport string) (*url.URL, error) {
	proxyURL, err := r.resolve(ctx, scheme, hostport)
	if err != nil {
		r.resolveErrorOnce.Do(func() { log.Printf("agentd system proxy: 读取 Windows 系统代理失败，改为直连：%v", err) })
		return nil, nil
	}
	return proxyURL, nil
}

func dialHTTPConnect(ctx context.Context, dialer *net.Dialer, proxyURL *url.URL, target string) (net.Conn, error) {
	conn, err := dialer.DialContext(ctx, "tcp", proxyURL.Host)
	if err != nil {
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	request := &http.Request{
		Method: http.MethodConnect,
		URL:    &url.URL{Opaque: target},
		Host:   target,
		Header: make(http.Header),
	}
	if proxyURL.User != nil {
		password, _ := proxyURL.User.Password()
		credentials := base64.StdEncoding.EncodeToString([]byte(proxyURL.User.Username() + ":" + password))
		request.Header.Set("Proxy-Authorization", "Basic "+credentials)
	}
	if err := request.Write(conn); err != nil {
		_ = conn.Close()
		return nil, err
	}
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, request)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK {
		_ = conn.Close()
		return nil, fmt.Errorf("系统代理拒绝 CONNECT：HTTP %d", response.StatusCode)
	}
	_ = conn.SetDeadline(time.Time{})
	if reader.Buffered() > 0 {
		return &bufferedConn{Conn: conn, reader: reader}, nil
	}
	return conn, nil
}

func dialSOCKS5(ctx context.Context, dialer *net.Dialer, proxyAddress string, target string) (net.Conn, error) {
	host, rawPort, err := net.SplitHostPort(target)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(rawPort)
	if err != nil || port < 1 || port > 65535 || len(host) > 255 {
		return nil, fmt.Errorf("无效的 SOCKS 目标 %q", target)
	}
	conn, err := dialer.DialContext(ctx, "tcp", proxyAddress)
	if err != nil {
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	fail := func(err error) (net.Conn, error) {
		_ = conn.Close()
		return nil, err
	}
	if _, err := conn.Write([]byte{5, 1, 0}); err != nil {
		return fail(err)
	}
	greeting := make([]byte, 2)
	if _, err := io.ReadFull(conn, greeting); err != nil {
		return fail(err)
	}
	if greeting[0] != 5 || greeting[1] != 0 {
		return fail(errors.New("SOCKS 代理要求不支持的认证方式"))
	}
	request := append([]byte{5, 1, 0, 3, byte(len(host))}, host...)
	request = append(request, byte(port>>8), byte(port))
	if _, err := conn.Write(request); err != nil {
		return fail(err)
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(conn, header); err != nil {
		return fail(err)
	}
	if header[0] != 5 || header[1] != 0 {
		return fail(fmt.Errorf("SOCKS 代理拒绝连接：%d", header[1]))
	}
	var skip int
	switch header[3] {
	case 1:
		skip = net.IPv4len + 2
	case 4:
		skip = net.IPv6len + 2
	case 3:
		length := make([]byte, 1)
		if _, err := io.ReadFull(conn, length); err != nil {
			return fail(err)
		}
		skip = int(length[0]) + 2
	default:
		return fail(errors.New("SOCKS 代理返回未知地址类型"))
	}
	if _, err := io.ReadFull(conn, make([]byte, skip)); err != nil {
		return fail(err)
	}
	_ = conn.SetDeadline(time.Time{})
	return conn, nil
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.reader.Read(p)
}

func (c *bufferedConn) CloseWrite() error {
	if closer, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return closer.CloseWrite()
	}
	return c.Conn.Close()
}

// pipe 双向转发到两侧都结束。一侧读到 EOF 时只半关闭另一侧的写方向，保留仍在
// 进行的响应；出现读写错误时立即关闭两侧，避免另一方向永远挂起。
func pipe(client net.Conn, upstream net.Conn) {
	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			_ = client.Close()
			_ = upstream.Close()
		})
	}
	done := make(chan struct{}, 2)
	relay := func(dst net.Conn, src net.Conn) {
		_, err := io.Copy(dst, src)
		if err != nil {
			closeBoth()
		} else if closer, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		} else {
			closeBoth()
		}
		done <- struct{}{}
	}
	go relay(upstream, client)
	go relay(client, upstream)
	<-done
	<-done
	closeBoth()
}

func canonicalHostPort(target *url.URL) string {
	if target == nil {
		return ""
	}
	if target.Port() != "" {
		return target.Host
	}
	port := "80"
	if strings.EqualFold(target.Scheme, "https") {
		port = "443"
	}
	return net.JoinHostPort(target.Hostname(), port)
}
