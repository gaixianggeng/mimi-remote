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

func runRuntime(args []string) error {
	return runRuntimeWithWriters(args, os.Stdout, os.Stderr)
}

func runRuntimeWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("runtime", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	claudePreference := fs.String("claude", "", "Claude 启用策略：auto、enabled 或 disabled")
	codexSharing := fs.String("codex-sharing", "", "Codex Desktop 共享 app-server：enabled 或 disabled")
	codexSharingDisableConfirmed := fs.Bool(
		"codex-sharing-disable-confirmed",
		false,
		"防误触 interlock：确认 Codex Desktop 已退出后关闭共享 daemon",
	)
	codexSharingRestart := fs.Bool("codex-sharing-restart", false, "防误触 interlock：应用待处理的共享 Codex daemon 迁移")
	codexSharingRestartConfirmed := fs.Bool(
		"codex-sharing-restart-confirmed",
		false,
		"防误触 interlock：调用方确认 Desktop 已正常退出或本来未运行（不是身份鉴权）",
	)
	restoreEnabled := fs.Bool("restore-enabled", false, "服务重载失败时恢复先前 enabled 状态")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	hasClaude := strings.TrimSpace(*claudePreference) != ""
	hasCodexSharing := strings.TrimSpace(*codexSharing) != ""
	hasCodexSharingRestart := *codexSharingRestart
	if *codexSharingRestartConfirmed && !hasCodexSharingRestart {
		return fmt.Errorf("--codex-sharing-restart-confirmed 只能与内部迁移入口一起使用")
	}
	if *codexSharingDisableConfirmed && !hasCodexSharing {
		return fmt.Errorf("--codex-sharing-disable-confirmed 只能与 --codex-sharing=disabled 一起使用")
	}
	operationCount := 0
	for _, selected := range []bool{hasClaude, hasCodexSharing, hasCodexSharingRestart} {
		if selected {
			operationCount++
		}
	}
	if operationCount != 1 {
		return fmt.Errorf("必须且只能传入 --claude、--codex-sharing 或 --codex-sharing-restart 其中一项")
	}
	if hasCodexSharingRestart && !*codexSharingRestartConfirmed {
		return fmt.Errorf("共享 daemon 迁移必须同时传入确认防误触开关；该开关不构成调用方鉴权")
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, stderr); err != nil {
		return err
	}
	if hasCodexSharing {
		enabled, err := parseEnabledDisabled(*codexSharing)
		if err != nil {
			return err
		}
		if *codexSharingDisableConfirmed && enabled {
			return fmt.Errorf("--codex-sharing-disable-confirmed 只能与 --codex-sharing=disabled 一起使用")
		}
		configureCtx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		var result agentsetup.CodexSharingConfigurationResult
		if *codexSharingDisableConfirmed {
			result, err = agentsetup.DisableCodexSharingAfterDesktopExit(configureCtx, *configPath)
		} else {
			result, err = agentsetup.ConfigureCodexSharing(configureCtx, *configPath, enabled)
		}
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
	if hasCodexSharingRestart {
		restartCtx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		result, err := agentsetup.RestartCodexSharingDaemon(restartCtx, *configPath)
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
		return false, fmt.Errorf("--codex-sharing 只支持 enabled 或 disabled")
	}
}
