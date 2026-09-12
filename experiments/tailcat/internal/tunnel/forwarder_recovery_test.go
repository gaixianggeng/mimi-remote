package tunnel

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/ipn/ipnstate"
)

type stubTunnelClient struct {
	ping    func(context.Context) error
	disco   func(context.Context) (*ipnstate.PingResult, error)
	dial    func(context.Context, uint16) (net.Conn, error)
	closeFn func() error
	closes  atomic.Int32
}

func (c *stubTunnelClient) Ping(ctx context.Context) (tailcat.PingResult, error) {
	if c.ping != nil {
		return tailcat.PingResult{}, c.ping(ctx)
	}
	return tailcat.PingResult{}, nil
}
func (c *stubTunnelClient) DiscoPing(ctx context.Context) (*ipnstate.PingResult, error) {
	if c.disco != nil {
		return c.disco(ctx)
	}
	return &ipnstate.PingResult{DERPRegionID: 1, DERPRegionCode: "test"}, nil
}
func (c *stubTunnelClient) DialTCPPort(ctx context.Context, port uint16) (net.Conn, error) {
	if c.dial != nil {
		return c.dial(ctx, port)
	}
	return nil, errors.New("test dial unavailable")
}
func (c *stubTunnelClient) Close() error {
	c.closes.Add(1)
	if c.closeFn != nil {
		return c.closeFn()
	}
	return nil
}

func newStubForwarder(t *testing.T, initial tunnelClient, factory func() tunnelClient) *Forwarder {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := newForwarder(listener, initial, factory)
	t.Cleanup(func() { f.Close() })
	go f.accept(8787)
	return f
}

func awaitSignal(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(5 * time.Second):
		t.Fatal("等待测试同步超时")
	}
}

func TestForwarderRecoveryIsSharedAndClosesOldBeforeCreatingNew(t *testing.T) {
	closeStarted, releaseClose := make(chan struct{}), make(chan struct{})
	oldClosed := atomic.Bool{}
	initial := &stubTunnelClient{closeFn: func() error {
		close(closeStarted)
		<-releaseClose
		oldClosed.Store(true)
		return nil
	}}
	next := &stubTunnelClient{}
	var created atomic.Int32
	f := newStubForwarder(t, initial, func() tunnelClient {
		if !oldClosed.Load() {
			t.Error("旧引擎未关闭就创建了相同身份的新引擎")
		}
		created.Add(1)
		return next
	})
	old := f.current
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			recovered, err := f.recoverClient(ctx, old)
			if err != nil {
				t.Error(err)
				return
			}
			if recovered.transport != next {
				t.Error("并发调用未得到相同的新引擎")
			}
		}()
	}
	awaitSignal(t, closeStarted)
	if created.Load() != 0 {
		t.Fatal("关闭旧引擎期间启动了新引擎")
	}
	close(releaseClose)
	wg.Wait()
	if created.Load() != 1 || initial.closes.Load() != 1 {
		t.Fatal("并发失败触发了重复重建")
	}
	// 迟到的失败属于旧一代，不能再次关闭已恢复的引擎。
	if _, err := f.recoverClient(ctx, old); err != nil {
		t.Fatal(err)
	}
	if created.Load() != 1 || next.closes.Load() != 0 {
		t.Fatal("旧请求错误破坏了已恢复的引擎")
	}
}

func TestForwarderRecoverySurvivesOneWaiterCancellation(t *testing.T) {
	pingStarted, releasePing := make(chan struct{}), make(chan struct{})
	next := &stubTunnelClient{ping: func(ctx context.Context) error {
		close(pingStarted)
		select {
		case <-releasePing:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}}
	f := newStubForwarder(t, &stubTunnelClient{}, func() tunnelClient { return next })
	old := f.current
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { _, err := f.recoverClient(ctx, old); result <- err }()
	awaitSignal(t, pingStarted)
	cancel()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("取消返回 %v", err)
	}
	close(releasePing)
	ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
	defer stop()
	recovered, err := f.clientForRequest(ctx)
	if err != nil || recovered.transport != next {
		t.Fatalf("其他请求不能继续共享恢复：%v", err)
	}
}

