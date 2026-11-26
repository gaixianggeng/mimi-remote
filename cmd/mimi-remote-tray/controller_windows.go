//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	runtimebudget "github.com/gaixianggeng/mimi-remote/internal/runtimestatus"
)

const (
	createNoWindow        = 0x08000000
	seeMaskNoCloseProcess = 0x00000040
	swShowNormal          = 1
	waitObject0           = 0
	waitFailed            = 0xFFFFFFFF
	infiniteWait          = 0xFFFFFFFF
)

var (
	trayShell32             = syscall.NewLazyDLL("shell32.dll")
	trayKernel32            = syscall.NewLazyDLL("kernel32.dll")
	procTrayShellExecuteExW = trayShell32.NewProc("ShellExecuteExW")
	procTrayWaitForSingle   = trayKernel32.NewProc("WaitForSingleObject")
	procTrayCloseHandle     = trayKernel32.NewProc("CloseHandle")
)

type shellExecuteInfo struct {
	Size          uint32
	Mask          uint32
	Window        uintptr
	Verb          *uint16
	File          *uint16
	Parameters    *uint16
	Directory     *uint16
	Show          int32
	Instance      uintptr
	IDList        uintptr
	Class         *uint16
	ClassKey      uintptr
	HotKey        uint32
	IconOrMonitor uintptr
	Process       uintptr
}

type terminalProcess struct {
	handle     uintptr
	scriptPath string
}

func (p *terminalProcess) Wait() error {
	if p == nil || p.handle == 0 {
		return errors.New("终端进程句柄不可用")
	}
	result, _, waitErr := procTrayWaitForSingle.Call(p.handle, infiniteWait)
	procTrayCloseHandle.Call(p.handle)
	if p.scriptPath != "" {
		_ = os.Remove(p.scriptPath)
	}
	if result == waitObject0 {
		return nil
	}
	if result == waitFailed {
		return fmt.Errorf("等待终端进程失败：%v", waitErr)
	}
	return fmt.Errorf("等待终端进程返回意外状态：%d", result)
}

type agentController struct {
	agentPath          string
	trayPath           string
	statusGate         chan struct{}
	statusRunner       func(context.Context, ...string) ([]byte, error)
	commandRunner      func(context.Context, ...string) ([]byte, error)
	modifyResolver     func() (innoModifyTarget, error)
	modifyVerifier     func(candidatePath, currentExecutable string) error
	modifyRunner       func(context.Context, string, []string) error
	cachedNetwork      *networkStatus
	networkLastChecked time.Time
	stateMu            sync.RWMutex
	configured         bool
}

func (c *agentController) setConfigured(value bool) {
	c.stateMu.Lock()
	c.configured = value
	c.stateMu.Unlock()
}

func (c *agentController) isConfigured() bool {
	c.stateMu.RLock()
	defer c.stateMu.RUnlock()
	return c.configured
}

type pairingInfo struct {
	OK                  *bool    `json:"ok,omitempty"`
	Endpoint            string   `json:"endpoint"`
	Network             string   `json:"network,omitempty"`
	TailscaleDNSName    string   `json:"tailscale_dns_name,omitempty"`
	TailscaleDeviceName string   `json:"tailscale_device_name,omitempty"`
	PairURL             string   `json:"pair_url"`
	PairExpiresAt       string   `json:"pair_expires_at"`
	Warnings            []string `json:"warnings,omitempty"`
}

const networkPolicyRefreshInterval = 2 * time.Minute

func newAgentController() (*agentController, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("定位托盘程序失败：%w", err)
	}
	agentPath := filepath.Join(filepath.Dir(executable), "agentd.exe")
	info, err := os.Stat(agentPath)
	if err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("安装目录中缺少 agentd.exe：%s", agentPath)
	}
	return &agentController{
		agentPath:  agentPath,
		trayPath:   executable,
		statusGate: make(chan struct{}, 1),
	}, nil
}

