package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

const claudeRuntimeMutationTimeout = 45 * time.Second

func runRuntime(args []string) error {
	return runRuntimeWithWriters(args, os.Stdout, os.Stderr)
}

func runRuntimeWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("runtime", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	codexPreference := fs.String("codex", "", "Codex 启用策略：auto、enabled 或 disabled")
	restoreCodex := fs.String("restore-codex", "", "恢复先前 Codex 事务结果 JSON")
	claudePreference := fs.String("claude", "", "Claude 启用策略：auto、enabled 或 disabled")
	restoreClaude := fs.String("restore-claude", "", "恢复先前 Claude 事务结果 JSON")
	restoreEnabled := fs.Bool("restore-enabled", false, "服务重载失败时恢复先前 enabled 状态")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	hasClaude := strings.TrimSpace(*claudePreference) != ""
	hasRestoreClaude := strings.TrimSpace(*restoreClaude) != ""
	hasCodex := strings.TrimSpace(*codexPreference) != ""
	hasRestoreCodex := strings.TrimSpace(*restoreCodex) != ""
	count := 0
	for _, selected := range []bool{hasClaude, hasRestoreClaude, hasCodex, hasRestoreCodex} {
		if selected {
			count++
		}
	}
	if count != 1 {
		return fmt.Errorf("必须且只能选择 --claude、--restore-claude、--codex 或 --restore-codex 之一")
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, stderr); err != nil {
		return err
	}
	if hasCodex || hasRestoreCodex {
		ctx, cancel := context.WithTimeout(context.Background(), claudeRuntimeMutationTimeout)
		defer cancel()
		var result agentsetup.CodexConfigurationResult
		var err error
		if hasRestoreCodex {
			var previous agentsetup.CodexConfigurationResult
			if err = json.Unmarshal([]byte(*restoreCodex), &previous); err != nil {
				return err
			}
			result, err = agentsetup.RestoreCodex(*configPath, previous)
		} else {
			result, err = agentsetup.ConfigureCodex(ctx, *configPath, *codexPreference)
		}
		if err != nil {
			return err
		}
		if *asJSON {
			return printJSONTo(stdout, result)
		}
		fmt.Fprintln(stdout, result.Message)
		if result.RestartRequired {
			fmt.Fprintln(stdout, "配置已保存，重启 agentd 后生效。")
		}
		return nil
	}
	if hasRestoreClaude {
		var previous agentsetup.ClaudeConfigurationResult
		if err := json.Unmarshal([]byte(*restoreClaude), &previous); err != nil {
			return err
		}
		result, err := agentsetup.RestoreClaude(*configPath, previous)
		if err != nil {
			return err
		}
		if *asJSON {
			return printJSONTo(stdout, result)
		}
		fmt.Fprintln(stdout, result.Message)
		if result.RestartRequired {
			fmt.Fprintln(stdout, "配置已恢复，需要重启 agentd 后生效。")
		}
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
	configureCtx, cancel := context.WithTimeout(context.Background(), claudeRuntimeMutationTimeout)
	defer cancel()
	result, err := agentsetup.ConfigureClaude(
		configureCtx,
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
