//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// tailcatTrayStatus 只读取 agentd tailcat status 的公开字段，不读取配置、连接地址或私钥。
type tailcatTrayStatus struct {
	Enabled           bool   `json:"enabled"`
	Running           bool   `json:"running"`
	PairedDeviceCount int    `json:"paired_device_count"`
	Error             string `json:"error"`
}

func (s tailcatTrayStatus) ready() bool {
	return s.Enabled && s.Running
}

func (s tailcatTrayStatus) title() string {
	switch {
	case !s.Enabled:
		return "未开启"
	case !s.Running:
		return "需要处理"
	default:
		return fmt.Sprintf("运行中 · %d 台设备", s.PairedDeviceCount)
	}
}

func parseTailcatTrayStatus(payload []byte) (tailcatTrayStatus, error) {
	var result tailcatTrayStatus
	var contract map[string]json.RawMessage
	if json.Unmarshal(payload, &result) != nil || json.Unmarshal(payload, &contract) != nil ||
		contract["enabled"] == nil || contract["running"] == nil {
		return tailcatTrayStatus{}, errors.New("agentd 未提供 Tailcat 状态，请重新安装同版本的 Mimi Remote")
	}
	return result, nil
}

func tailcatStatusArguments() []string {
	return []string{"tailcat", "status", "--json"}
}

func tailcatToggleArguments(enable bool) []string {
	action := "disable"
	if enable {
		action = "enable"
	}
	return []string{"tailcat", action, "--json"}
}

func tailcatPairingArguments() []string {
	return []string{"tailcat", "pair", "--qr-only", "--json"}
}

func (c *agentController) runCommand(ctx context.Context, args ...string) ([]byte, error) {
	if c.commandRunner != nil {
		return c.commandRunner(ctx, args...)
	}
	return c.runHidden(ctx, args...)
}

func (c *agentController) tailcatStatus(ctx context.Context) (tailcatTrayStatus, error) {
	payload, err := c.runCommand(ctx, tailcatStatusArguments()...)
	if err != nil {
		return tailcatTrayStatus{}, err
	}
	return parseTailcatTrayStatus(payload)
}

// setTailcat 以 agentd 回读的状态为准：enable/disable 命令返回成功，但辅助程序没有
// 真正运行或停止时，不能向用户报告成功。
func (c *agentController) setTailcat(ctx context.Context, enable bool) (tailcatTrayStatus, error) {
	if _, err := c.runCommand(ctx, tailcatToggleArguments(enable)...); err != nil {
		return tailcatTrayStatus{}, err
	}
	status, err := c.tailcatStatus(ctx)
	if err != nil {
		return tailcatTrayStatus{}, fmt.Errorf("无法回读 Tailcat 状态：%w", err)
	}
	return status, confirmTailcatState(status, enable)
}

func confirmTailcatState(status tailcatTrayStatus, enable bool) error {
	if enable && !status.ready() {
		return fmt.Errorf("agentd 回读显示 Tailcat 没有运行：%s", fallbackText(status.Error, "请运行诊断查看原因"))
	}
	if !enable && (status.Enabled || status.Running) {
		return errors.New("agentd 回读显示 Tailcat 仍在运行，请刷新状态后重试")
	}
	return nil
}

func (c *agentController) tailcatPairing(ctx context.Context) (pairingInfo, error) {
	payload, err := c.runCommand(ctx, tailcatPairingArguments()...)
	if err != nil {
		return pairingInfo{}, err
	}
	result, err := parsePairingInfo(payload)
	if err != nil {
		return pairingInfo{}, err
	}
	link, err := url.Parse(result.PairURL)
	if err != nil || link.Query().Get("transport") != "tailcat" ||
		strings.TrimSpace(link.Query().Get("tailcat_pair_address")) == "" {
		return pairingInfo{}, errors.New("Tailcat 配对信息缺少内置连接地址，请重新生成")
	}
	return result, nil
}

