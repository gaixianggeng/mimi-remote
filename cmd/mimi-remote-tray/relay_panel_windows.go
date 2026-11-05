//go:build windows

package main

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const (
	panelRelay = 2100 + iota
	panelRelayApply
	panelRelayCancel
	panelRelayGuide
	wmPanelRelayConfigured = wmApp + 22
)

const selfHostedRelayGuideURL = "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/self-hosted-relay.md"

func (s tailcatTrayStatus) relayTitle() string {
	if s.managed() {
		return "Mimi 中转"
	}
	if strings.TrimSpace(s.DERPMapURL) != "" {
		return "自建中转"
	}
	return "默认 Tailcat 自带"
}

// 校验先于模式变更；不能因为地址无效就停用当前健康的中转。
func (c *agentController) configureRelay(ctx context.Context, choice, rawURL string) (tailcatTrayStatus, error) {
	if choice != "default" && choice != "custom" && choice != "mimi" {
		return tailcatTrayStatus{}, errors.New("请选择中转服务")
	}
	relayURL := ""
	if choice == "custom" {
		var err error
		relayURL, err = config.NormalizeTailcatDERPMapURL(rawURL)
		if err != nil {
			return tailcatTrayStatus{}, err
		}
		if relayURL == "" {
			return tailcatTrayStatus{}, errors.New("请输入完整的 DERP Map HTTPS 地址")
		}
		if relayURL == config.DefaultManagedTailcatDERPMapURL {
			return tailcatTrayStatus{}, errors.New("使用 Mimi 中转时，请直接选择“Mimi 中转”")
		}
	}
	status, err := c.tailcatStatus(ctx)
	if err != nil {
		return status, err
	}
	if choice == "mimi" || status.managed() {
		status, err = c.setTailcatManaged(ctx, choice == "mimi")
		if err != nil {
			return status, err
		}
	}
	if choice != "mimi" {
		if _, err = c.runCommand(ctx, "tailcat", "configure", "--derp-map-url="+relayURL, "--json"); err != nil {
			return status, err
		}
	}
	// “使用此中转”包含开启内置连接，用户无需再找另一个开关。
	status, err = c.setTailcat(ctx, true)
	if err != nil {
		return status, err
	}
	if choice != "mimi" && (status.managed() || status.DERPMapURL != relayURL) {
		return status, errors.New("中转配置尚未生效，请刷新后重试")
	}
	return status, nil
}

func (p *controlPanel) createRelayControls(instance uintptr) error {
	p.relayPicker = p.createControl(instance, "BUTTON", "中转服务…", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 32, 480, 510, 32, panelRelay)
	p.relayTitle = p.createControl(instance, "STATIC", "自建中转", wsChild|ssLeft|ssNoPrefix, 32, 100, 510, 30, 0)
	p.relayDescription = p.createControl(instance, "STATIC", "在有公网域名的服务器上部署 derper，把 DERP Map 文件发布到 HTTPS 地址，再填到下面。应用后，用手机扫描新二维码。", wsChild|ssLeft|ssNoPrefix, 32, 145, 510, 58, 0)
	p.relayInput = p.createControl(instance, "EDIT", "", wsChild|wsTabStop|0x00800000|0x0080, 32, 210, 510, 32, 0)
	p.relayApply = p.createControl(instance, "BUTTON", "使用此中转", wsChild|wsTabStop|bsOwnerDraw, 292, 270, 120, 42, panelRelayApply)
	p.relayCancel = p.createControl(instance, "BUTTON", "取消", wsChild|wsTabStop|bsOwnerDraw, 422, 270, 120, 42, panelRelayCancel)
	p.relayGuide = p.createControl(instance, "BUTTON", "部署文档", wsChild|wsTabStop|bsOwnerDraw, 32, 270, 120, 42, panelRelayGuide)
	p.relayControls = []uintptr{p.relayTitle, p.relayDescription, p.relayInput, p.relayApply, p.relayCancel, p.relayGuide}
	for _, control := range append([]uintptr{p.relayPicker}, p.relayControls...) {
		if control == 0 {
			return errors.New("创建中转配置控件失败")
		}
	}
	// 限制输入长度，与服务端地址验证一致。
	procPanelSendMessageW.Call(p.relayInput, 0x00C5, 2048, 0)
	return nil
}

