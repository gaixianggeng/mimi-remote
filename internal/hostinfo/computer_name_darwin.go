//go:build darwin

package hostinfo

import (
	"context"
	"os/exec"
)

// platformComputerName 读取 macOS 系统设置里的「电脑名称」（例如「某某的 Mac Studio」）。
// 它是用户在系统设置里认得的设备名；读取失败、超时或输出异常时返回空，由调用方退回主机名。
func platformComputerName(ctx context.Context) string {
	runCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	output, err := exec.CommandContext(runCtx, "scutil", "--get", "ComputerName").Output()
	if err != nil || len(output) == 0 || len(output) > commandOutputLimit {
		return ""
	}
	return string(output)
}
