package httpapi

import (
	"context"
	"errors"

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
	client, err := r.authenticatedDeepSeekClient(ctx)
	switch {
	case errors.Is(err, errDeepSeekCredentialsUnavailable):
		status.Reason = "credentials_unavailable"
		return status
	case errors.Is(err, harnessclient.ErrCredentialsRejected):
		// 服务在线但不认已存 token，且自动更新没成功：需要用户换启动链接，而不是等服务恢复。
		status.State = runtimeStateSignedOut
		status.Reason = deepSeekCredentialsRejectedReason
		return status
	case err != nil:
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

// deepSeekCredentialsRejectedReason 标记“Harness 拒绝已存启动凭据”。它同样按失败快照
// 短期缓存，Harness 重启后的自动更新或用户手动恢复能尽快反映到菜单栏。
const deepSeekCredentialsRejectedReason = "credentials_rejected"
