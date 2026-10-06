package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func runDiagnostics(args []string) error {
	return runDiagnosticsWithWriter(args, os.Stdout)
}

func runDiagnosticsWithWriter(args []string, output io.Writer) error {
	if len(args) < 2 {
		return errors.New("用法：agentd diagnostics status|start|stop|clear|export --json")
	}
	action := args[1]
	method := http.MethodPost
	switch action {
	case "status", "export":
		method = http.MethodGet
	case "start", "stop", "clear":
	default:
		return errors.New("未知诊断日志操作")
	}
	fs := flag.NewFlagSet("diagnostics", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	fs.Bool("json", false, "以 JSON 输出诊断结果")
	if fs.Parse(args[2:]) != nil || fs.NArg() > 0 {
		return errors.New("诊断日志命令参数无效")
	}
	cfg, err := config.LoadForDoctor(*configPath)
	if err != nil {
		return errors.New("无法读取本机服务配置")
	}
	_, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return errors.New("本机服务端口无效")
	}
	token, err := diagnosticControlToken(*configPath, false)
	if err != nil {
		return errors.New("无法读取本机诊断凭据，请确认服务已启动并检查文件权限")
	}
	// 按服务的实际监听策略选择回环地址，兼容 IPv6 及模块开关重建监听。
	// 只接受字面回环 IP；其它情况走本机 IPv4，不能向远端地址发送本机凭据。
	loopback := "127.0.0.1"
	for _, address := range moduleListenAddresses(cfg) {
		host, _, _ := net.SplitHostPort(address)
		if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
			loopback = ip.String()
			break
		}
	}
	target := "http://" + net.JoinHostPort(loopback, port) + "/api/local/diagnostics/" + action
	req, err := http.NewRequest(method, target, nil)
	if err != nil {
		return errors.New("无法建立本机诊断请求")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	client := &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return errors.New("无法连接本机服务，请确认服务已启动")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("本机诊断日志操作失败（HTTP %d），请检查服务版本和状态", resp.StatusCode)
	}
	decoder := json.NewDecoder(io.LimitReader(resp.Body, 32<<20))
	var value json.RawMessage
	if err := decoder.Decode(&value); err != nil {
		return errors.New("本机诊断响应无效")
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return errors.New("本机诊断响应包含多余内容")
	}
	_, err = fmt.Fprintln(output, string(value))
	return err
}
