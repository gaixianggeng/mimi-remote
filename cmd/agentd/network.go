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

func runNetwork(args []string) error { return runNetworkWithWriters(args, os.Stdout, os.Stderr) }

func runNetworkWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("network", flag.ContinueOnError)
	fs.SetOutput(stderr)
	path := fs.String("config", config.DefaultPath(), "配置文件路径")
	lan := fs.Bool("lan-enabled", false, "是否允许 Mimi 局域网访问")
	tailscale := fs.Bool("tailscale-enabled", false, "是否允许 Mimi Tailscale 访问")
	restore := fs.String("restore-state", "", "恢复先前连接设置的事务结果 JSON")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	module, count := "", 0
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "lan-enabled":
			module = "lan"
			count++
		case "tailscale-enabled":
			module = "tailscale"
			count++
		case "restore-state":
			count++
		}
	})
	if count != 1 {
		return fmt.Errorf("必须且只能传入 --lan-enabled、--tailscale-enabled 或 --restore-state 之一")
	}
	if err := prepareDefaultConfigMigration(fs, *path, stderr); err != nil {
		return err
	}
	var result agentsetup.NetworkConfigurationResult
	var err error
	if *restore != "" {
		var previous agentsetup.NetworkConfigurationResult
		if err = json.Unmarshal([]byte(*restore), &previous); err != nil {
			return err
		}
		if previous.Previous.AllowLAN {
			if err := ensurePlatformLANAccessAllowed(); err != nil {
				return err
			}
		}
		result, err = agentsetup.RestoreNetworkAccess(*path, previous)
	} else {
		enabled := *tailscale
		if module == "lan" {
			enabled = *lan
		}
		if module == "lan" && enabled {
			if err := ensurePlatformLANAccessAllowed(); err != nil {
				return err
			}
		}
		result, err = agentsetup.ConfigureNetworkAccess(*path, module, enabled)
	}
	if err != nil {
		return err
	}
	if *asJSON {
		return printJSONTo(stdout, result)
	}
	fmt.Fprintf(stdout, "Mimi 连接设置：Tailscale=%t，局域网=%t\n", result.TailscaleEnabled, result.LANEnabled)
	if result.RestartRequired {
		fmt.Fprintln(stdout, "配置已保存，重启 agentd 后生效。")
	}
	return nil
}
