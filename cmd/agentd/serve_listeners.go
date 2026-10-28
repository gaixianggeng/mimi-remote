package main

import (
	"fmt"
	"net"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
)

// bindServeListeners owns startup listeners until all required binds succeed.
func bindServeListeners(cfg config.Config, addresses []string, bind func(config.Config, string) (net.Listener, error)) ([]net.Listener, bool, error) {
	listeners := make([]net.Listener, 0, len(addresses))
	for _, address := range addresses {
		listener, err := bind(cfg, address)
		if err != nil {
			for _, opened := range listeners {
				_ = opened.Close()
			}
			return nil, false, fmt.Errorf("监听 %s 失败：%w", address, err)
		}
		if listener == nil {
			continue
		}
		if cfg.HasNetworkModuleControls() {
			listener = networkaccess.Wrap(listener, moduleIngressPolicy(cfg))
		}
		listeners = append(listeners, listener)
	}
	return listeners, false, nil
}
