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

const claudeRuntimeMutationTimeout = 45 * time.Second

func runRuntime(args []string) error {
	return runRuntimeWithWriters(args, os.Stdout, os.Stderr)
}

func runRuntimeWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("runtime", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	claudePreference := fs.String("claude", "", "Claude 启用策略：auto、enabled 或 disabled")
	restoreEnabled := fs.Bool("restore-enabled", false, "服务重载失败时恢复先前 enabled 状态")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	hasClaude := strings.TrimSpace(*claudePreference) != ""
	if !hasClaude {
		return fmt.Errorf("必须传入 --claude")
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, stderr); err != nil {
		return err
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
