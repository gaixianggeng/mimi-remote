package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func moduleListenAddresses(cfg config.Config) []string {
	if !cfg.HasNetworkModuleControls() {
		return agentDListenAddresses(cfg.Listen, cfg.Network.AllowLAN)
	}
	_, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return []string{cfg.Listen}
	}
	if cfg.TailscaleAccessEnabled() || cfg.LANAccessEnabled() {
		// Every socket accepted on this listener is checked by networkaccess.
		// Wildcard alone is never the module-control security boundary.
		return []string{net.JoinHostPort("0.0.0.0", port)}
	}
	return []string{net.JoinHostPort("127.0.0.1", port)}
}

func fetchModuleStatusForCommand(endpoint, token string) *config.ModuleStatus {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(endpoint, "/")+"/api/host/modules", nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "Bearer "+token)
	client := &http.Client{Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	response, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil
	}
	var status config.ModuleStatus
	if err := json.NewDecoder(io.LimitReader(response.Body, 16<<10)).Decode(&status); err != nil {
		return nil
	}
	return &status
}
