//go:build windows

package doctor

import (
	"context"
	"fmt"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/tailcatsidecar"
)

// tailcatCheck 确认安装包内置的 Tailcat 辅助程序可以运行。Tailcat 默认关闭，未启用时
// 缺失只作提醒；启用后缺失或无法运行会让 Tailcat 设备离线，按错误处理。
func (c *Checker) tailcatCheck(ctx context.Context) Check {
	enabled := c.cfg.Tailcat.Enabled
	failure := func(message string, fix string) Check {
		check := Check{Name: "tailcat", OK: false, Message: message, Fix: fix}
		if !enabled {
			check.Level = "warning"
		}
		return check
	}
	reinstall := "重新运行与 agentd 同版本的 Mimi Remote Windows 安装器"
	path, err := tailcatsidecar.Resolve(c.cfg.Tailcat.SidecarBin)
	if err != nil {
		return failure(err.Error(), reinstall)
	}
	version, err := tailcatsidecar.Version(ctx, path)
	if err != nil {
		return failure(err.Error(), reinstall)
	}
	agentVersion := strings.TrimPrefix(strings.TrimSpace(c.version), "v")
	if agentVersion != "" && agentVersion != "devel" && version != "devel" &&
		strings.TrimPrefix(version, "v") != agentVersion {
		check := failure(fmt.Sprintf("Tailcat 辅助程序 %s 与 agentd %s 版本不一致", version, agentVersion), reinstall)
		check.Level = "warning"
		return check
	}
	state := "已启用"
	if !enabled {
		state = "未启用，可在托盘或 agentd tailcat enable 中开启"
	}
	return Check{Name: "tailcat", OK: true, Message: fmt.Sprintf("Tailcat 辅助程序 %s 可用（%s）", version, state)}
}
