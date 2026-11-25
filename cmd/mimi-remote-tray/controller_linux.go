//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

type linuxController struct {
	agentPath string
	runner    func(context.Context, ...string) ([]byte, error)
}

func newLinuxController(agentPath string) (*linuxController, error) {
	if agentPath == "" {
		executable, err := os.Executable()
		if err != nil {
			return nil, err
		}
		agentPath = filepath.Join(filepath.Dir(executable), "agentd")
	}
	path, err := filepath.Abs(agentPath)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return nil, errors.New("安装目录缺少可执行的 agentd，请重新安装 Linux 发布包")
	}
	c := &linuxController{agentPath: path}
	c.runner = c.run
	return c, nil
}

// The CLI is the only service/configuration owner. Never invoke a shell or read
// long-lived credentials into the tray process.
func (c *linuxController) run(ctx context.Context, args ...string) ([]byte, error) {
	return c.runWithProgress(ctx, nil, 0, nil, args...)
}

func (c *linuxController) runWithProgress(
	ctx context.Context,
	progress *onboardingProgressAccumulator,
	generation uint64,
	onProgress func(onboardingCheck),
	args ...string,
) ([]byte, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, trayCommandTimeout("linux", args...))
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, c.agentPath, args...)
	cmd.Dir = filepath.Dir(c.agentPath) // release/worktree directories may be removed after launch.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	stdout, stderr, stdoutTruncated, err := runTrayCommand(cmd, progress, generation, onProgress, 1024*1024, 64*1024)
	if ctx.Err() != nil {
		return nil, newTrayUILocalError("command_timeout", trayActiveStepForArgs(args), "")
	}
	if stdoutTruncated {
		return nil, errors.New("agentd 输出过大，请使用本机诊断工具检查")
	}
	if err != nil {
		if cliErr := decodeTrayCommandError(stdout, stderr, err, trayValidationContextForArgs("linux", args)); cliErr != nil {
			return stdout, cliErr
		}
		return stdout, newTrayUnknownCommandError(err, trayActiveStepForArgs(args), string(stderr))
	}
	return stdout, nil
}

func (c *linuxController) preflight(
	ctx context.Context,
	stage string,
	progress *onboardingProgressAccumulator,
	generation uint64,
	onProgress func(onboardingCheck),
	extraArgs ...string,
) (onboardingPreflightReport, error) {
	if stage != "setup" && stage != "pair" {
		return onboardingPreflightReport{}, fmt.Errorf("不支持的预检阶段：%q", stage)
	}
	if progress == nil {
		configured := false
		progress = newOnboardingProgressAccumulatorWithContext(generation, onboardingValidationContext{
			Surface:    "check",
			Platform:   "linux",
			Stage:      stage,
			Configured: &configured,
		})
	}
	args := append([]string{"preflight", "--json", "--stage", stage, "--progress-json"}, extraArgs...)
	payload, err := c.runWithProgress(ctx, progress, generation, onProgress, args...)
	if err != nil {
		return onboardingPreflightReport{}, err
	}
	report, err := decodeAndValidatePreflightReportForStage(payload, "linux", stage, false, "")
	if err != nil {
		return onboardingPreflightReport{}, fmt.Errorf("无法解析预检报告：%w", err)
	}
	progress.Complete(generation, report)
	return report, nil
}

func (c *linuxController) status(ctx context.Context, refresh bool) (agentStatus, error) {
	args := []string{"status", "--json", "--runtime"}
	if refresh {
		args = append(args, "--runtime-refresh")
	}
	payload, err := c.runner(ctx, args...)
	if err != nil {
		return agentStatus{}, err
	}
	return parseAgentStatus(payload)
}

func (c *linuxController) action(ctx context.Context, action string) (string, error) {
	var args []string
	switch action {
	case "start", "restart":
		args = []string{action, "--wait", "20s", "--no-pair"}
	case "stop":
		args = []string{"stop"}
	case "doctor":
		args = []string{"doctor", "--json"}
	case "logs":
		args = []string{"logs", "-n", "200"}
	case "tailcat-enable":
		args = []string{"tailcat", "enable", "--json"}
	case "tailcat-disable":
		args = []string{"tailcat", "disable", "--json"}
	case "tailcat-enter-managed":
		args = []string{"tailcat", "enter-managed", "--json"}
	case "tailcat-exit-managed":
		args = []string{"tailcat", "exit-managed", "--json"}
	default:
		return "", errors.New("不支持的操作")
	}
	payload, err := c.runner(ctx, args...)
	// Diagnostic data is displayed, never parsed as an unstable command result.
	// The doctor contract uses JSON and may exit unsuccessfully with valid results.
	if action == "doctor" {
		var pretty bytes.Buffer
		if json.Indent(&pretty, payload, "", "  ") == nil {
			payload = pretty.Bytes()
		}
	}
	return redactTrayText(string(payload)), err
}