func TestForwarderCloseCancelsRecoveryAndReleasesLocalConnections(t *testing.T) {
	pingStarted := make(chan struct{})
	next := &stubTunnelClient{ping: func(ctx context.Context) error {
		close(pingStarted)
		<-ctx.Done()
		return ctx.Err()
	}}
	initial := &stubTunnelClient{}
	f := newStubForwarder(t, initial, func() tunnelClient { return next })
	local, err := net.Dial("tcp", f.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer local.Close()
	awaitSignal(t, pingStarted)
	closed := make(chan struct{})
	go func() { f.Close(); close(closed) }()
	awaitSignal(t, closed)
	if next.closes.Load() != 1 || initial.closes.Load() != 1 {
		t.Fatal("关闭后仍有引擎未释放")
	}
	local.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := local.Read(make([]byte, 1)); err == nil {
		t.Fatal("关闭后本地连接仍然开放")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("关闭未及时释放本地连接")
	}
	if _, err := f.clientForRequest(context.Background()); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("关闭后仍可获取引擎：%v", err)
	}
}

func TestForwarderRecoveryFailureIsBoundedAndLaterRequestCanRetry(t *testing.T) {
	offline := errors.New("server offline")
	failed := &stubTunnelClient{ping: func(ctx context.Context) error {
		if _, ok := ctx.Deadline(); !ok {
			t.Error("恢复没有超时边界")
		}
		return offline
	}}
	next := &stubTunnelClient{}
	var created atomic.Int32
	f := newStubForwarder(t, &stubTunnelClient{}, func() tunnelClient {
		if created.Add(1) == 1 {
			return failed
		}
		return next
	})
	if _, err := f.recoverClient(context.Background(), f.current); !errors.Is(err, offline) {
		t.Fatalf("恢复错误为 %v", err)
	}
	for i := 0; i < 10; i++ {
		if _, err := f.clientForRequest(context.Background()); !errors.Is(err, offline) {
			t.Fatalf("离线错误为 %v", err)
		}
	}
	if created.Load() != 1 || failed.closes.Load() != 1 {
		t.Fatal("离线请求产生重建风暴或泄漏引擎")
	}
	time.Sleep(forwarderRecoveryCooldown)
	recovered, err := f.clientForRequest(context.Background())
	if err != nil || recovered.transport != next || created.Load() != 2 {
		t.Fatalf("离线后无法再次恢复：%v", err)
	}
}

func TestForwarderRecoversBeforeSendingAndDoesNotTreatHTTPAuthAsTunnelFailure(t *testing.T) {
	var received atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received.Add(1)
		body, _ := io.ReadAll(r.Body)
		if string(body) != "one message" {
			t.Errorf("请求内容为 %q", body)
		}
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	next := &stubTunnelClient{dial: func(ctx context.Context, _ uint16) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "tcp", target.Host)
	}}
	var created atomic.Int32
	f := newStubForwarder(t, &stubTunnelClient{}, func() tunnelClient { created.Add(1); return next })
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Post(f.Endpoint(), "text/plain", strings.NewReader("one message"))
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized || received.Load() != 1 || created.Load() != 1 {
		t.Fatal("请求被重发或鉴权错误触发了重建")
	}
}

func TestForwarderNeverReplaysBytesAfterEstablishedStreamFails(t *testing.T) {
	readDone := make(chan []byte, 1)
	initial := &stubTunnelClient{dial: func(context.Context, uint16) (net.Conn, error) {
		proxy, remote := net.Pipe()
		go func() {
			defer remote.Close()
			body := make([]byte, len("one message"))
			_, err := io.ReadFull(remote, body)
			if err != nil {
				readDone <- nil
				return
			}
			readDone <- body
			// 远端已接收消息，但没有返回结果就断开。
		}()
		return proxy, nil
	}}
	var created atomic.Int32
	f := newStubForwarder(t, initial, func() tunnelClient { created.Add(1); return &stubTunnelClient{} })
	local, err := net.Dial("tcp", f.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer local.Close()
	local.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.WriteString(local, "one message"); err != nil {
		t.Fatal(err)
	}
	_, err = local.Read(make([]byte, 1))
	if !errors.Is(err, io.EOF) {
		t.Fatalf("连接断开结果为 %v", err)
	}
	if body := <-readDone; string(body) != "one message" {
		t.Fatal("远端未收到预期消息")
	}
	if created.Load() != 0 {
		t.Fatal("已转发业务字节后触发自动重建重放")
	}
}

func TestForwarderMonitorRecoversAnEstablishedSilentConnection(t *testing.T) {
	var probes atomic.Int32
	initial := &stubTunnelClient{disco: func(context.Context) (*ipnstate.PingResult, error) {
		probes.Add(1)
		return nil, errors.New("peer disappeared")
	}}
	next := &stubTunnelClient{}
	f := newStubForwarder(t, initial, func() tunnelClient { return next })
	// 无活动连接时不探测，也不为未使用的隧道重建引擎。
	f.checkActiveClient()
	if probes.Load() != 0 {
		t.Fatal("闲置隧道仍在发送探测")
	}
	local, remote := net.Pipe()
	defer remote.Close()
	f.mu.Lock()
	f.connections[local] = f.current
	f.mu.Unlock()
	f.checkActiveClient()
	remote.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := remote.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Fatalf("失效的旧连接未释放：%v", err)
	}
	recovered, err := f.clientForRequest(context.Background())
	if err != nil || recovered.transport != next || probes.Load() != 1 {
		t.Fatalf("存活探测未恢复连接：%v", err)
	}
}

