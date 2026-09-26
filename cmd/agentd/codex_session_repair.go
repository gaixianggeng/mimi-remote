package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

var releaseSharedCodexSession = appserver.ReleaseSharedLocalBackgroundServer

func runCodexSessionRepair(args []string) error {
	return runCodexSessionRepairWithWriters(args, os.Stdout, os.Stderr)
}

func runCodexSessionRepairWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repair-codex-session", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", config.DefaultPath(), "现有配置文件路径")
	confirmed := fs.Bool("confirm-disconnected", false, "确认共享任务已结束、Mimi 服务已停止且 Desktop SSH 页面已关闭")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if !*confirmed || fs.NArg() != 0 {
		return fmt.Errorf("请先结束共享任务、停止 Mimi 服务并关闭 Desktop SSH 页面，再使用 --confirm-disconnected 确认一次性修复")
	}
	if err := ensureNoLegacyCodexExperimentResidue(); err != nil {
		return err
	}
	// 修复只读取已有配置，不执行 setup、迁移或 EnsureReady，避免检查阶段
	// 抢先创建另一个 resident，也不能对缺失配置隐式采用默认目标。
	info, err := os.Stat(config.ExpandPath(*configPath))
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("修复需要可读取的现有配置文件")
	}
	cfg, err := config.LoadForDoctor(*configPath)
	if err != nil {
		return err
	}
	if !cfg.Codex.IsEnabled() || cfg.AppServer.Transport != "local" || cfg.AppServer.SSHTarget != "" {
		return fmt.Errorf("一次性修复仅适用于已启用 Codex 的本机 local transport，不操作远端 SSH 服务")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	result, err := releaseSharedCodexSession(ctx, appserver.SharedLocalOptions{CodexBin: cfg.Codex.Bin, Env: cfg.Codex.Env})
	if err != nil {
		return err
	}
	if *asJSON {
		return printJSONTo(stdout, result)
	}
	fmt.Fprintln(stdout, result.Message)
	fmt.Fprintln(stdout, "请通过 Mimi Remote Mac 启动服务，或在已登录的本机终端运行 agentd start。")
	return nil
}