type linuxPairingInfo struct {
	OK            *bool  `json:"ok,omitempty"`
	PairURL       string `json:"pair_url"`
	PairExpiresAt string `json:"pair_expires_at"`
}

func (c *linuxController) pairing(ctx context.Context, network string) (linuxPairingInfo, error) {
	var args []string
	switch network {
	case "tailcat":
		args = []string{"tailcat", "pair", "--qr-only", "--json"}
	case "tailscale", "lan":
		args = []string{"pair", "--network", network, "--qr-only", "--json"}
	default:
		return linuxPairingInfo{}, errors.New("请选择 Tailcat、Tailscale 或局域网配对")
	}
	payload, err := c.runner(ctx, args...)
	if err != nil {
		return linuxPairingInfo{}, err
	}
	var result linuxPairingInfo
	if json.Unmarshal(payload, &result) != nil {
		return result, errors.New("无法读取短期配对信息")
	}
	if result.OK != nil && !*result.OK {
		return linuxPairingInfo{}, errors.New("短期配对信息返回失败状态")
	}
	u, err := url.Parse(result.PairURL)
	expires, dateErr := time.Parse(time.RFC3339, result.PairExpiresAt)
	if err != nil || u.Scheme != "mimiremote" || u.Host != "pair" ||
		u.Query().Get("pair_sig") == "" || u.Query().Get("token") != "" ||
		u.Query().Get("issued_at") == "" ||
		dateErr != nil || !expires.After(time.Now()) || len(result.PairURL) > 8192 {
		return linuxPairingInfo{}, errors.New("配对票据无效或已过期，请重新生成")
	}
	// agentd's outer timestamp has second precision, while its signed URL
	// preserves nanoseconds. Compare instants at the documented outer precision.
	ticketExpiry, ticketErr := time.Parse(time.RFC3339Nano, u.Query().Get("expires_at"))
	if ticketErr != nil || !ticketExpiry.Truncate(time.Second).Equal(expires.Truncate(time.Second)) || !ticketExpiry.After(time.Now()) {
		return linuxPairingInfo{}, errors.New("配对票据有效期不一致或已过期")
	}
	result.PairExpiresAt = ticketExpiry.Format(time.RFC3339Nano)
	if network == "tailcat" && (u.Query().Get("transport") != "tailcat" || u.Query().Get("tailcat_pair_address") == "") {
		return linuxPairingInfo{}, errors.New("Tailcat 配对信息缺少内置连接地址")
	}
	if network != "tailcat" && u.Query().Get("transport") == "tailcat" {
		return linuxPairingInfo{}, errors.New("配对网络与所选方式不一致")
	}
	return result, nil
}

// Read only the public status fields, never configuration or private keys.
type linuxTailcatStatus struct {
	Enabled           bool   `json:"enabled"`
	Mode              string `json:"mode"`
	Running           bool   `json:"running"`
	PairedDeviceCount int    `json:"paired_device_count"`
	Error             string `json:"error"`
}

func (c *linuxController) tailcatStatus(ctx context.Context) (linuxTailcatStatus, error) {
	data, err := c.runner(ctx, "tailcat", "status", "--json")
	if err != nil {
		return linuxTailcatStatus{}, err
	}
	var result linuxTailcatStatus
	var contract map[string]json.RawMessage
	if json.Unmarshal(data, &result) != nil || json.Unmarshal(data, &contract) != nil || contract["enabled"] == nil || contract["running"] == nil {
		return result, errors.New("agentd 未提供 Tailcat 状态，请更新 agentd")
	}
	return result, nil
}

var traySecretLine = regexp.MustCompile(`(?i)(token|secret|password|authorization|capability|pair_sig|private[_ -]?key|bearer\s|mimiremote://)`)
var trayURLCredential = regexp.MustCompile(`(https?|wss?)://[^\s/@]+:[^\s/@]+@[^\s]+`)

func redactTrayText(text string) string {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		if traySecretLine.MatchString(line) {
			lines[i] = "[已隐藏包含凭据的内容]"
			continue
		}
		lines[i] = scrubTraySensitiveText(trayURLCredential.ReplaceAllString(line, "[已隐藏带凭据的地址]"))
	}
	return strings.Join(lines, "\n")
}
