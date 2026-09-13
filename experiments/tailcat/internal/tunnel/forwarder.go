package tunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

type ForwarderConfig struct {
	Address      string
	RemotePort   uint16
	ListenAddr   string
	IdentityPath string
	PrivateKey   string
	EndpointPath string
}

type Forwarder struct {
	listener    net.Listener
	done        chan struct{}
	close       sync.Once
	closeErr    error
	ctx         context.Context
	cancel      context.CancelFunc
	mu          sync.Mutex
	current     *forwarderClient
	recovery    *forwarderRecovery
	newClient   func() tunnelClient
	connections map[net.Conn]*forwarderClient
}

func StartForwarder(ctx context.Context, config ForwarderConfig) (*Forwarder, error) {
	if config.RemotePort == 0 {
		return nil, errors.New("远端端口不能为 0")
	}
	if err := requireLoopbackAddress(config.ListenAddr); err != nil {
		return nil, fmt.Errorf("本地监听地址：%w", err)
	}
	if _, err := tailcat.ParseAddr(tailcat.Addr(config.Address)); err != nil {
		return nil, fmt.Errorf("解析 Tailcat 地址：%w", err)
	}
	privateKey, err := clientPrivateKey(config)
	if err != nil {
		return nil, err
	}
	newClient := func() tunnelClient {
		return &tailcat.Client{Server: tailcat.Addr(config.Address), Key: privateKey, Logf: logger.Discard}
	}
	client := newClient()
	pingContext, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if _, err := client.Ping(pingContext); err != nil {
		client.Close()
		return nil, fmt.Errorf("连接 Tailcat 服务端：%w", err)
	}

	listener, err := net.Listen("tcp", config.ListenAddr)
	if err != nil {
		client.Close()
		return nil, fmt.Errorf("监听本地端口：%w", err)
	}
	forwarder := newForwarder(listener, client, newClient)
	if config.EndpointPath != "" {
		if err := writePrivateFile(config.EndpointPath, []byte(forwarder.Endpoint()+"\n")); err != nil {
			forwarder.Close()
			return nil, fmt.Errorf("写入本地端点：%w", err)
		}
	}
	go forwarder.accept(config.RemotePort)
	go forwarder.monitor()
	return forwarder, nil
}

func clientPrivateKey(config ForwarderConfig) (key.NodePrivate, error) {
	if config.PrivateKey != "" {
		return parsePrivateKey(config.PrivateKey)
	}
	if config.IdentityPath == "" {
		return key.NodePrivate{}, errors.New("客户端身份文件或私钥不能为空")
	}
	return LoadOrCreateClientIdentity(config.IdentityPath)
}

func (f *Forwarder) Endpoint() string {
	return "http://" + f.listener.Addr().String()
}

func (f *Forwarder) Done() <-chan struct{} {
	return f.done
}

type PathDiagnostic struct {
	Path           string `json:"path"`
	LatencyMillis  int64  `json:"latency_millis"`
	DERPRegionCode string `json:"derp_region_code,omitempty"`
}

func (f *Forwarder) DiscoPing(ctx context.Context) (PathDiagnostic, error) {
	if f == nil {
		return PathDiagnostic{}, errors.New("Tailcat 客户端未启动")
	}
	client, err := f.clientForRequest(ctx)
	if err != nil {
		return PathDiagnostic{}, err
	}
	probeContext, cancel := context.WithTimeout(ctx, forwarderAttemptTimeout)
	result, err := client.transport.DiscoPing(probeContext)
	cancel()
	if err != nil && ctx.Err() == nil {
		client, err = f.recoverClient(ctx, client)
		if err == nil {
			result, err = client.transport.DiscoPing(ctx)
		}
	}
	if err != nil {
		return PathDiagnostic{}, err
	}
	path := "unknown"
	switch {
	case result.Endpoint != "":
		path = "direct"
	case result.PeerRelay != "":
		path = "peer-relay"
	case result.DERPRegionID != 0:
		path = "derp"
	}
	return PathDiagnostic{
		Path:           path,
		LatencyMillis:  max(0, int64(result.LatencySeconds*1000)),
		DERPRegionCode: result.DERPRegionCode,
	}, nil
}

func (f *Forwarder) DiscoPingJSON(ctx context.Context) (string, error) {
	result, err := f.DiscoPing(ctx)
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(result)
	return string(encoded), err
}

func (f *Forwarder) Close() error {
	f.close.Do(func() {
		f.mu.Lock()
		close(f.done)
		f.cancel()
		client, recovery := f.current, f.recovery
		f.current = nil
		connections := make([]net.Conn, 0, len(f.connections))
		for connection := range f.connections {
			connections = append(connections, connection)
		}
		f.mu.Unlock()
		if err := f.listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			f.closeErr = err
		}
		for _, connection := range connections {
			connection.Close()
		}
		if client != nil {
			if err := client.transport.Close(); err != nil && f.closeErr == nil {
				f.closeErr = err
			}
		}
		if recovery != nil {
			// 等待恢复任务清理尚未发布的新引擎，Close 返回后不能留下同身份连接。
			<-recovery.done
		}
	})
	return f.closeErr
}

func (f *Forwarder) accept(remotePort uint16) {
	for {
		localConn, err := f.listener.Accept()
		if err != nil {
			return
		}
		f.mu.Lock()
		if f.ctx.Err() != nil {
			f.mu.Unlock()
			localConn.Close()
			return
		}
		f.connections[localConn] = nil
		f.mu.Unlock()
		go f.proxy(localConn, remotePort)
	}
}

func (f *Forwarder) proxy(localConn net.Conn, remotePort uint16) {
	defer func() {
		localConn.Close()
		f.mu.Lock()
		delete(f.connections, localConn)
		f.mu.Unlock()
	}()
	dialContext, cancel := context.WithTimeout(f.ctx, 15*time.Second)
	defer cancel()
	client, err := f.clientForRequest(dialContext)
	if err != nil {
		return
	}
	for dialContext.Err() == nil {
		attemptContext, stopAttempt := context.WithTimeout(dialContext, forwarderAttemptTimeout)
		tunnelConn, err := client.transport.DialTCPPort(attemptContext, remotePort)
		stopAttempt()
		if err != nil && dialContext.Err() == nil {
			client, err = f.recoverClient(dialContext, client)
			if err == nil {
				tunnelConn, err = client.transport.DialTCPPort(dialContext, remotePort)
			}
		}
		if err != nil {
			return
		}
		f.mu.Lock()
		if dialContext.Err() != nil {
			f.mu.Unlock()
			tunnelConn.Close()
			return
		}
		if f.current != client {
			f.mu.Unlock()
			tunnelConn.Close()
			// 拨号成功也可能落后于并发恢复；尚未转发字节，可以共享恢复后重新拨号。
			client, err = f.recoverClient(dialContext, client)
			if err != nil {
				return
			}
			continue
		}
		f.connections[localConn] = client
		f.mu.Unlock()

		// 只重试建立 TCP，开始复制业务字节后绝不重放，结果未知的消息交给上层处理。
		tailcat.ProxyConns(localConn, tunnelConn)
		return
	}
}
