package httpapi

import (
	"context"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// probeDeepSeekRuntime 只验证已启用服务的握手与模型目录，不创建会话或占用 follow 名额。
// 不能把 Setup 的预检成功当作 agentd 已加载配置；Mac 使用这里的运行态作最终判断。
func (r *Router) probeDeepSeekRuntime(ctx context.Context) runtimeAccountStatus {
	status := runtimeAccountStatus{
		ID: "deepseek", Title: "DeepSeek Harness", Enabled: r.cfg.DeepSeek.Enabled,
		State: runtimeStateUnavailable, Reason: "harness_unavailable",
	}
	if !status.Enabled {
		status.State = runtimeStateDisabled
		status.Reason = "disabled"
		return status
	}
	// 凭据误指向命名管道时，文件读取不受 context 超时控制；探测不能因此卡住全部状态刷新。
	info, err := os.Stat(r.cfg.DeepSeek.TokenFile)
	if err != nil || !info.Mode().IsRegular() {
		status.Reason = "credentials_unavailable"
		return status
	}
	token, err := harnessclient.ReadTokenFile(r.cfg.DeepSeek.TokenFile)
	if err != nil {
		status.Reason = "credentials_unavailable"
		return status
	}
	client, err := harnessclient.New(harnessclient.Config{BaseURL: r.cfg.DeepSeek.BaseURL, AccessToken: token})
	if err != nil || client.Authenticate(ctx) != nil {
		return status
	}
	catalog, err := client.ModelCatalog(ctx)
	if err != nil {
		return status
	}
	for _, group := range catalog.Groups {
		if len(group.Models) > 0 {
			status.State = runtimeStateAvailable
			status.Reason = "ready"
			return status
		}
	}
	status.Reason = "models_unavailable"
	return status
}