func TestForwarderMonitorPreservesHealthySlowBusinessConnection(t *testing.T) {
	initial := &stubTunnelClient{}
	var created atomic.Int32
	f := newStubForwarder(t, initial, func() tunnelClient { created.Add(1); return &stubTunnelClient{} })
	local, remote := net.Pipe()
	defer remote.Close()
	f.mu.Lock()
	f.connections[local] = f.current
	f.mu.Unlock()
	// 业务流没有返回数据，但 DISCO 存活探测正常，不能关闭它或重发业务。
	f.checkActiveClient()
	if created.Load() != 0 || initial.closes.Load() != 0 {
		t.Fatal("业务静默导致健康连接被销毁")
	}
}

func TestForwarderRetriesSuccessfulDialInvalidatedByRecovery(t *testing.T) {
	for _, completed := range []bool{false, true} {
		name := "recovery_pending"
		if completed {
			name = "recovery_completed"
		}
		t.Run(name, func(t *testing.T) {
			var received, created, dials atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				received.Add(1)
				body, _ := io.ReadAll(r.Body)
				if string(body) != "one message" {
					t.Errorf("请求内容为 %q", body)
				}
				w.WriteHeader(http.StatusNoContent)
			}))
			defer server.Close()
			target, _ := url.Parse(server.URL)
			dialStarted, releaseDial := make(chan struct{}), make(chan struct{})
			pingStarted, releasePing := make(chan struct{}), make(chan struct{})
			staleClosed := make(chan struct{})
			initial := &stubTunnelClient{dial: func(ctx context.Context, _ uint16) (net.Conn, error) {
				close(dialStarted)
				select {
				case <-releaseDial:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				local, remote := net.Pipe()
				go func() {
					defer remote.Close()
					defer close(staleClosed)
					if n, _ := remote.Read(make([]byte, 1)); n != 0 {
						t.Error("失效连接收到了业务字节")
					}
				}()
				return local, nil
			}}
			next := &stubTunnelClient{
				ping: func(ctx context.Context) error {
					close(pingStarted)
					select {
					case <-releasePing:
						return nil
					case <-ctx.Done():
						return ctx.Err()
					}
				},
				dial: func(ctx context.Context, _ uint16) (net.Conn, error) {
					dials.Add(1)
					return (&net.Dialer{}).DialContext(ctx, "tcp", target.Host)
				},
			}
			f := newStubForwarder(t, initial, func() tunnelClient { created.Add(1); return next })
			endpoint, old := f.Endpoint(), f.current
			requestDone := make(chan error, 1)
			go func() {
				client := &http.Client{Timeout: 5 * time.Second}
				response, err := client.Post(endpoint, "text/plain", strings.NewReader("one message"))
				if err == nil {
					response.Body.Close()
					if response.StatusCode != http.StatusNoContent {
						err = errors.New("响应状态不正确")
					}
				}
				requestDone <- err
			}()
			awaitSignal(t, dialStarted)
			recoveryDone := make(chan error, 1)
			go func() { _, err := f.recoverClient(f.ctx, old); recoveryDone <- err }()
			awaitSignal(t, pingStarted)
			// 显式控制两种时序，避免依赖调度速度碰巧触发竞态。
			if completed {
				close(releasePing)
				if err := <-recoveryDone; err != nil {
					t.Fatal(err)
				}
			}
			close(releaseDial)
			awaitSignal(t, staleClosed)
			if !completed {
				close(releasePing)
				if err := <-recoveryDone; err != nil {
					t.Fatal(err)
				}
			}
			if err := <-requestDone; err != nil {
				t.Fatalf("尚未转发字节的请求被关闭：%v", err)
			}
			if received.Load() != 1 || created.Load() != 1 || dials.Load() != 1 || f.Endpoint() != endpoint {
				t.Fatal("请求未恰好转发一次、重复恢复或本地入口改变")
			}
		})
	}
}
