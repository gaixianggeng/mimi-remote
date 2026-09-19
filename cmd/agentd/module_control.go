package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func runModuleControl(args []string) error {
	fs := flag.NewFlagSet("module", flag.ContinueOnError)
	path := fs.String("config", config.DefaultPath(), "配置文件路径")
	module := fs.String("module", "", "codex、claude、tailscale 或 lan")
	enabled := fs.Bool("enabled", false, "是否启用模块")
	revision := fs.String("if-revision", "", "只修改指定配置版本")
	restoreJSON := fs.String("restore", "", "恢复指定的模块开关快照（不含凭据）")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	supplied := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "enabled" {
			supplied = true
		}
	})
	if !supplied && *restoreJSON == "" {
		return fmt.Errorf("必须显式提供 --enabled=true/false")
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("module 不接受位置参数")
	}
	if err := prepareDefaultConfigMigration(fs, *path, os.Stderr); err != nil {
		return err
	}
	var restore *agentsetup.ModulePreferences
	if *restoreJSON != "" {
		if supplied {
			return fmt.Errorf("--restore 与 --enabled 不能同时使用")
		}
		restore = &agentsetup.ModulePreferences{}
		if err := json.Unmarshal([]byte(*restoreJSON), restore); err != nil {
			return fmt.Errorf("恢复快照无效：%w", err)
		}
	}
	// Never bypass the Windows LAN/private-network safety policy through this
	// new command, including when undo restores a previously enabled LAN.
	if (*module == "lan" && *enabled) || (restore != nil && restore.LAN != nil && *restore.LAN) {
		if err := ensurePlatformLANAccessAllowed(); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	result, err := agentsetup.ConfigureModule(ctx, *path, *module, *enabled, *revision, restore)
	if err != nil {
		return err
	}
	if *asJSON {
		return printJSON(result)
	}
	fmt.Fprintf(os.Stdout, "%s 设置已保存；需要重启：%t\n", result.Module, result.RestartRequired)
	return nil
}