func (c *agentController) status(ctx context.Context, refreshRuntime bool) (agentStatus, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	select {
	case c.statusGate <- struct{}{}:
		defer func() { <-c.statusGate }()
	case <-ctx.Done():
		return agentStatus{}, ctx.Err()
	}

	// 排队与执行使用独立预算。手动刷新取得执行权后，必须完整覆盖
	// runtime 的 10 秒探测以及计划任务、配置和网络状态读取。
	timeout := backgroundStatusCommandTimeout
	if refreshRuntime {
		timeout = manualStatusCommandTimeout
	}
	commandCtx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	inspectNetwork := c.cachedNetwork == nil ||
		time.Since(c.networkLastChecked) >= networkPolicyRefreshInterval
	args := statusArguments(refreshRuntime, inspectNetwork)
	runner := c.statusRunner
	if runner == nil {
		runner = c.runHidden
	}
	payload, err := runner(commandCtx, args...)
	if err != nil {
		return agentStatus{}, err
	}
	status, err := parseAgentStatus(payload)
	if err != nil {
		return agentStatus{}, err
	}
	c.setConfigured(true)
	if status.NetworkStatus != nil && status.NetworkStatus.PolicyChecked {
		snapshot := *status.NetworkStatus
		c.cachedNetwork = &snapshot
		c.networkLastChecked = time.Now()
	} else if c.cachedNetwork != nil && status.NetworkStatus != nil &&
		c.cachedNetwork.Mode == status.NetworkStatus.Mode &&
		c.cachedNetwork.AllowLAN == status.NetworkStatus.AllowLAN {
		snapshot := *c.cachedNetwork
		status.NetworkStatus = &snapshot
	} else if c.cachedNetwork != nil {
		// The configuration changed since the last full inspection. Do not show
		// stale policy data; force the next refresh to inspect the new mode.
		c.cachedNetwork = nil
		c.networkLastChecked = time.Time{}
	}
	return status, nil
}

func statusArguments(refreshRuntime bool, inspectNetwork bool) []string {
	arguments := []string{"status", "--json", "--runtime"}
	if refreshRuntime {
		arguments = append(arguments, "--runtime-refresh")
	}
	if inspectNetwork {
		arguments = append(arguments, "--network-policy")
	}
	return arguments
}

func (c *agentController) action(ctx context.Context, action string) error {
	_, err := c.runCommand(ctx, actionArguments(action)...)
	return err
}

func actionArguments(action string) []string {
	arguments := []string{action}
	if action == "start" || action == "restart" {
		arguments = append(arguments, "--wait", serviceReadyWait.String(), "--no-pair")
	}
	return arguments
}

func (c *agentController) doctor(ctx context.Context, fix bool) (string, error) {
	payload, err := c.runCommand(ctx, doctorArguments(fix)...)
	return strings.TrimSpace(string(payload)), err
}

func (c *agentController) pairing(ctx context.Context) (pairingInfo, error) {
	payload, err := c.runCommand(ctx, pairingArguments()...)
	if err != nil {
		return pairingInfo{}, err
	}
	return parsePairingInfo(payload)
}

// 指定网络生成二维码，保留未指定时的旧默认行为。
func (c *agentController) pairingOnNetwork(ctx context.Context, network string) (pairingInfo, error) {
	if network != "tailscale" && network != "lan" {
		return pairingInfo{}, errors.New("请选择 Tailscale 或同一局域网")
	}
	args := append(pairingArguments(), "--network", network)
	payload, err := c.runCommand(ctx, args...)
	if err != nil {
		return pairingInfo{}, err
	}
	return parsePairingInfo(payload)
}

func pairingArguments() []string {
	return []string{"pair", "--qr-only", "--json"}
}

func parsePairingInfo(payload []byte) (pairingInfo, error) {
	receipt, err := decodeOnboardingPairingTicketReceipt(payload, false)
	if err != nil {
		return pairingInfo{}, errors.New("解析短期配对信息失败，请重新生成")
	}
	return pairingInfo{
		OK:                  receipt.OK,
		Endpoint:            receipt.Endpoint,
		Network:             receipt.Network,
		TailscaleDNSName:    receipt.TailscaleDNSName,
		TailscaleDeviceName: receipt.TailscaleDeviceName,
		PairURL:             receipt.PairURL,
		PairExpiresAt:       receipt.PairExpiresAt,
		Warnings:            receipt.Warnings,
	}, nil
}

