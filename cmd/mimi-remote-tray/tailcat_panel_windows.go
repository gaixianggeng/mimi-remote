//go:build windows

package main

import (
	"errors"
	"unsafe"
)

const wmPanelTailcatEnabled = wmApp + 21

type tailcatPresentation struct {
	Value         string
	Color         uint32
	ToggleLabel   string
	ToggleEnabled bool
}

// makeTailcatPresentation 只依据 agentd 回读的 Tailcat 状态。读不到状态时不提供开关，
// 避免在不确定的状态上开启或关闭。
func makeTailcatPresentation(status agentStatus, tailcat tailcatTrayStatus, hasTailcat bool, tailcatErr error, busy bool) tailcatPresentation {
	neutral := rgbColor(101, 101, 110)
	presentation := tailcatPresentation{Value: "正在检查", Color: neutral, ToggleLabel: "开启内置连接"}
	switch {
	case status.Version != "" && !status.ProcessOK:
		presentation.Value = "服务未运行"
		return presentation
	case tailcatErr != nil:
		presentation.Value = "状态不可用"
		presentation.Color = rgbColor(154, 91, 0)
		return presentation
	case !hasTailcat:
		return presentation
	case !tailcat.Enabled:
		presentation.Value = tailcat.title()
		presentation.ToggleEnabled = !busy && status.ServiceOK
		return presentation
	}
	presentation.Value = tailcat.title()
	presentation.ToggleLabel = "关闭内置连接"
	presentation.ToggleEnabled = !busy && status.ProcessOK
	presentation.Color = rgbColor(35, 126, 58)
	if !tailcat.Running {
		presentation.Color = rgbColor(154, 91, 0)
	}
	return presentation
}

// defaultPairingUsesTailcat 在 Tailscale 与局域网都没有开启或不可用、Tailcat 已运行时
// 直接展示 Tailcat 二维码：此时默认配对没有手机可达的地址，必然失败。listen 是回环
// 地址并不说明这一点，agentd 可能另外监听 Tailscale 地址，所以只看运行中 agentd 的模块状态。
func defaultPairingUsesTailcat(status agentStatus, tailcat tailcatTrayStatus, hasTailcat bool) bool {
	modules := status.ModuleStatus
	if !hasTailcat || !tailcat.ready() || modules == nil {
		return false
	}
	return !(modules.TailscaleEnabled && modules.TailscaleAvailable) && !(modules.LANEnabled && modules.LANAvailable)
}

func (p *controlPanel) actionButtonLabel(command uint32) string {
	switch command {
	case panelTailcatToggle:
		return fallbackText(p.tailcatToggleLabel, "开启内置连接")
	case panelPairNetwork:
		return "连接方式"
	}
	return panelActionLabel(command)
}

func (p *controlPanel) syncTailcatRow(presentation tailcatPresentation) {
	setControlPanelText(p.tailcatValue, presentation.Value)
	p.tailcatStatusColor = presentation.Color
	if p.tailcatToggleLabel != presentation.ToggleLabel {
		p.tailcatToggleLabel = presentation.ToggleLabel
		setControlPanelText(p.tailcatToggle, presentation.ToggleLabel)
	}
	setControlPanelEnabled(p.tailcatToggle, presentation.ToggleEnabled)
	procPanelInvalidateRect.Call(p.tailcatToggle, 0, 1)
}

func (p *controlPanel) pairNetworkEnabled() bool {
	p.app.mu.RLock()
	busy := p.app.busy
	p.app.mu.RUnlock()
	return !p.pairingLoading && !busy
}

// 显式选择网络，不能把“默认网络”当作 Tailscale 或局域网的替身。
func (p *controlPanel) switchPairingNetwork() {
	if !p.pairNetworkEnabled() {
		return
	}
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)
	p.app.mu.RLock()
	modules := p.app.status.ModuleStatus
	p.app.mu.RUnlock()
	_, hasTailcat, tailcatErr := p.app.tailcatSnapshot()
	appendMenu(menu, menuFlags(!hasTailcat || tailcatErr != nil), 1, "内置连接（Tailcat）· 免费可用")
	appendMenu(menu, menuFlags(modules == nil || !modules.TailscaleEnabled || !modules.TailscaleAvailable), 2, "Tailscale")
	appendMenu(menu, menuFlags(modules == nil || !modules.LANEnabled || !modules.LANAvailable), 3, "同一局域网")
	var bounds panelRect
	procPanelGetWindowRect.Call(p.pairNetwork, uintptr(unsafe.Pointer(&bounds)))
	choice, _, _ := procTrackPopupMenu.Call(menu, tpmReturnCmd|tpmNoNotify,
		uintptr(bounds.Left), uintptr(bounds.Bottom), 0, p.window, 0)
	switch choice {
	case 1:
		p.selectBuiltinPairing()
	case 2, 3:
		p.pairingTailcat = false
		p.pairingNetwork = "tailscale"
		if choice == 3 {
			p.pairingNetwork = "lan"
		}
		p.refreshPairing()
	}
}

func (p *controlPanel) selectBuiltinPairing() {
	tailcat, hasTailcat, tailcatErr := p.app.tailcatSnapshot()
	switch {
	case !hasTailcat || tailcatErr != nil:
		p.app.showError(errors.New("内置连接状态暂不可用，请返回面板刷新后重试"))
	case !tailcat.Enabled:
		// 用户已经选择内置连接，直接开启并回读结果，不再询问连接模式。
		p.app.setTailcatForPairing(p.window)
	case !tailcat.Running:
		p.app.showError(errors.New("内置连接未运行：" + fallbackText(tailcat.Error, "请运行诊断查看原因")))
	default:
		p.pairingTailcat = true
		p.refreshPairing()
	}
}

func (p *controlPanel) finishTailcatEnabled() {
	if !p.pairingView {
		return
	}
	p.pairingTailcat = true
	p.refreshPairing()
}

type pairingCopy struct {
	Badge    string
	Title    string
	Summary  string
	Endpoint string
	Warning  string
}

// tailcatPairingCopy 覆盖配对视图在 Tailcat 模式下的文案。Tailcat 配对信息里的
// Endpoint 是隧道内的本机地址，对用户没有意义，改为说明连接方式。
func tailcatPairingCopy(base pairingCopy, loading bool, failed bool, ready bool) pairingCopy {
	result := base
	result.Title = "扫描二维码连接电脑"
	result.Endpoint = "连接方式：内置连接（Tailcat）"
	switch {
	case loading:
		result.Summary = "正在向中继申请短期 Tailcat 配对节点，首次可能需要 20 秒…"
	case failed:
		result.Warning = "请稍后点击“刷新二维码”重试，或运行诊断查看 Tailcat 状态。"
	case ready:
		result.Badge = "Tailcat · 10 分钟"
		result.Summary = "Mimi 全部功能免费。用手机扫码即可连接；已开通 Mimi 中转服务的设备会自动启用。"
	}
	return result
}
