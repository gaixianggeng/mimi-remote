package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"path/filepath"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

var runHostPreflight = setup.RunPreflight

func runPreflight(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("preflight", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	o := setup.PreflightOptions{Version: version, RuntimePaths: map[string]string{}, Assistants: map[string]string{}}
	fs.StringVar(&o.Stage, "stage", "setup", "检查阶段")
	fs.StringVar(&o.ConfigPath, "config", config.DefaultPath(), "配置文件")
	fs.StringVar(&o.ScanRoot, "scan-root", "", "代码目录")
	fs.StringVar(&o.BrowseRoot, "browse-root", "", "浏览目录")
	asJSON := fs.Bool("json", false, "输出 JSON")
	fs.BoolVar(&o.InstallerSmoke, "installer-smoke", false, "验证离线安装包的隔离预检结果")
	stream := fs.Bool("progress-json", false, "流式输出检查进度")
	fs.Func("assistant", "助手草稿", func(value string) error { return preflightChoice(o.Assistants, value, false) })
	fs.Func("runtime-path", "程序草稿", func(value string) error { return preflightChoice(o.RuntimePaths, value, true) })
	if err := fs.Parse(args[1:]); err != nil {
		return invalidOnboardingRequest(err)
	}
	if !*asJSON || fs.NArg() != 0 || o.Stage != "setup" && o.Stage != "pair" || strings.TrimSpace(o.ConfigPath) == "" {
		return invalidOnboardingRequest(errors.New("请指定有效的预检参数"))
	}
	for _, root := range []string{o.ScanRoot, o.BrowseRoot} {
		if strings.TrimSpace(root) != root || (root != "" && !filepath.IsAbs(config.ExpandPath(root))) {
			return invalidOnboardingRequest(errors.New("请选择代码目录的绝对路径"))
		}
	}
	if o.Stage == "pair" && (len(o.RuntimePaths)+len(o.Assistants) > 0 || o.ScanRoot != "" || o.BrowseRoot != "") {
		return invalidOnboardingRequest(errors.New("配对检查使用已保存的配置"))
	}
	if o.InstallerSmoke && (o.Stage != "setup" || !flagSetByCaller(fs, "config") || o.ScanRoot == "" || o.BrowseRoot == "") {
		return invalidOnboardingRequest(errors.New("请提供隔离的配置、扫描和浏览目录"))
	}
	o.LegacyPath = setupLegacyPath(fs)
	o.HostDial = coreDialForConfig(o.ConfigPath)
	var progress func(setup.PreflightCheck)
	var streamErr error
	if *stream {
		enc := json.NewEncoder(stderr)
		progress = func(row setup.PreflightCheck) {
			if streamErr == nil {
				streamErr = enc.Encode(row)
			}
		}
	}
	report := runHostPreflight(context.Background(), o, progress)
	if o.InstallerSmoke && !validInstallerPreflight(report, o) {
		return errors.New("安装包隔离预检失败")
	}
	return json.NewEncoder(stdout).Encode(report)
}

func preflightChoice(choices map[string]string, raw string, path bool) error {
	id, value, ok := strings.Cut(raw, "=")
	if !ok || (id != "codex" && id != "claude" && id != "agy") {
		return errors.New("助手标识无效")
	}
	if _, ok := choices[id]; ok {
		return errors.New("助手标识重复")
	}
	if path {
		if value != "auto" && (!filepath.IsAbs(value) || strings.TrimSpace(value) != value) {
			return errors.New("请选择程序的绝对路径")
		}
	} else if value != "auto" && value != "enabled" && value != "disabled" {
		return errors.New("助手状态无效")
	}
	choices[id] = value
	return nil
}

func validInstallerPreflight(r setup.PreflightReport, o setup.PreflightOptions) bool {
	if r.Schema != "mimi.onboarding.preflight/v1" || r.Stage != "setup" || !r.OK || r.Configured || r.WorkspaceConfirmed ||
		!r.ScanRootExists || r.ConfigPath != o.ConfigPath || r.ScanRoot != o.ScanRoot || r.BrowseRoot != o.BrowseRoot {
		return false
	}
	var store, workspace bool
	for _, row := range r.Checks {
		switch row.ID {
		case "config_store":
			store = row.State == "ok" && !row.Blocking
		case "workspace_root":
			workspace = row.State == "ok" && !row.Blocking
		}
	}
	return store && workspace
}
