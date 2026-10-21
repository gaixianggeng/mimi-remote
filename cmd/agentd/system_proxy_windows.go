//go:build windows

package main

import (
	"log"

	"github.com/gaixianggeng/mimi-remote/internal/systemproxy"
)

// startSystemProxyRelay 让本进程之后启动的 Codex app-server 与 Claude 适配器沿用 Windows
// 系统代理（#884）。中转启动失败不影响服务，子进程按原样直连。
func startSystemProxyRelay() func() {
	resolve, ok := systemproxy.SystemResolver()
	if !ok {
		return func() {}
	}
	relay, err := systemproxy.StartRelay(resolve)
	if err != nil {
		log.Printf("agentd system proxy relay unavailable: %v", err)
		return func() {}
	}
	uninstall := systemproxy.Install(relay)
	mode := "unknown"
	if settings, err := systemproxy.CurrentSettings(); err == nil {
		mode = settings.Mode()
	}
	log.Printf("agentd system proxy relay ready mode=%s", mode)
	return func() {
		uninstall()
		_ = relay.Close()
	}
}
