//go:build windows

package main

import (
	"errors"
	"strings"
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
	presentation := tailcatPresentation{Value: "正在检查", Color: neutral, ToggleLabel: "开启 Tailcat"}
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
	presentation.ToggleLabel = "关闭 Tailcat"
	presentation.ToggleEnabled = !busy && status.ProcessOK
	presentation.Color = rgbColor(35, 126, 58)
	if !tailcat.Running {
		presentation.Color = rgbColor(154, 91, 0)
	}
	return presentation
}

// defaultPairingUsesTailcat 在 agentd 只监听本机、Tailcat 已运行时直接展示 Tailcat
// 二维码：此时默认配对没有手机可达的地址，必然失败。
func defaultPairingUsesTailcat(status agentStatus, tailcat tailcatTrayStatus, hasTailcat bool) bool {
	return hasTailcat && tailcat.ready() && status.NetworkStatus != nil &&
		strings.EqualFold(strings.TrimSpace(status.NetworkStatus.Mode), "loopback")
}

func (p *controlPanel) actionButtonLabel(command uint32) string {
	switch command {
	case panelTailcatToggle:
		return fallbackText(p.tailcatToggleLabel, "开启 Tailcat")
	case panelPairNetwork:
		if p.pairingTailcat {
			return "用默认网络"
		}
		return "用 Tailcat"
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
	_, hasTailcat, tailcatErr := p.app.tailcatSnapshot()
	p.app.mu.RLock()
	busy := p.app.busy
	p.app.mu.RUnlock()
	return !p.pairingLoading && !busy && (p.pairingTailcat || (hasTailcat && tailcatErr == nil))
}

// switchPairingNetwork 在默认网络与 Tailcat 二维码之间切换。Tailcat 未开启时先征得
// 确认并由 agentd 回读确认运行，成功后经 wmPanelTailcatEnabled 回到这里生成二维码。
func (p *controlPanel) switchPairingNetwork() {
	if p.pairingLoading {
		return
	}
	if p.pairingTailcat {
		p.pairingTailcat = false
		p.refreshPairing()
		return
	}
	tailcat, hasTailcat, tailcatErr := p.app.tailcatSnapshot()
	switch {
	case !hasTailcat || tailcatErr != nil:
		p.app.showError(errors.New("Tailcat 状态暂不可用，请返回面板刷新状态后重试"))
	case !tailcat.Enabled:
		p.app.confirmAndSetTailcat(true, p.window)
	case !tailcat.Running:
		p.app.showError(errors.New("Tailcat 已开启但没有运行：" + fallbackText(tailcat.Error, "请运行诊断查看原因")))
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
	result.Title = "用 Tailcat 扫码连接"
	result.Endpoint = "连接方式：Tailcat 内置连接"
	switch {
	case loading:
		result.Summary = "正在向中继申请短期 Tailcat 配对节点，首次可能需要 20 秒…"
	case failed:
		result.Warning = "请稍后点击“刷新二维码”重试，或运行诊断查看 Tailcat 状态。"
	case ready:
		result.Badge = "Tailcat · 10 分钟"
		result.Summary = "无需 Tailscale 或局域网。用移动设备上的 Mimi Remote 扫描左侧二维码。"
	}
	return result
}
