package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

type tailcatCommandStatus struct {
	Enabled           bool   `json:"enabled"`
	Running           bool   `json:"running"`
	Version           string `json:"version,omitempty"`
	Address           string `json:"address,omitempty"`
	PairAddress       string `json:"pair_address,omitempty"`
	PairExpiresAt     string `json:"pair_expires_at,omitempty"`
	PairedDeviceCount int    `json:"paired_device_count"`
	Error             string `json:"error,omitempty"`
}

func runTailcat(args []string) error {
	return runTailcatWithWriters(args, os.Stdout, os.Stderr)
}

func runTailcatWithWriters(args []string, stdout io.Writer, stderr io.Writer) error {
	if len(args) < 2 {
		return errors.New("tailcat 需要子命令：status、enable、disable、pair 或 reset")
	}
	action := strings.ToLower(strings.TrimSpace(args[1]))
	switch action {
	case "status", "enable", "disable", "pair", "reset":
	default:
		return fmt.Errorf("未知 Tailcat 子命令 %q", action)
	}

	fs := flag.NewFlagSet("tailcat "+action, flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	asJSON := fs.Bool("json", false, "输出 JSON")
	qrOnly := fs.Bool("qr-only", false, "配对时只输出短期配对信息")
	if err := fs.Parse(args[2:]); err != nil {
		return err
	}
	if *qrOnly && action != "pair" {
		return errors.New("--qr-only 只适用于 tailcat pair")
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, stderr); err != nil {
		return err
	}
	cfg, err := config.LoadForDoctor(*configPath)
	if err != nil {
		return err
	}
	status, err := requestTailcatControl(context.Background(), *configPath, cfg, action)
	if err != nil {
		return err
	}
	if action == "pair" {
		result, err := agentsetup.TailcatPair(*configPath, status.PairAddress)
		if err != nil {
			return err
		}
		if *asJSON {
			return printJSONTo(stdout, qrOnlyPairResult(result))
		}
		printQROnlyPairResult(stdout, result)
		return nil
	}
	if *asJSON {
		return printJSONTo(stdout, status)
	}
	printTailcatStatus(stdout, status)
	return nil
}

func requestTailcatControl(ctx context.Context, configPath string, cfg config.Config, action string) (tailcatCommandStatus, error) {
	localToken, err := httpapi.ReadTailcatLocalControlToken(configPath)
	if err != nil {
		return tailcatCommandStatus{}, fmt.Errorf("Tailcat 本机控制尚未就绪，请先启动 agentd：%w", err)
	}
	result := agentsetup.ResultFromConfig(ctx, configPath, cfg)
	controlURL, err := serviceCheckURL(loopbackServiceEndpoint(result.Endpoint), "/api/local/tailcat")
	if err != nil {
		return tailcatCommandStatus{}, err
	}
	method := http.MethodPost
	var body io.Reader
	if action == "status" {
		method = http.MethodGet
	} else {
		encoded, encodeErr := json.Marshal(map[string]string{"action": action})
		if encodeErr != nil {
			return tailcatCommandStatus{}, encodeErr
		}
		body = bytes.NewReader(encoded)
	}
	requestCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(requestCtx, method, controlURL, body)
	if err != nil {
		return tailcatCommandStatus{}, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(cfg.Auth.Token))
	req.Header.Set(httpapi.TailcatLocalControlHeader, localToken)
	response, err := (&http.Client{Timeout: 25 * time.Second}).Do(req)
	if err != nil {
		return tailcatCommandStatus{}, fmt.Errorf("连接本机 agentd 失败：%w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Error string `json:"error"`
		}
		_ = json.NewDecoder(io.LimitReader(response.Body, 32<<10)).Decode(&failure)
		if strings.TrimSpace(failure.Error) == "" {
			failure.Error = fmt.Sprintf("agentd 返回 HTTP %d", response.StatusCode)
		}
		return tailcatCommandStatus{}, errors.New(failure.Error)
	}
	var status tailcatCommandStatus
	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&status); err != nil {
		return tailcatCommandStatus{}, fmt.Errorf("解析 Tailcat 状态失败：%w", err)
	}
	return status, nil
}

func printTailcatStatus(w io.Writer, status tailcatCommandStatus) {
	state := "关闭"
	if status.Enabled && status.Running {
		state = "运行中"
	} else if status.Enabled {
		state = "需要处理"
	}
	fmt.Fprintf(w, "Tailcat 实验：%s\n", state)
	if status.Version != "" {
		fmt.Fprintf(w, "版本：%s\n", status.Version)
	}
	fmt.Fprintf(w, "已配对设备：%d\n", status.PairedDeviceCount)
	if status.Error != "" {
		fmt.Fprintf(w, "问题：%s\n", status.Error)
	}
}
