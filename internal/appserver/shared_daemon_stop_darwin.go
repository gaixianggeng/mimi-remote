//go:build darwin

package appserver

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

func stopManagedSharedDaemonCommand(ctx context.Context, options LocalDaemonOptions) error {
	bin := strings.TrimSpace(options.CodexBin)
	if bin == "" {
		bin = "codex"
	}
	cmd := exec.CommandContext(ctx, bin, "app-server", "daemon", "stop")
	configureManagedCommand(cmd)
	cmd.Env = buildManagedEnv(options.Env)
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	message := sanitizeDiagnostic(string(output))
	lower := strings.ToLower(message)
	if strings.Contains(lower, "not running") || strings.Contains(lower, "no running") {
		return nil
	}
	if strings.Contains(lower, unmanagedSharedDaemonMessage) {
		return fmt.Errorf("官方 lifecycle 报告 pid backend，但 stop 拒绝管理该进程，已停止迁移")
	}
	if message == "" {
		return fmt.Errorf("停止旧 Codex local daemon 失败：%w", err)
	}
	return fmt.Errorf("停止旧 Codex local daemon 失败：%s", message)
}
