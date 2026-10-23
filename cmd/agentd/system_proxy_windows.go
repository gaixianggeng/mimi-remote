//go:build windows

package main

import (
	"errors"
	"fmt"
	"log"

	"github.com/gaixianggeng/mimi-remote/internal/systemproxy"
)

// startSystemProxyRelay 让本进程之后启动的 Codex app-server 与 Claude 适配器沿用 Windows
// 系统代理（#884）。中转不可用时必须终止启动，不能让仅能经代理联网的会话静默直连。
func startSystemProxyRelay() (func(), error) {
	resolve, ok := systemproxy.SystemResolver()
	if !ok {
		return nil, errors.New("当前 Windows 环境不支持系统代理解析")
	}
	return startSystemProxyRelayWithResolver(resolve)
}

func startSystemProxyRelayWithResolver(resolve systemproxy.Resolver) (func(), error) {
	relay, err := systemproxy.StartRelay(resolve)
	if err != nil {
		return nil, fmt.Errorf("启动 Windows 系统代理中转：%w", err)
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
	}, nil
}
