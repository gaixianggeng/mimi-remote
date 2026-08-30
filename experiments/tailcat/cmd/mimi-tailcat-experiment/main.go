package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Tailcat 实验失败："+err.Error())
		os.Exit(1)
	}
}

func run(arguments []string) error {
	if len(arguments) == 0 {
		return errors.New("需要子命令：client-key、host 或 forward")
	}
	switch arguments[0] {
	case "client-key":
		return runClientKey(arguments[1:])
	case "host":
		return runHost(arguments[1:])
	case "forward":
		return runForward(arguments[1:])
	default:
		return fmt.Errorf("未知子命令 %q", arguments[0])
	}
}

func runClientKey(arguments []string) error {
	flags := flag.NewFlagSet("client-key", flag.ContinueOnError)
	identityPath := flags.String("identity", "", "客户端身份文件")
	publicKeyPath := flags.String("public-key", "", "客户端公钥输出文件")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *identityPath == "" || *publicKeyPath == "" {
		return errors.New("client-key 需要 --identity 和 --public-key")
	}
	privateKey, err := tunnel.LoadOrCreateClientIdentity(*identityPath)
	if err != nil {
		return err
	}
	if err := writePrivateText(*publicKeyPath, privateKey.Public().String()); err != nil {
		return err
	}
	fmt.Printf("客户端公钥已写入 %s\n", *publicKeyPath)
	return nil
}

func runHost(arguments []string) error {
	flags := flag.NewFlagSet("host", flag.ContinueOnError)
	target := flags.String("target", "127.0.0.1:8787", "本机 agentd 地址")
	port := flags.Uint("port", 8787, "Tailcat 远端端口")
	identityPath := flags.String("identity", "", "服务端身份文件")
	addressPath := flags.String("address", "", "Tailcat 地址输出文件")
	allowedClientPath := flags.String("allow", "", "允许连接的客户端公钥文件")
	derpMapURL := flags.String("derpmap-url", "", "可选 DERP Map URL")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *port == 0 || *port > 65535 {
		return fmt.Errorf("--port 超出范围：%d", *port)
	}
	if *identityPath == "" || *addressPath == "" || *allowedClientPath == "" {
		return errors.New("host 需要 --identity、--address 和 --allow")
	}
	allowedClient, err := readPrivateText(*allowedClientPath)
	if err != nil {
		return err
	}
	host, err := tunnel.StartHost(tunnel.HostConfig{
		TargetAddr:       *target,
		RemotePort:       uint16(*port),
		IdentityPath:     *identityPath,
		AddressPath:      *addressPath,
		AllowedClientKey: allowedClient,
		DERPMapURL:       *derpMapURL,
	})
	if err != nil {
		return err
	}
	defer host.Close()
	fmt.Printf("Tailcat 服务端已启动，连接地址保存在 %s\n", *addressPath)
	waitForSignal()
	return nil
}

func runForward(arguments []string) error {
	flags := flag.NewFlagSet("forward", flag.ContinueOnError)
	addressPath := flags.String("address", "", "Tailcat 地址文件")
	identityPath := flags.String("identity", "", "客户端身份文件")
	endpointPath := flags.String("endpoint", "", "本地 HTTP 端点输出文件")
	listen := flags.String("listen", "127.0.0.1:0", "本地监听地址")
	port := flags.Uint("port", 8787, "Tailcat 远端端口")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *port == 0 || *port > 65535 {
		return fmt.Errorf("--port 超出范围：%d", *port)
	}
	if *addressPath == "" || *identityPath == "" {
		return errors.New("forward 需要 --address 和 --identity")
	}
	address, err := readPrivateText(*addressPath)
	if err != nil {
		return err
	}
	forwarder, err := tunnel.StartForwarder(context.Background(), tunnel.ForwarderConfig{
		Address:      address,
		RemotePort:   uint16(*port),
		ListenAddr:   *listen,
		IdentityPath: *identityPath,
		EndpointPath: *endpointPath,
	})
	if err != nil {
		return err
	}
	defer forwarder.Close()
	fmt.Printf("Tailcat 本地转发已启动：%s\n", forwarder.Endpoint())
	waitForSignal()
	return nil
}

func waitForSignal() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	<-ctx.Done()
}

func readPrivateText(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("读取 %s：%w", path, err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return "", fmt.Errorf("文件 %s 的权限必须为 0600", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("读取 %s：%w", path, err)
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "", fmt.Errorf("文件 %s 不能为空", path)
	}
	return value, nil
}

func writePrivateText(path, value string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("创建 %s 的目录：%w", path, err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("写入 %s：%w", path, err)
	}
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return fmt.Errorf("设置 %s 权限：%w", path, err)
	}
	if _, err := fmt.Fprintln(file, value); err != nil {
		file.Close()
		return fmt.Errorf("写入 %s：%w", path, err)
	}
	return file.Close()
}