func tailcatToggleConfirmation(enable bool) (string, string, uint32) {
	if enable {
		return "开启 Tailcat？",
			"Tailcat 是实验性的内置连接：手机不装 Tailscale、电脑不开局域网也能扫码连接。\r\n\r\n" +
				"连接先经 DERP 中继发现对端，网络允许时改为端到端加密直连，否则继续经中继转发。默认中继由 Tailscale 运营。" +
				"Tailcat 只发起出站连接，不新增 Windows 防火墙规则。",
			mbYesNo | mbIconInfo
	}
	return "关闭 Tailcat？",
		"正在使用 Tailcat 的手机和平板会断开。\r\n\r\nagentd 以及 Tailscale、局域网连接继续运行。",
		mbYesNo | mbIconWarning
}

// refreshTailcat 只在 agentd 进程可用时读取 Tailcat；服务停止时清空旧状态，
// 避免停机后仍显示“运行中”。
func (a *trayApplication) refreshTailcat(processOK bool) {
	if !processOK {
		a.mu.Lock()
		a.tailcat, a.hasTailcat, a.tailcatErr = tailcatTrayStatus{}, false, nil
		a.mu.Unlock()
		return
	}
	ctx, cancel := statusContext()
	status, err := a.controller.tailcatStatus(ctx)
	cancel()
	a.storeTailcat(status, err)
}

func (a *trayApplication) storeTailcat(status tailcatTrayStatus, err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.tailcatErr = err
	if err == nil {
		a.tailcat, a.hasTailcat = status, true
	}
}

func (a *trayApplication) tailcatSnapshot() (tailcatTrayStatus, bool, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.tailcat, a.hasTailcat, a.tailcatErr
}

func (a *trayApplication) toggleTailcat() {
	status, has, err := a.tailcatSnapshot()
	if !has || err != nil {
		a.showError(errors.New("Tailcat 状态暂不可用，请刷新状态后重试"))
		return
	}
	a.confirmAndSetTailcat(!status.Enabled, 0)
}

// confirmAndSetTailcat 在用户确认后开启或关闭 Tailcat。notifyWindow 非零时，开启
// 成功后向该窗口投递 wmPanelTailcatEnabled，让配对视图切到 Tailcat 二维码。
func (a *trayApplication) confirmAndSetTailcat(enable bool, notifyWindow uintptr) {
	title, text, flags := tailcatToggleConfirmation(enable)
	if showMessage(a.window, title, text, flags) != idYes || !a.beginBusy() {
		return
	}
	verb := "关闭"
	if enable {
		verb = "开启"
	}
	go func() {
		defer a.endBusy()
		ctx, cancel := actionContext()
		status, err := a.controller.setTailcat(ctx, enable)
		cancel()
		if err == nil {
			a.storeTailcat(status, nil)
		}
		a.refreshStatus()
		if err != nil {
			trayLogf("tailcat %s failed: %v", verb, err)
			a.showError(fmt.Errorf("%s Tailcat 失败：%w", verb, err))
			return
		}
		a.showBalloon("Mimi Remote", "Tailcat 已"+verb, niifInfo)
		if enable && notifyWindow != 0 {
			procPostMessageW.Call(notifyWindow, wmPanelTailcatEnabled, 0, 0)
		}
	}()
}

func (a *trayApplication) requestTailcatPairing() {
	status, has, err := a.tailcatSnapshot()
	if !has || err != nil || !status.ready() {
		a.showError(errors.New("Tailcat 尚未运行，请先在控制面板或托盘菜单中开启 Tailcat"))
		return
	}
	a.mu.RLock()
	ready := a.status.ServiceOK
	a.mu.RUnlock()
	if !ready {
		a.showError(errors.New("服务尚未就绪，请先启动服务并等待状态变为“运行正常”"))
		return
	}
	procPostMessageW.Call(a.window, wmTrayPair, pairRequestTailcat, 0)
}
