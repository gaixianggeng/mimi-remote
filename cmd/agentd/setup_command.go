package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func flagSetByCaller(fs *flag.FlagSet, name string) bool {
	present := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == name {
			present = true
		}
	})
	return present
}

func setupLegacyPath(fs *flag.FlagSet) string {
	if flagSetByCaller(fs, "config") || strings.TrimSpace(os.Getenv("AGENTD_CONFIG")) != "" {
		return ""
	}
	return config.LegacyDefaultPath()
}

func setupMigrationNotice(w io.Writer, result agentsetup.Result) {
	if result.Migrated {
		fmt.Fprintln(w, "已复用旧版配置并迁移到新目录（旧文件已保留）")
	}
}

func runSetupWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := onboardingFlagSet("setup", args[1:])
	var options agentsetup.Options
	fs.StringVar(&options.ConfigPath, "config", config.DefaultPath(), "配置文件路径")
	fs.StringVar(&options.ScanRoot, "scan-root", "", "项目扫描目录")
	fs.StringVar(&options.BrowseRoot, "browse-root", "", "移动设备浏览授权目录，新安装默认使用项目扫描目录")
	fs.BoolVar(&options.CreateRoot, "create-root", false, "确认创建所选的缺失目录")
	fs.StringVar(&options.Listen, "listen", "", "监听地址，新安装默认只监听本机")
	fs.StringVar(&options.AppServerSSHTarget, "app-server-ssh-target", "", "共享 Codex App Server 的 SSH 目标")
	fs.BoolVar(&options.Force, "force", false, "兼容旧调用；已有配置必须保留原身份")
	fs.BoolVar(&options.SaveOnly, "no-pair", false, "仅保存配置并返回回执")
	asJSON := fs.Bool("json", false, "输出 JSON")
	qrOnly := fs.Bool("qr-only", false, "只输出短期配对信息")
	options.RuntimePaths = map[string]string{}
	options.Assistants = map[string]string{}
	fs.Func("runtime-path", "程序选择 ID=绝对路径或 auto", func(v string) error { return preflightChoice(options.RuntimePaths, v, true) })
	fs.Func("assistant", "助手启用策略 ID=auto|enabled|disabled", func(v string) error { return preflightChoice(options.Assistants, v, false) })
	if err := parseOnboardingFlags(fs, args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 0 || *qrOnly && options.SaveOnly || (len(options.RuntimePaths)+len(options.Assistants) > 0 && !options.SaveOnly) {
		return invalidOnboardingRequest(errors.New("请检查配对与助手选项"))
	}
	if flagSetByCaller(fs, "scan-root") && strings.TrimSpace(options.ScanRoot) == "" || flagSetByCaller(fs, "browse-root") && strings.TrimSpace(options.BrowseRoot) == "" || options.CreateRoot && options.ScanRoot == "" && options.BrowseRoot == "" {
		return invalidOnboardingRequest(errors.New("请明确选择目录"))
	}
	if err := ensureNoLegacyCodexExperimentResidue(); err != nil {
		return err
	}
	options.LegacyPath = setupLegacyPath(fs)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	result, err := runAgentSetup(ctx, options)
	if err != nil {
		return err
	}
	setupMigrationNotice(stderr, result)
	receipt := setupReceipt{Configured: true, Created: result.Created, ConfigPath: result.ConfigPath, ScanRoot: result.ScanRoot, BrowseRoot: result.BrowseRoot}
	if !options.SaveOnly {
		pair, issueErr := requestPairIssue(ctx, result.ConfigPath, agentsetup.PairingNetworkAuto)
		if issueErr != nil {
			receipt.PairingDeferred = true
		} else {
			pair.Created, pair.ConfigPath = result.Created, result.ConfigPath
			pair.ScanRoot, pair.BrowseRoot = result.ScanRoot, result.BrowseRoot
			result = pair
		}
	}
	if options.SaveOnly || receipt.PairingDeferred {
		if *asJSON {
			return printJSONTo(stdout, struct {
				OK bool `json:"ok"`
				setupReceipt
			}{true, receipt})
		}
		fmt.Fprintln(stdout, "代码目录已保存。", result.ScanRoot)
		if receipt.PairingDeferred {
			fmt.Fprintln(stdout, "待服务、助手和网络就绪后，运行 agentd pair 获取二维码。")
		}
		return nil
	}
	if *asJSON {
		if *qrOnly {
			return printJSONTo(stdout, struct {
				qrOnlyPairOutput
				setupReceipt
			}{qrOnlyPairResult(result), receipt})
		}
		return printJSONTo(stdout, struct {
			OK         bool `json:"ok"`
			Configured bool `json:"configured"`
			agentsetup.Result
		}{true, true, result})
	}
	if *qrOnly {
		printQROnlyPairResult(stdout, result)
	} else {
		printSetupResult(stdout, result)
	}
	return nil
}

type setupReceipt struct {
	Configured      bool   `json:"configured"`
	Created         bool   `json:"created"`
	ConfigPath      string `json:"config_path"`
	ScanRoot        string `json:"scan_root"`
	BrowseRoot      string `json:"browse_root"`
	PairingDeferred bool   `json:"pairing_deferred,omitempty"`
}
