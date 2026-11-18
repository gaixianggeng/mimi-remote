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
	restore := fs.String("restore-state", "", "恢复先前目录设置事务 JSON")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 0 || (*root == "") == (*restore == "") {
		return fmt.Errorf("必须且只能传入 --root 或 --restore-state，不能带位置参数")
	}
	if err := prepareDefaultConfigMigration(fs, *path, stderr); err != nil {
		return err
	}
	var result agentsetup.WorkspaceConfigurationResult
	var err error
	if *restore != "" {
		var previous agentsetup.WorkspaceConfigurationResult
		if err := json.Unmarshal([]byte(*restore), &previous); err != nil {
			return err
		}
		result, err = agentsetup.RestoreWorkspace(*path, previous)
	} else {
		result, err = agentsetup.ConfigureWorkspace(*path, *root)
	}
	if err != nil {
		return err
	}
	if *asJSON {
		return printJSONTo(stdout, result)
	}
	fmt.Fprintln(stdout, "代码目录已保存，重启服务后生效。")
	return nil
}
