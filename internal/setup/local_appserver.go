package setup

import (
	"context"
	"runtime"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// sharedLocalPreflightTimeout 覆盖版本检查、首次协议初始化和 resident 启动后的重试。
// setup/up 与启动前迁移传入的是 context.Background()，没有这层总超时时，一个能完成
// WebSocket 握手却不回应 initialize 的 socket 会让“正在设置”永远停住。
const sharedLocalPreflightTimeout = 25 * time.Second

var localAppServerPreflight = preflightSharedLocalAppServer

// macOS 设置阶段可能由 SSH 或安装器调用，只验证 CLI，不能抢先创建 SSH 安全会话的
// resident。真实连接验证由 GUI supervisor 的 serve 完成；Linux 保留原有预检。
func preflightSharedLocalAppServer(ctx context.Context, codexBin string, env map[string]string) error {
	ctx, cancel := context.WithTimeout(ctx, sharedLocalPreflightTimeout)
	defer cancel()
	if _, err := appserver.CheckLocalCodex(ctx, codexBin); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		return nil
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
