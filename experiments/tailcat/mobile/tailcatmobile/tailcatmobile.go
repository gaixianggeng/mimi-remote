// Package tailcatmobile exposes the smallest gomobile-compatible surface needed
// by the iOS experiment. The app keeps the private key in Keychain.
package tailcatmobile

import (
	"context"
	"fmt"
	"time"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
)

type Proxy struct {
	forwarder *tunnel.Forwarder
}

func GeneratePrivateKey() (string, error) {
	return tunnel.NewClientPrivateKey()
}

func PublicKey(privateKey string) (string, error) {
	return tunnel.ClientPublicKey(privateKey)
}

func StartProxy(address, privateKey string, remotePort int) (*Proxy, error) {
	if remotePort < 1 || remotePort > 65535 {
		return nil, fmt.Errorf("远端端口超出范围：%d", remotePort)
	}
	forwarder, err := tunnel.StartForwarder(context.Background(), tunnel.ForwarderConfig{
		Address:    address,
		PrivateKey: privateKey,
		RemotePort: uint16(remotePort),
		ListenAddr: "127.0.0.1:0",
	})
	if err != nil {
		return nil, err
	}
	return &Proxy{forwarder: forwarder}, nil
}

func (p *Proxy) LocalEndpoint() string {
	if p == nil || p.forwarder == nil {
		return ""
	}
	return p.forwarder.Endpoint()
}

func (p *Proxy) DiscoPing(timeoutSeconds int) (string, error) {
	if p == nil || p.forwarder == nil {
		return "", fmt.Errorf("Tailcat 代理未启动")
	}
	if timeoutSeconds < 1 || timeoutSeconds > 30 {
		timeoutSeconds = 10
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSeconds)*time.Second)
	defer cancel()
	return p.forwarder.DiscoPingJSON(ctx)
}

func (p *Proxy) Close() error {
	if p == nil || p.forwarder == nil {
		return nil
	}
	err := p.forwarder.Close()
	p.forwarder = nil
	return err
}
