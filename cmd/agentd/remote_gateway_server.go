package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
)

type remoteGatewayServer struct {
	server   *http.Server
	listener net.Listener
}

func startRemoteGatewayServer(cfg config.Config, router *httpapi.Router) (*remoteGatewayServer, error) {
	if !cfg.AppServer.RemoteGateway.Enabled {
		return nil, nil
	}
	if router == nil {
		return nil, fmt.Errorf("remote gateway 缺少 Router")
	}
	address := strings.TrimSpace(cfg.AppServer.RemoteGateway.Listen)
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return nil, fmt.Errorf("监听 remote gateway %s 失败：%w", address, err)
	}
	return &remoteGatewayServer{
		server: &http.Server{
			Addr:              address,
			Handler:           router.RemoteGatewayHandler(),
			ReadHeaderTimeout: 10 * time.Second,
		},
		listener: listener,
	}, nil
}

func (s *remoteGatewayServer) shutdown(timeout time.Duration) error {
	if s == nil || s.server == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if err := s.server.Shutdown(ctx); err != nil {
		_ = s.server.Close()
		return err
	}
	return nil
}
