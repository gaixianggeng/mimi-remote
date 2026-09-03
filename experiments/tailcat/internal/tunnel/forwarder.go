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
	client   *tailcat.Client
	listener net.Listener
	done     chan struct{}
	close    sync.Once
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
	client := &tailcat.Client{
		Server: tailcat.Addr(config.Address),
		Key:    privateKey,
		Logf:   logger.Discard,
	}
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
	forwarder := &Forwarder{
		client:   client,
		listener: listener,
		done:     make(chan struct{}),
	}
	if config.EndpointPath != "" {
		if err := writePrivateFile(config.EndpointPath, []byte(forwarder.Endpoint()+"\n")); err != nil {
			forwarder.Close()
			return nil, fmt.Errorf("写入本地端点：%w", err)
		}
	}
	go forwarder.accept(config.RemotePort)
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
	if f == nil || f.client == nil {
		return PathDiagnostic{}, errors.New("Tailcat 客户端未启动")
	}
	result, err := f.client.DiscoPing(ctx)
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
	var closeError error
	f.close.Do(func() {
		close(f.done)
		if err := f.listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			closeError = err
		}
		if err := f.client.Close(); err != nil && closeError == nil {
			closeError = err
		}
	})
	return closeError
}

func (f *Forwarder) accept(remotePort uint16) {
	for {
		localConn, err := f.listener.Accept()
		if err != nil {
			return
		}
		go f.proxy(localConn, remotePort)
	}
}

func (f *Forwarder) proxy(localConn net.Conn, remotePort uint16) {
	dialContext, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	tunnelConn, err := f.client.DialTCPPort(dialContext, remotePort)
	if err != nil {
		localConn.Close()
		return
	}
	tailcat.ProxyConns(localConn, tunnelConn)
}
