package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func runWorkspace(args []string) error {
	return runWorkspaceWithWriters(args, os.Stdout, os.Stderr)
}

func runWorkspaceWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("workspace", flag.ContinueOnError)
	fs.SetOutput(stderr)
	path := fs.String("config", config.DefaultPath(), "配置文件路径")
	root := fs.String("root", "", "项目扫描与移动设备浏览授权目录")
	scan := fs.String("scan-root", "", "项目扫描目录")
	browse := fs.String("browse-root", "", "移动设备浏览授权目录；省略时保留现有授权")
	primary := fs.Bool("primary", false, "仅更新指定列表的首个目录，保留其他目录")
	browseOnly := fs.String("set-browse-root", "", "仅替换移动设备浏览授权范围，保留全部扫描目录")
	restore := fs.String("restore-state", "", "恢复先前目录设置事务 JSON")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := parseOnboardingFlags(fs, args[1:]); err != nil {
		return err
	}
	hasRoot := flagSetByCaller(fs, "root")
	hasScan := flagSetByCaller(fs, "scan-root")
	hasBrowse := flagSetByCaller(fs, "browse-root")
	hasRestore := flagSetByCaller(fs, "restore-state")
	hasPrimary := flagSetByCaller(fs, "primary")
	hasBrowseOnly := flagSetByCaller(fs, "set-browse-root")
	selection := agentsetup.WorkspaceSelection{}
	valid := false
	switch {
	case hasBrowseOnly:
		valid = *browseOnly != "" && !hasRoot && !hasScan && !hasBrowse && !hasPrimary && !hasRestore
		selection.BrowseRoot = *browseOnly
	case hasPrimary:
		valid = *primary && !hasRoot && !hasRestore && (hasScan || hasBrowse) && (!hasScan || *scan != "") && (!hasBrowse || *browse != "")
		selection = agentsetup.WorkspaceSelection{ScanRoot: *scan, BrowseRoot: *browse, PrimaryOnly: true}
	case hasRestore:
		valid = *restore != "" && !hasRoot && !hasScan && !hasBrowse
	case hasRoot:
		valid = *root != "" && !hasScan && !hasBrowse
		selection = agentsetup.WorkspaceSelection{ScanRoot: *root, BrowseRoot: *root}
	case hasScan:
		valid = *scan != "" && (!hasBrowse || *browse != "")
		selection = agentsetup.WorkspaceSelection{ScanRoot: *scan, BrowseRoot: *browse}
	}
	if fs.NArg() != 0 || !valid {
		return invalidOnboardingRequest(fmt.Errorf("请选择 --root、--scan-root [--browse-root]、--primary 配合扫描或浏览目录、--set-browse-root 或 --restore-state 中的一种形式"))
	}
	legacy := setupLegacyPath(fs)
	var result agentsetup.WorkspaceConfigurationResult
	var err error
	if *restore != "" {
		var receipt struct {
			Previous *agentsetup.WorkspaceState `json:"previous"`
			Applied  *agentsetup.WorkspaceState `json:"applied"`
		}
		if err := json.Unmarshal([]byte(*restore), &receipt); err != nil {
			return invalidOnboardingRequest(err)
		}
		if receipt.Previous == nil || receipt.Applied == nil {
			return invalidOnboardingRequest(fmt.Errorf("目录恢复记录不完整"))
		}
		result, err = agentsetup.EditWorkspace(*path, legacy, selection, &agentsetup.WorkspaceConfigurationResult{Previous: *receipt.Previous, Applied: *receipt.Applied})
	} else {
		result, err = agentsetup.EditWorkspace(*path, legacy, selection, nil)
		if hasRoot && err != nil {
			return moduleConfigFailure(*path, workspaceFailure(*root, err))
		}
	}
	if err != nil {
		return moduleConfigFailure(*path, err)
	}
	if *asJSON {
		return printJSONTo(stdout, result)
	}
	fmt.Fprintln(stdout, "代码目录已保存，重启服务后生效。")
	return nil
}