func (p *controlPanel) layoutRelayControls() {
	for _, item := range []struct {
		control    uintptr
		x, y, w, h int
	}{
		{p.relayPicker, 32, 480, 510, 32}, {p.relayTitle, 32, 100, 510, 30},
		{p.relayDescription, 32, 145, 510, 58}, {p.relayInput, 32, 210, 510, 32},
		{p.relayApply, 292, 270, 120, 42}, {p.relayCancel, 422, 270, 120, 42}, {p.relayGuide, 32, 270, 120, 42},
	} {
		procPanelSetWindowPos.Call(item.control, 0, uintptr(p.scale(item.x)), uintptr(p.scale(item.y)),
			uintptr(p.scale(item.w)), uintptr(p.scale(item.h)), swpNoZOrder|swpNoActivate)
	}
}

func (p *controlPanel) chooseRelayService() {
	if !p.pairNetworkEnabled() {
		return
	}
	status, has, err := p.app.tailcatSnapshot()
	if !has || err != nil {
		p.app.showError(errors.New("内置连接状态暂不可用，请刷新后重试"))
		return
	}
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)
	for i, title := range []string{"默认 Tailcat 自带", "自建中转", "Mimi 中转"} {
		flags := uint32(0)
		if title == status.relayTitle() {
			flags = 0x0008
		}
		appendMenu(menu, flags, uint32(i+1), title)
	}
	var bounds panelRect
	procPanelGetWindowRect.Call(p.relayPicker, uintptr(unsafe.Pointer(&bounds)))
	choice, _, _ := procTrackPopupMenu.Call(menu, tpmReturnCmd|tpmNoNotify,
		uintptr(bounds.Left), uintptr(bounds.Bottom), 0, p.window, 0)
	switch choice {
	case 1:
		p.applyRelay("default", "")
	case 2:
		p.relayEditing = true
		p.pairingView = false
		setControlPanelVisible(p.dashboardControls, false)
		setControlPanelVisible(p.pairingControls, false)
		setControlPanelVisible([]uintptr{p.relayPicker}, false)
		setControlPanelVisible(p.relayControls, true)
		value := status.DERPMapURL
		if status.managed() {
			value = ""
		}
		setControlPanelText(p.relayInput, value)
		procPanelSetFocus.Call(p.relayInput)
		procPanelInvalidateRect.Call(p.window, 0, 1)
	case 3:
		p.applyRelay("mimi", "")
	}
}

func (p *controlPanel) applyRelay(choice, relayURL string) {
	status, _, _ := p.app.tailcatSnapshot()
	if choice != "mimi" && status.Enabled && (status.managed() || relayURL != status.DERPMapURL) {
		if showMessage(p.window, "更换中转服务？", "本机内置连接会短暂重连，使用该线路的手机需要重新扫码。Tailscale 和局域网连接不受影响。", mbYesNo|mbIconWarning) != idYes {
			return
		}
	}
	if !p.app.beginBusy() {
		return
	}
	window := p.window
	go func() {
		ctx, cancel := actionContext()
		next, err := p.app.controller.configureRelay(ctx, choice, relayURL)
		cancel()
		if err == nil {
			p.app.storeTailcat(next, nil)
		}
		p.app.refreshStatus()
		p.app.endBusy()
		if err != nil {
			p.app.showError(err)
			return
		}
		procPostMessageW.Call(window, wmPanelRelayConfigured, 0, 0)
	}()
}

// 交给系统默认浏览器打开文档；打不开时提示地址，不影响正在填写的中转。
func (p *controlPanel) openSelfHostedRelayGuide() {
	if err := exec.Command("rundll32", "url.dll,FileProtocolHandler", selfHostedRelayGuideURL).Start(); err != nil {
		p.app.showError(errors.New("无法打开浏览器，请访问：" + selfHostedRelayGuideURL))
	}
}

func (p *controlPanel) applyCustomRelay() {
	buffer := make([]uint16, 2049)
	procPanelSendMessageW.Call(p.relayInput, 0x000D, uintptr(len(buffer)), uintptr(unsafe.Pointer(&buffer[0])))
	p.applyRelay("custom", strings.TrimSpace(syscall.UTF16ToString(buffer)))
}
