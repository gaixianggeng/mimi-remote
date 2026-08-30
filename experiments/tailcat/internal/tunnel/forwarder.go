package tunnel

import (
	"context"
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
	if _, err := tailcat.ParseConnBlob(tailcat.ConnBlob(config.Address)); err != nil {
		return nil, fmt.Errorf("解析 Tailcat 地址：%w", err)
	}
	privateKey, err := clientPrivateKey(config)
	if err != nil {
		return nil, err
	}
	client := &tailcat.Client{
		Server: tailcat.ConnBlob(config.Address),
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
