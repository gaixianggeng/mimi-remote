package setup

import (
	"context"
	"fmt"
	"runtime"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

// localAppServerPreflight 在 Linux 首次写入配置前，通过 stdio 启动一次短命
// App Server 并完成 initialize。它不占用正式 WebSocket 端口，也不会留下后台进程。
var localAppServerPreflight = func(ctx context.Context, codexBin string, env map[string]string) error {
	if _, err := appserver.CheckLocalCodex(ctx, codexBin); err != nil {
		return err
	}
	process, _, err := appserver.StartManaged(ctx, appserver.ManagedOptions{
		CodexBin: codexBin,
		Env:      env,
	})
	if err != nil {
		return err
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := process.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("停止本机 Codex app-server 预检进程失败：%w", err)
	}
	return nil
}

func setupUsesManagedLocalAppServer(requestedSSHTarget string) bool {
	if runtime.GOOS == "windows" {
		return true
	}
	return runtime.GOOS == "linux" && requestedSSHTarget == ""
}
