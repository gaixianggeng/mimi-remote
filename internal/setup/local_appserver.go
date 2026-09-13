package setup

import (
	"context"
	"runtime"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// localAppServerPreflight 在 macOS 与 Linux 首次写入配置前附着或启动共享 control
// socket，并完成 initialize。成功后 resident 保持运行，供终端、Codex Desktop 与 agentd 共用。
var localAppServerPreflight = func(ctx context.Context, codexBin string, env map[string]string) error {
	if _, err := appserver.CheckLocalCodex(ctx, codexBin); err != nil {
		return err
	}
	transport, err := appserver.NewSharedLocalTransport(appserver.SharedLocalOptions{
		CodexBin: codexBin,
		Env:      env,
	})
	if err != nil {
		return err
	}
	return transport.EnsureReady(ctx)
}

func setupUsesManagedLocalAppServer(requestedSSHTarget string) bool {
	return runtime.GOOS == "windows"
}

// 显式 SSH target 仍是受支持的远端模式；没有 target 时 macOS 与 Linux 都直连本机 socket。
func setupUsesSharedLocalAppServer(requestedSSHTarget string) bool {
	return config.SupportsSharedLocalAppServer() && requestedSSHTarget == ""
}
