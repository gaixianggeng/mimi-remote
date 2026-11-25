package setup

import (
	"context"
	"runtime"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// sharedLocalPreflightTimeout 覆盖版本检查、首次协议初始化和 resident 启动后的重试。
// setup/up 与启动前迁移传入的是 context.Background()，没有这层总超时时，一个能完成
// WebSocket 握手却不回应 initialize 的 socket 会让“正在设置”永远停住。
const sharedLocalPreflightTimeout = 25 * time.Second

var localAppServerPreflight = preflightSharedLocalAppServer

// macOS 设置阶段可能由 SSH 或安装器调用，只验证 CLI 与 socket 路径，不能抢先创建 SSH 安全会话的
// resident。真实连接验证由 GUI supervisor 的 serve 完成；Linux 保留原有预检。
func preflightSharedLocalAppServer(ctx context.Context, codexBin string, env map[string]string) error {
	ctx, cancel := context.WithTimeout(ctx, sharedLocalPreflightTimeout)
	defer cancel()
	req := CodexRuntime(config.CodexConfig{Env: env}, "local")
	if codexBin != "codex" {
		req.Override = codexBin
	}
	candidate, err := ResolveRuntime(ctx, req)
	if err != nil {
		return err
	}
	transport, err := appserver.NewSharedLocalTransport(appserver.SharedLocalOptions{
		CodexBin: candidate.Path,
		Env:      env,
	})
	if err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		return nil
	}
	return transport.EnsureReady(ctx)
}

// Windows can save an automatic configuration before a compatible Codex is
// installed. Launch will discover it then. Only explicit selections gate setup.
func (d RuntimeDiscovery) preflightManagedCodex(ctx context.Context, override string) error {
	override = strings.TrimSpace(override)
	if (override == "" || override == "auto") && strings.TrimSpace(d.getenv("AGENTD_CODEX_BIN")) == "" {
		return nil
	}
	_, err := d.Resolve(ctx, RuntimeRequest{Name: "codex", Transport: "ws", Override: override})
	return err
}

func setupUsesManagedLocalAppServer(requestedSSHTarget string) bool {
	return runtime.GOOS == "windows"
}

// 显式 SSH target 仍是受支持的远端模式；没有 target 时 macOS 与 Linux 都直连本机 socket。
func setupUsesSharedLocalAppServer(requestedSSHTarget string) bool {
	return config.SupportsSharedLocalAppServer() && requestedSSHTarget == ""
}
