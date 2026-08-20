package main

import (
	"context"
	"maps"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// startManagedIndependentAppServerWebSocket 只为平台默认配置串行化最终
// ownership 复核与 WS 启动；自定义 profile 不拥有全局 shared daemon owner。
func startManagedIndependentAppServerWebSocket(
	cfg config.Config,
	configPath string,
) (*appserver.ManagedWebSocketProcess, error) {
	if !config.IsPlatformDefaultPath(configPath) {
		return startManagedAppServerWebSocket(cfg)
	}

	expectedBin := cfg.Codex.Bin
	expectedEnv := maps.Clone(cfg.Codex.Env)
	var process *appserver.ManagedWebSocketProcess
	ctx, cancel := context.WithTimeout(context.Background(), sharedDaemonReconcileTimeout)
	defer cancel()
	err := appserver.StartIndependentModeRuntime(
		ctx,
		func() error {
			return config.ValidateSharedDaemonDisabledOwnership(configPath, expectedBin, expectedEnv)
		},
		func() error {
			var startErr error
			process, startErr = startManagedAppServerWebSocket(cfg)
			return startErr
		},
	)
	if err != nil {
		return nil, err
	}
	return process, nil
}
