package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

const (
	codexDesktopSyncMutationTimeout = 45 * time.Second
)

func runRuntime(args []string) error {
	return runRuntimeWithWriters(args, os.Stdout, os.Stderr)
}

func runRuntimeWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("runtime", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	claudePreference := fs.String("claude", "", "Claude 启用策略：auto、enabled 或 disabled")
	codexDesktopSync := fs.String("codex-desktop-sync", "", "Codex Desktop 会话同步：enabled 或 disabled")
	cleanupLegacySharingConfirmed := fs.Bool(
		"cleanup-legacy-sharing-confirmed",
		false,
		"确认 Codex Desktop 已退出后清理旧共享 daemon 配置",
	)
	restoreEnabled := fs.Bool("restore-enabled", false, "服务重载失败时恢复先前 enabled 状态")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	hasClaude := strings.TrimSpace(*claudePreference) != ""
	hasCodexDesktopSync := strings.TrimSpace(*codexDesktopSync) != ""
	if *cleanupLegacySharingConfirmed && !hasCodexDesktopSync {
		return fmt.Errorf("--cleanup-legacy-sharing-confirmed 只能与 --codex-desktop-sync 一起使用")
	}
	operationCount := 0
	for _, selected := range []bool{hasClaude, hasCodexDesktopSync} {
		if selected {
			operationCount++
		}
	}
	if operationCount != 1 {
		return fmt.Errorf("必须且只能传入 --claude 或 --codex-desktop-sync 其中一项")
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, stderr); err != nil {
		return err
	}
	if hasCodexDesktopSync {
		enabled, err := parseEnabledDisabled(*codexDesktopSync)
		if err != nil {
			return err
		}
		configureCtx, cancel := context.WithTimeout(context.Background(), codexDesktopSyncMutationTimeout)
		result, err := agentsetup.ConfigureCodexDesktopSync(
			configureCtx,
			*configPath,
			enabled,
			*cleanupLegacySharingConfirmed,
		)
		cancel()
		if err != nil {
			return err
		}
		if *asJSON {
			return printJSONTo(stdout, result)
		}
		fmt.Fprintln(stdout, result.Message)
		return nil
	}
	preference, err := agentsetup.ParseClaudeActivationPreference(*claudePreference)
	if err != nil {
		return err
	}
	var restored *bool
	fs.Visit(func(item *flag.Flag) {
		if item.Name == "restore-enabled" {
			value := *restoreEnabled
			restored = &value
		}
	})
	result, err := agentsetup.ConfigureClaude(
		context.Background(),
		*configPath,
		preference,
		restored,
	)
	if err != nil {
		return err
	}
	if *asJSON {
		return printJSONTo(stdout, result)
	}
	state := "关闭"
	if result.Enabled {
		state = "开启"
	}
	fmt.Fprintf(stdout, "Claude 实验通道：%s\n", state)
	if strings.TrimSpace(result.Message) != "" {
		fmt.Fprintln(stdout, result.Message)
	}
	if result.RestartRequired {
		fmt.Fprintln(stdout, "配置已更新，需要重启 agentd 后生效。")
	}
	return nil
}

func parseEnabledDisabled(raw string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "enabled", "true", "1":
		return true, nil
	case "disabled", "false", "0":
		return false, nil
	default:
		return false, fmt.Errorf("--codex-desktop-sync 只支持 enabled 或 disabled")
	}
}
