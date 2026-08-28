package main

import (
	"flag"
	"fmt"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

func runRemoteToken(args []string) error {
	fs := flag.NewFlagSet("remote-token", flag.ContinueOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 1 || fs.Arg(0) != "rotate" {
		return fmt.Errorf("用法：agentd remote-token [--config PATH] rotate")
	}
	path, err := agentsetup.RotateRemoteGatewayTokenFile(*configPath)
	if err != nil {
		return err
	}
	fmt.Printf("已原子轮换 remote gateway token：%s\n", path)
	return nil
}
