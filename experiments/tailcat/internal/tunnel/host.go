package tunnel

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/wgengine/filter"
)

type HostConfig struct {
	TargetAddr        string
	RemotePort        uint16
	IdentityPath      string
	AddressPath       string
	AllowedClientKey  string
	AllowedClientKeys []string
	AllowAllClients   bool
	DERPMapURL        string
	Region            *tailcfg.DERPRegion
}

type Host struct {
	server  *tailcat.Server
	address tailcat.Addr
}

func StartHost(config HostConfig) (*Host, error) {
	if config.RemotePort == 0 {
		return nil, errors.New("远端端口不能为 0")
	}
	if err := requireLoopbackAddress(config.TargetAddr); err != nil {
		return nil, fmt.Errorf("agentd 目标地址：%w", err)
	}
	allowedClients := make([]key.NodePublic, 0, len(config.AllowedClientKeys)+1)
	clientKeys := append([]string(nil), config.AllowedClientKeys...)
	if config.AllowedClientKey != "" {
		clientKeys = append(clientKeys, config.AllowedClientKey)
	}
	for _, rawKey := range clientKeys {
		allowedClient, err := ParsePublicKey(rawKey)
		if err != nil {
			return nil, err
		}
		allowedClients = append(allowedClients, allowedClient)
	}
	if !config.AllowAllClients && len(allowedClients) == 0 {
		// Tailcat 把空白名单解释为允许所有客户端。实验服务未配对时必须显式
		// 放入一个永远不会分发的占位键，保证稳定地址默认拒绝连接。
		allowedClients = append(allowedClients, key.NewNode().Public())
	}
	privateKey, savedInfo, err := loadOrCreateHostIdentity(config.IdentityPath)
	if err != nil {
		return nil, err
	}

	server := &tailcat.Server{
		Key:            privateKey,
		Logf:           logger.Discard,
		AllowedClients: allowedClients,
		ServedTCPPorts: []filter.PortRange{{First: config.RemotePort, Last: config.RemotePort}},
	}
	if savedInfo != nil {
		server.Region = savedInfo.Region[0]
	} else if config.Region != nil {
		server.Region = config.Region
	} else {
		server.DERPMapURL = config.DERPMapURL
	}
	server.OnTCP = func(port uint16) func(net.Conn) {
		if port != config.RemotePort {
			return nil
		}
		return func(tunnelConn net.Conn) {
			backendConn, err := net.DialTimeout("tcp", config.TargetAddr, 5*time.Second)
			if err != nil {
				tunnelConn.Close()
				return
			}
			tailcat.ProxyConns(tunnelConn, backendConn)
		}
	}

	if err := server.Start(); err != nil {
		return nil, fmt.Errorf("启动 Tailcat 服务端：%w", err)
	}
	address := server.TailcatAddr()
	if savedInfo == nil {
		if err := saveHostIdentity(config.IdentityPath, privateKey, address); err != nil {
			server.Close()
			return nil, err
		}
	}
	if err := writePrivateFile(config.AddressPath, []byte(string(address)+"\n")); err != nil {
		server.Close()
		return nil, fmt.Errorf("写入 Tailcat 地址：%w", err)
	}
	return &Host{server: server, address: address}, nil
}

func (h *Host) AddAllowedClient(rawKey string) error {
	if h == nil || h.server == nil {
		return errors.New("Tailcat 服务端未启动")
	}
	client, err := ParsePublicKey(rawKey)
	if err != nil {
		return err
	}
	h.server.AddAllowedClient(client)
	return nil
}

func (h *Host) Address() string {
	return string(h.address)
}

func (h *Host) Close() error {
	if h == nil || h.server == nil {
		return nil
	}
	return h.server.Close()
}

func requireLoopbackAddress(address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("必须是 host:port：%w", err)
	}
	if port == "" {
		return errors.New("端口不能为空")
	}
	if host == "localhost" {
		return nil
	}
	ip, err := netip.ParseAddr(host)
	if err != nil || !ip.IsLoopback() {
		return errors.New("只允许 127.0.0.1、::1 或 localhost")
	}
	return nil
}
