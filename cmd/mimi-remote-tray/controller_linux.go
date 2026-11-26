//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Matches contracts/host-cli/onboarding-codes-v1.json (wait=60s within BE<=85s
// and Linux tray client timeout>=110s).
const linuxServiceReadyWait = 60 * time.Second

type linuxController struct {
	agentPath  string
	runner     func(context.Context, ...string) ([]byte, error)
	stateMu    sync.RWMutex
	configured bool
}

func (c *linuxController) setConfigured(value bool) {
	c.stateMu.Lock()
	c.configured = value
	c.stateMu.Unlock()
}

func (c *linuxController) isConfigured() bool {
	c.stateMu.RLock()
	defer c.stateMu.RUnlock()
	return c.configured
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
	stdout, stderr, stdoutTruncated, err := runTrayCommand(cmd, progress, generation, onProgress, 1024*1024, 64*1024)
	if errors.Is(ctx.Err(), context.Canceled) {
		return nil, context.Canceled
	}
	if ctx.Err() != nil {
		return nil, newTrayUILocalError("command_timeout", trayActiveStepForArgs(args))
	}
	if stdoutTruncated {
		return nil, errors.New("agentd 输出过大，请使用本机诊断工具检查")
	}
	if err != nil {
		if cliErr := decodeTrayCommandError(stdout, stderr, err, trayValidationContextForArgs("linux", args, c.isConfigured()), args...); cliErr != nil {
			return stdout, cliErr
		}
		return stdout, newTrayUnknownCommandError(err, trayActiveStepForArgs(args))
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
	report, err := runTrayPreflight(ctx, "linux", stage, progress, generation, onProgress, c.runWithProgress, extraArgs...)
	if err == nil && report.Configured != nil {
		c.setConfigured(*report.Configured)
	}
	return report, err
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
	status, err := parseAgentStatus(payload)
	if err != nil {
		return agentStatus{}, err
	}
	c.setConfigured(true)
	return status, nil
}

func (c *linuxController) action(ctx context.Context, action string) (string, error) {
	var args []string
	switch action {
	case "start", "restart":
		args = []string{action, "--wait", strconv.Itoa(int(linuxServiceReadyWait/time.Second)) + "s", "--no-pair"}
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
	// Failed service commands may put a private error envelope on stdout.
	// Keep the legacy read-only doctor report visible when it reports a problem.
	if err != nil && action != "logs" {
		if action != "doctor" {
			return "", err
		}
		var report struct {
			Checks []json.RawMessage `json:"checks"`
			Error  json.RawMessage   `json:"error"`
		}
		if json.Unmarshal(payload, &report) != nil || report.Checks == nil || report.Error != nil {
			return "", err
		}
	}
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
	var keys map[string]json.RawMessage
	var result linuxPairingInfo
	if json.Unmarshal(payload, &keys) != nil || json.Unmarshal(payload, &result) != nil {
		return linuxPairingInfo{}, errors.New("无法读取短期配对信息")
	}
	if !supportedOnboardingSchema(keys) {
		return linuxPairingInfo{}, errors.New("无法读取短期配对信息")
	}
	if _, v1 := keys["ok"]; v1 {
		if _, err := decodeOnboardingPairingTicketReceipt(payload, true); err != nil {
			return linuxPairingInfo{}, errors.New("无法读取短期配对信息")
		}
	}
	u, err := url.Parse(result.PairURL)
	expires, dateErr := time.Parse(time.RFC3339Nano, result.PairExpiresAt)
	if dateErr != nil {
		expires, dateErr = time.Parse(time.RFC3339, result.PairExpiresAt)
	}
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
