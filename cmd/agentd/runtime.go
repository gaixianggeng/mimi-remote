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

const (
	deepSeekRuntimeMutationTimeout = 15 * time.Second
	maxDeepSeekStartupURLBytes     = 16 << 10
)

func runRuntime(args []string) error {
	return runRuntimeWithIO(args, os.Stdin, os.Stdout, os.Stderr)
}

func runRuntimeWithWriters(args []string, stdout, stderr io.Writer) error {
	return runRuntimeWithIO(args, strings.NewReader(""), stdout, stderr)
}

func runRuntimeWithIO(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("runtime", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	codexPreference := fs.String("codex", "", "Codex 启用策略：auto、enabled 或 disabled")
	restoreCodex := fs.String("restore-codex", "", "恢复先前 Codex 事务结果 JSON")
	claudePreference := fs.String("claude", "", "Claude 启用策略：auto、enabled 或 disabled")
	restoreClaude := fs.String("restore-claude", "", "恢复先前 Claude 事务结果 JSON")
	deepSeekAction := fs.String("deepseek", "", "DeepSeek 操作：inspect、connect、disabled 或 refresh")
	deepSeekURLStdin := fs.Bool("deepseek-url-stdin", false, "从标准输入读取 Harness 启动链接")
	restoreEnabled := fs.Bool("restore-enabled", false, "服务重载失败时恢复先前 enabled 状态")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("runtime 不接受位置参数；含凭据的 Harness 链接只能通过标准输入传入")
	}
	hasClaude := strings.TrimSpace(*claudePreference) != ""
	hasRestoreClaude := strings.TrimSpace(*restoreClaude) != ""
	hasCodex := strings.TrimSpace(*codexPreference) != ""
	hasRestoreCodex := strings.TrimSpace(*restoreCodex) != ""
	hasDeepSeek := strings.TrimSpace(*deepSeekAction) != ""
	count := 0
	for _, selected := range []bool{
		hasClaude, hasRestoreClaude, hasCodex, hasRestoreCodex, hasDeepSeek,
	} {
		if selected {
			count++
		}
	}
	if count != 1 {
		return fmt.Errorf(
			"必须且只能选择 --claude、--restore-claude、--codex、--restore-codex 或 --deepseek 之一",
		)
	}
	if hasDeepSeek {
		return runDeepSeekRuntime(
			fs,
			*configPath,
			*deepSeekAction,
			*deepSeekURLStdin,
			*restoreEnabled,
			*asJSON,
			stdin,
			stdout,
			stderr,
		)
	}
	if *deepSeekURLStdin {
		return fmt.Errorf("--deepseek-url-stdin 只能与 --deepseek connect 一起使用")
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

func runDeepSeekRuntime(
	fs *flag.FlagSet,
	configPath string,
	rawAction string,
	readURLFromStdin bool,
	restoreEnabled bool,
	asJSON bool,
	stdin io.Reader,
	stdout io.Writer,
	stderr io.Writer,
) error {
	if !asJSON {
		return fmt.Errorf("--deepseek 必须与 --json 一起使用")
	}
	restoreWasSet := false
	fs.Visit(func(item *flag.Flag) {
		if item.Name == "restore-enabled" {
			restoreWasSet = true
		}
	})
	if restoreWasSet || restoreEnabled {
		return fmt.Errorf("--restore-enabled 只适用于 --claude")
	}
	action, err := agentsetup.ParseDeepSeekRuntimeAction(rawAction)
	if err != nil {
		return err
	}
	if readURLFromStdin && action != agentsetup.DeepSeekRuntimeConnect {
		return fmt.Errorf("--deepseek-url-stdin 只能与 --deepseek connect 一起使用")
	}
	startupURL := ""
	if readURLFromStdin {
		startupURL, err = readDeepSeekStartupURL(stdin)
		if err != nil {
			return err
		}
	}
	// inspect 明确只读；其它操作保留现有默认配置迁移语义。
	if action != agentsetup.DeepSeekRuntimeInspect {
		if err := prepareDefaultConfigMigration(fs, configPath, stderr); err != nil {
			return err
		}
	}
	configureCtx, cancel := context.WithTimeout(context.Background(), deepSeekRuntimeMutationTimeout)
	defer cancel()
	result, err := agentsetup.ConfigureDeepSeek(configureCtx, configPath, action, startupURL)
	if err != nil {
		return err
	}
	return printJSONTo(stdout, result)
}

func readDeepSeekStartupURL(reader io.Reader) (string, error) {
	if reader == nil {
		return "", fmt.Errorf("标准输入不可用")
	}
	raw, err := io.ReadAll(io.LimitReader(reader, maxDeepSeekStartupURLBytes+1))
	if err != nil {
		return "", fmt.Errorf("读取 Harness 启动链接失败")
	}
	if len(raw) > maxDeepSeekStartupURLBytes {
		return "", fmt.Errorf("Harness 启动链接不能超过 %d 字节", maxDeepSeekStartupURLBytes)
	}
	value := strings.TrimSpace(string(raw))
	if value == "" {
		return "", fmt.Errorf("Harness 启动链接不能为空")
	}
	return value, nil
}