func doctorArguments(fix bool) []string {
	arguments := []string{"doctor"}
	if fix {
		arguments = append(arguments, "--fix")
	}
	return arguments
}

func (c *agentController) preflight(
	ctx context.Context,
	stage string,
	progress *onboardingProgressAccumulator,
	generation uint64,
	onProgress func(onboardingCheck),
	extraArgs ...string,
) (onboardingPreflightReport, error) {
	run := c.runHiddenWithProgress
	if c.commandRunner != nil {
		run = func(runCtx context.Context, _ *onboardingProgressAccumulator, _ uint64, _ func(onboardingCheck), args ...string) ([]byte, error) {
			return c.commandRunner(runCtx, args...)
		}
	}
	report, err := runTrayPreflight(ctx, "windows", stage, progress, generation, onProgress, run, extraArgs...)
	if err == nil && report.Configured != nil {
		c.setConfigured(*report.Configured)
	}
	return report, err
}

func (c *agentController) runHidden(ctx context.Context, args ...string) ([]byte, error) {
	return c.runHiddenWithProgress(ctx, nil, 0, nil, args...)
}

func (c *agentController) runHiddenWithProgress(
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
		ctx, cancel = context.WithTimeout(ctx, trayCommandTimeout("windows", args...))
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, c.agentPath, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
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
		if cliErr := decodeTrayCommandError(stdout, stderr, err, trayValidationContextForArgs("windows", args, c.isConfigured()), args...); cliErr != nil {
			return nil, cliErr
		}
		return nil, newTrayUnknownCommandError(err, trayActiveStepForArgs(args))
	}
	return stdout, nil
}

func (c *agentController) openLogsTerminal() error {
	// 不打开 cmd：日志本来就是一串文本，用系统默认程序打开 agentd.log
	// 既能滚动查看，也不会在用户面前多出一个终端窗口。
	logPath, err := managedLogPath()
	if err != nil {
		return err
	}
	if _, err := os.Stat(logPath); err != nil {
		return fmt.Errorf("日志文件尚未生成：%s", logPath)
	}
	return shellOpenPath(logPath)
}

func managedLogPath() (string, error) {
	localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	if localAppData == "" {
		cacheDir, err := os.UserCacheDir()
		if err != nil {
			return "", fmt.Errorf("定位日志目录失败：%w", err)
		}
		localAppData = cacheDir
	}
	return filepath.Join(localAppData, "Mimi Remote", "logs", "agentd.log"), nil
}

func shellOpenPath(path string) error {
	// 托盘没有控制台，ShellExecuteEx 让资源管理器自己挑默认程序打开文件。
	verb, _ := syscall.UTF16PtrFromString("open")
	file, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	info := shellExecuteInfo{
		Size: uint32(unsafe.Sizeof(shellExecuteInfo{})),
		Verb: verb,
		File: file,
		Show: swShowNormal,
	}
	result, _, launchErr := procTrayShellExecuteExW.Call(uintptr(unsafe.Pointer(&info)))
	if result == 0 {
		return fmt.Errorf("打开日志失败：%v", launchErr)
	}
	return nil
}

func trayLogf(format string, args ...any) {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return
	}
	logDir := filepath.Join(cacheDir, "Mimi Remote")
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		return
	}
	file, err := os.OpenFile(filepath.Join(logDir, "tray.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = fmt.Fprintf(file, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
}

const (
	statusQueueTimeout             = 25 * time.Second
	backgroundStatusCommandTimeout = 12 * time.Second
	manualStatusCommandTimeout     = runtimebudget.ManualCommandTimeout
	// 启动就绪要覆盖 LAN 策略查询（最多 30 秒）与受管 Codex 初始化（最多 25 秒）；
	// 20 秒时实测约 22 秒才开始监听，托盘会先报就绪失败（#456）。
	serviceReadyWait = 60 * time.Second
	// restart 先停旧实例：等待 PID 退出最多 10 秒、同步计划任务最多 10 秒
	// （cmd/agentd/windows_service.go），再加上配置检查与提交启动的余量。
	serviceStopBudget = 20 * time.Second
)

var actionCommandBudget = trayCommandTimeout("windows", "start")

func statusContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), statusQueueTimeout)
}

func actionContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), actionCommandBudget)
}
