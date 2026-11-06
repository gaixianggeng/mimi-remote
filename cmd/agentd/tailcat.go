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
	Mode              string `json:"mode"`
	Running           bool   `json:"running"`
	Version           string `json:"version,omitempty"`
	DERPMapURL        string `json:"derp_map_url,omitempty"`
	Address           string `json:"address,omitempty"`
	PublicKey         string `json:"public_key,omitempty"`
	MacInstallationID string `json:"mac_installation_id,omitempty"`
	PairAddress       string `json:"pair_address,omitempty"`
	PairPublicKey     string `json:"pair_public_key,omitempty"`
	PairExpiresAt     string `json:"pair_expires_at,omitempty"`
	PairedDeviceCount int    `json:"paired_device_count"`
	Error             string `json:"error,omitempty"`
	FreePairAddress   string `json:"free_pair_address,omitempty"`
}

func runTailcat(args []string) error {
	return runTailcatWithWriters(args, os.Stdout, os.Stderr)
}

func runTailcatWithWriters(args []string, stdout io.Writer, stderr io.Writer) error {
	if len(args) < 2 {
		return errors.New("tailcat 需要子命令：status、enable、disable、pair、reset、configure、enter-managed、exit-managed 或 relay-set")
	}
	action := strings.ToLower(strings.TrimSpace(args[1]))
	if action == "relay" {
		if len(args) < 3 || args[2] != "set" {
			return errors.New("用法：tailcat relay set --choice default|custom|mimi [--derp-map-url <地址>] --json")
		}
		// 对外使用分层命令；内部 HTTP action 与早期草稿别名保持兼容。
		args = append([]string{args[0], "relay-set"}, args[3:]...)
		action = "relay-set"
	}
	switch action {
	case "status", "enable", "disable", "pair", "reset", "configure", "enter-managed", "exit-managed", "relay-set":
	default:
		return fmt.Errorf("未知 Tailcat 子命令 %q", action)
	}

	fs := flag.NewFlagSet("tailcat "+action, flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	asJSON := fs.Bool("json", false, "输出 JSON")
	qrOnly := fs.Bool("qr-only", false, "配对时只输出短期配对信息")
	derpMapURL := fs.String("derp-map-url", "", "自定义 DERP Map HTTPS URL；空值恢复 Tailcat 默认中继")
	choice := fs.String("choice", "", "relay-set 的中转选择：default、custom 或 mimi")
	if err := fs.Parse(args[2:]); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("tailcat 子命令不接受多余的位置参数")
	}
	derpMapURLSet := false
	choiceSet := false
	fs.Visit(func(current *flag.Flag) {
		switch current.Name {
		case "derp-map-url":
			derpMapURLSet = true
		case "choice":
			choiceSet = true
		}
	})
	if *qrOnly && action != "pair" {
		return errors.New("--qr-only 只适用于 tailcat pair")
	}
	if action == "configure" && !derpMapURLSet {
		return errors.New("tailcat configure 必须显式提供 --derp-map-url；使用 --derp-map-url= 恢复默认中继")
	}
	if action != "configure" && action != "relay-set" && derpMapURLSet {
		return errors.New("--derp-map-url 只适用于 tailcat configure 和 tailcat relay-set")
	}
	if action != "relay-set" && choiceSet {
		return errors.New("--choice 只适用于 tailcat relay-set")
	}
	if action == "relay-set" && !choiceSet {
		return errors.New("tailcat relay-set 必须提供 --choice=default|custom|mimi")
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, stderr); err != nil {
		return err
	}
	cfg, err := config.LoadForDoctor(*configPath)
	if err != nil {
		return err
	}
	status, err := requestTailcatControl(context.Background(), *configPath, cfg, action, *derpMapURL, *choice)
	if err != nil {
		return err
	}
	if action == "pair" {
		// 只有托管模式的二维码才带托管字段。自建模式带上它们，iOS 会先向云端
		// 预留电脑名额，到 claim 时才被拒绝。
		macInstallationID, macPublicKey, pairPublicKey, freePairAddress := "", "", "", ""
		if status.Mode == config.TailcatModeManaged {
			macInstallationID, macPublicKey, pairPublicKey = status.MacInstallationID, status.PublicKey, status.PairPublicKey
			freePairAddress = status.FreePairAddress
		}
		result, err := agentsetup.TailcatPairWithManagedHost(
			*configPath,
			status.PairAddress,
			macInstallationID,
			macPublicKey,
			pairPublicKey,
			freePairAddress,
		)
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

func requestTailcatControl(
	ctx context.Context,
	configPath string,
	cfg config.Config,
	action string,
	derpMapURL string,
	choice string,
) (tailcatCommandStatus, error) {
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
		payload := map[string]string{"action": action}
		if action == "configure" {
			payload["derp_map_url"] = derpMapURL
		}
		if action == "relay-set" {
			payload["choice"] = strings.TrimSpace(choice)
			payload["derp_map_url"] = derpMapURL
		}
		encoded, encodeErr := json.Marshal(payload)
		if encodeErr != nil {
			return tailcatCommandStatus{}, encodeErr
		}
		body = bytes.NewReader(encoded)
	}
	timeout := 25 * time.Second
	if action == "configure" || action == "enter-managed" || action == "exit-managed" || action == "relay-set" {
		// 切换中继会验证新 sidecar，并在失败时恢复旧 sidecar。relay-set 把
		// 这几步串起来，预算要比单步更宽。
		timeout = 50 * time.Second
	}
	requestCtx, cancel := context.WithTimeout(ctx, timeout)
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
	response, err := (&http.Client{Timeout: timeout}).Do(req)
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
	mode := "免费线路"
	if status.Mode == config.TailcatModeManaged {
		mode = "托管 + 免费线路"
	}
	fmt.Fprintf(w, "线路：%s\n", mode)
	if status.Version != "" {
		fmt.Fprintf(w, "版本：%s\n", status.Version)
	}
	if status.DERPMapURL == "" {
		fmt.Fprintln(w, "中继：Tailcat 默认")
	} else {
		fmt.Fprintf(w, "中继：%s\n", status.DERPMapURL)
	}
	fmt.Fprintf(w, "已配对设备：%d\n", status.PairedDeviceCount)
	if status.Error != "" {
		fmt.Fprintf(w, "问题：%s\n", status.Error)
	}
}
