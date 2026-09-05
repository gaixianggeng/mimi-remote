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
	cmd := exec.CommandContext(ctx, c.agentPath, args...)
	cmd.Dir = filepath.Dir(c.agentPath) // release/worktree directories may be removed after launch.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	stdout := &boundedTrayOutput{remaining: 1024 * 1024}
	stderr := &boundedTrayOutput{remaining: 64 * 1024}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	if ctx.Err() != nil {
		return nil, errors.New("agentd 操作超时或已取消，请刷新状态后重试")
	}
	if stdout.truncated {
		return nil, errors.New("agentd 输出过大，请使用本机诊断工具检查")
	}
	if err != nil {
		return stdout.Bytes(), fmt.Errorf("agentd %s 失败：%s", args[0], fallbackText(redactTrayText(stderr.String()), "请运行诊断或查看日志"))
	}
	return stdout.Bytes(), nil
}

type boundedTrayOutput struct {
	bytes.Buffer
	remaining int
	truncated bool
}

func (b *boundedTrayOutput) Write(p []byte) (int, error) {
	n := len(p)
	if len(p) > b.remaining {
		p = p[:b.remaining]
		b.truncated = true
	}
	_, _ = b.Buffer.Write(p)
	b.remaining -= len(p)
	return n, nil
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
	PairURL       string `json:"pair_url"`
	PairExpiresAt string `json:"pair_expires_at"`
}

func (c *linuxController) pairing(ctx context.Context) (linuxPairingInfo, error) {
	payload, err := c.runner(ctx, "pair", "--qr-only", "--json")
	if err != nil {
		return linuxPairingInfo{}, err
	}
	var result linuxPairingInfo
	if json.Unmarshal(payload, &result) != nil {
		return result, errors.New("无法读取短期配对信息")
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
		lines[i] = trayURLCredential.ReplaceAllString(line, "[已隐藏带凭据的地址]")
	}
	return strings.Join(lines, "\n")
}
