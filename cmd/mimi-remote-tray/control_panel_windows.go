//go:build windows

package main

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/skip2/go-qrcode"
)

const (
	controlPanelClass = "MimiRemoteControlPanelWindow"

	wmPaint          = 0x000F
	wmEraseBkgnd     = 0x0014
	wmDrawItem       = 0x002B
	wmSetFont        = 0x0030
	wmCtlColorStatic = 0x0138
	wmDPIChanged     = 0x02E0

	wsChild        = 0x40000000
	wsVisible      = 0x10000000
	wsCaption      = 0x00C00000
	wsSysMenu      = 0x00080000
	wsMinimizeBox  = 0x00020000
	wsClipChildren = 0x02000000
	wsTabStop      = 0x00010000

	wsExAppWindow     = 0x00040000
	wsExControlParent = 0x00010000

	ssLeft      = 0x00000000
	ssCenter    = 0x00000001
	ssNoPrefix  = 0x00000080
	bsOwnerDraw = 0x0000000B

	swHide    = 0
	swShow    = 5
	swRestore = 9

	colorWindow        = 5
	transparentMode    = 1
	fontWeightNormal   = 400
	fontWeightMedium   = 500
	fontWeightSemibold = 600
	clearTypeQuality   = 5
	defaultCharset     = 1

	stockNullBrush = 5
	penStyleSolid  = 0

	odtButton   = 4
	odsSelected = 0x0001
	odsDisabled = 0x0004
	odsFocus    = 0x0010

	dtCenter      = 0x00000001
	dtVCenter     = 0x00000004
	dtSingleLine  = 0x00000020
	dtNoPrefix    = 0x00000800
	dtEndEllipsis = 0x00008000

	diNormal = 0x0003

	cfUnicodeText = 13
	gmemMoveable  = 0x0002

	swpNoZOrder   = 0x0004
	swpNoActivate = 0x0010
	defaultDPI    = 96

	controlPanelLogicalWidth  = 600
	controlPanelLogicalHeight = 550
)

const (
	panelRefresh = 2000 + iota
	panelStart
	panelRestart
	panelStop
	panelPair
	panelDoctor
	panelDoctorFix
	panelLogs
	panelPairBack
	panelPairCopy
	panelPairRefresh
)

const wmPanelPairReady = wmApp + 20

var (
	panelUser32 = syscall.NewLazyDLL("user32.dll")
	panelGDI32  = syscall.NewLazyDLL("gdi32.dll")

	procPanelShowWindow       = panelUser32.NewProc("ShowWindow")
	procPanelSetWindowTextW   = panelUser32.NewProc("SetWindowTextW")
	procPanelEnableWindow     = panelUser32.NewProc("EnableWindow")
	procPanelSendMessageW     = panelUser32.NewProc("SendMessageW")
	procPanelSetFocus         = panelUser32.NewProc("SetFocus")
	procPanelGetSystemMetrics = panelUser32.NewProc("GetSystemMetrics")
	procPanelGetDpiForSystem  = panelUser32.NewProc("GetDpiForSystem")
	procPanelGetDpiForWindow  = panelUser32.NewProc("GetDpiForWindow")
	procPanelGetWindowRect    = panelUser32.NewProc("GetWindowRect")
	procPanelSetWindowPos     = panelUser32.NewProc("SetWindowPos")
	procPanelIsDialogMessageW = panelUser32.NewProc("IsDialogMessageW")
	procPanelInvalidateRect   = panelUser32.NewProc("InvalidateRect")
	procPanelGetClientRect    = panelUser32.NewProc("GetClientRect")
	procPanelBeginPaint       = panelUser32.NewProc("BeginPaint")
	procPanelEndPaint         = panelUser32.NewProc("EndPaint")
	procPanelFillRect         = panelUser32.NewProc("FillRect")
	procPanelDrawTextW        = panelUser32.NewProc("DrawTextW")
	procPanelDrawIconEx       = panelUser32.NewProc("DrawIconEx")
	procPanelOpenClipboard    = panelUser32.NewProc("OpenClipboard")
	procPanelEmptyClipboard   = panelUser32.NewProc("EmptyClipboard")
	procPanelSetClipboardData = panelUser32.NewProc("SetClipboardData")
	procPanelCloseClipboard   = panelUser32.NewProc("CloseClipboard")

	procPanelCreateFontW    = panelGDI32.NewProc("CreateFontW")
	procPanelCreatePen      = panelGDI32.NewProc("CreatePen")
	procPanelCreateBrush    = panelGDI32.NewProc("CreateSolidBrush")
	procPanelDeleteObject   = panelGDI32.NewProc("DeleteObject")
	procPanelSelectObject   = panelGDI32.NewProc("SelectObject")
	procPanelGetStockObject = panelGDI32.NewProc("GetStockObject")
	procPanelSetTextColor   = panelGDI32.NewProc("SetTextColor")
	procPanelSetBkMode      = panelGDI32.NewProc("SetBkMode")
	procPanelRoundRect      = panelGDI32.NewProc("RoundRect")
	procPanelEllipse        = panelGDI32.NewProc("Ellipse")
	procPanelRectangle      = panelGDI32.NewProc("Rectangle")
	procPanelMoveToEx       = panelGDI32.NewProc("MoveToEx")
	procPanelLineTo         = panelGDI32.NewProc("LineTo")
	procPanelPolygon        = panelGDI32.NewProc("Polygon")

	procPanelGlobalAlloc  = kernel32.NewProc("GlobalAlloc")
	procPanelGlobalLock   = kernel32.NewProc("GlobalLock")
	procPanelGlobalUnlock = kernel32.NewProc("GlobalUnlock")
	procPanelGlobalFree   = kernel32.NewProc("GlobalFree")
	procPanelMoveMemory   = kernel32.NewProc("RtlMoveMemory")
)

type panelRect struct {
	Left   int32
	Top    int32
	Right  int32
	Bottom int32
}

type panelPaintStruct struct {
	DC        uintptr
	Erase     int32
	Paint     panelRect
	Restore   int32
	IncUpdate int32
	Reserved  [32]byte
}

type panelDrawItem struct {
	ControlType uint32
	ControlID   uint32
	ItemID      uint32
	ItemAction  uint32
	ItemState   uint32
	ItemWindow  uintptr
	DC          uintptr
	Rect        panelRect
	ItemData    uintptr
}

type controlPanel struct {
	app *trayApplication

	window uintptr
	dpi    uint32

	titleFont  uintptr
	statusFont uintptr
	normalFont uintptr
	valueFont  uintptr
	smallFont  uintptr
	buttonFont uintptr

	backgroundBrush uintptr
	cardBrush       uintptr
	detailBrush     uintptr
	statusBrush     uintptr

	titleLabel      uintptr
	appVersionLabel uintptr
	subtitleLabel   uintptr
	badgeLabel      uintptr
	statusDotLabel  uintptr
	statusLabel     uintptr
	summaryLabel    uintptr
	endpointLabel   uintptr
	endpointValue   uintptr
	versionLabel    uintptr
	versionValue    uintptr
	networkLabel    uintptr
	networkValue    uintptr
	projectsLabel   uintptr
	projectsValue   uintptr
	codexLabel      uintptr
	codexValue      uintptr
	claudeLabel     uintptr
	claudeValue     uintptr
	footerLabel     uintptr

	refresh   uintptr
	start     uintptr
	restart   uintptr
	stop      uintptr
	pair      uintptr
	doctor    uintptr
	doctorFix uintptr
	logs      uintptr

	pairTitle         uintptr
	pairSummary       uintptr
	pairEndpoint      uintptr
	pairExpiry        uintptr
	pairWarning       uintptr
	pairBack          uintptr
	pairCopy          uintptr
	pairRefresh       uintptr
	dashboardControls []uintptr
	pairingControls   []uintptr

	pairingDataMu        sync.Mutex
	pendingPairing       pairingInfo
	pendingPairingMatrix [][]bool
	pendingPairingErr    error
	pairingInfo          pairingInfo
	pairingMatrix        [][]bool
	pairingErr           error
	pairingView          bool
	pairingLoading       bool

	statusColor       uint32
	statusBackground  uint32
	codexStatusColor  uint32
	claudeStatusColor uint32
}

type controlPanelPresentation struct {
	StateTitle       string
	StateBadge       string
	StateSummary     string
	EndpointValue    string
	VersionValue     string
	NetworkValue     string
	ProjectsValue    string
	CodexValue       string
	ClaudeValue      string
	StatusColor      uint32
	StatusBackground uint32
	CodexColor       uint32
	ClaudeColor      uint32
	RefreshEnabled   bool
	StartEnabled     bool
	RestartEnabled   bool
	StopEnabled      bool
	PairEnabled      bool
	DoctorEnabled    bool
	FixEnabled       bool
	LogsEnabled      bool
}

func (a *trayApplication) showControlPanel() {
	if a.panel == nil {
		panel := &controlPanel{app: a}
		a.panel = panel
		if err := panel.create(); err != nil {
			a.panel = nil
			a.showError(err)
			return
		}
	}
	a.panel.showDashboardView()
	a.panel.ensureWindowDPI()
	a.panel.syncFromApplication()
	procPanelShowWindow.Call(a.panel.window, swRestore)
	procPanelShowWindow.Call(a.panel.window, swShow)
	procSetForegroundWindow.Call(a.panel.window)
	procPanelSetFocus.Call(a.panel.refresh)
}

func (a *trayApplication) syncControlPanel() {
	if a.panel != nil && a.panel.window != 0 {
		a.panel.syncFromApplication()
	}
}

func (a *trayApplication) destroyControlPanel() {
	if a.panel == nil {
		return
	}
	panel := a.panel
	if panel.window != 0 {
		procDestroyWindow.Call(panel.window)
	}
	panel.releaseResources()
	a.panel = nil
}

func translateControlPanelMessage(panel *controlPanel, msg *message) bool {
	if panel == nil || panel.window == 0 || msg == nil {
		return false
	}
	translated, _, _ := procPanelIsDialogMessageW.Call(
		panel.window,
		uintptr(unsafe.Pointer(msg)),
	)
	return translated != 0
}

func (p *controlPanel) create() error {
	if p == nil || p.app == nil {
		return errors.New("Windows 控制面板初始化失败")
	}
	instance, _, err := procGetModuleHandleW.Call(0)
	if instance == 0 {
		return fmt.Errorf("获取 Windows 模块句柄失败：%v", err)
	}
	p.dpi = controlPanelSystemDPI()
	className, _ := syscall.UTF16PtrFromString(controlPanelClass)
	cursor, _, _ := procLoadCursorW.Call(0, idcArrow)
	class := windowClassEx{
		Size:       uint32(unsafe.Sizeof(windowClassEx{})),
		WndProc:    syscall.NewCallback(controlPanelWindowProc),
		Instance:   instance,
		Icon:       p.app.icon,
		Cursor:     cursor,
		Background: colorWindow + 1,
		ClassName:  className,
		IconSmall:  p.app.icon,
	}
	registered, _, registerErr := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&class)))
	if registered == 0 && !errors.Is(registerErr, errorAlreadyExists) {
		return fmt.Errorf("注册 Windows 控制面板失败：%v", registerErr)
	}

	windowWidth := p.scale(controlPanelLogicalWidth)
	windowHeight := p.scale(controlPanelLogicalHeight)
	screenWidth, _, _ := procPanelGetSystemMetrics.Call(0)
	screenHeight, _, _ := procPanelGetSystemMetrics.Call(1)
	x := p.scale(80)
	y := p.scale(60)
	if int(screenWidth) > windowWidth {
		x = (int(screenWidth) - windowWidth) / 2
	}
	if int(screenHeight) > windowHeight {
		y = (int(screenHeight) - windowHeight) / 2
	}
	title, _ := syscall.UTF16PtrFromString("Mimi Remote")
	window, _, createErr := procCreateWindowExW.Call(
		wsExAppWindow|wsExControlParent,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(title)),
		wsCaption|wsSysMenu|wsMinimizeBox|wsClipChildren,
		uintptr(x), uintptr(y), uintptr(windowWidth), uintptr(windowHeight),
		0, 0, instance, 0,
	)
	if window == 0 {
		return fmt.Errorf("创建 Windows 控制面板失败：%v", createErr)
	}
	p.window = window
	if procPanelGetDpiForWindow.Find() == nil {
		if dpi, _, _ := procPanelGetDpiForWindow.Call(window); dpi >= defaultDPI {
			actualDPI := uint32(dpi)
			if actualDPI != p.dpi {
				p.dpi = actualDPI
				windowWidth = p.scale(controlPanelLogicalWidth)
				windowHeight = p.scale(controlPanelLogicalHeight)
				if int(screenWidth) > windowWidth {
					x = (int(screenWidth) - windowWidth) / 2
				}
				if int(screenHeight) > windowHeight {
					y = (int(screenHeight) - windowHeight) / 2
				}
				procPanelSetWindowPos.Call(
					window, 0,
					uintptr(x), uintptr(y), uintptr(windowWidth), uintptr(windowHeight),
					swpNoZOrder|swpNoActivate,
				)
			}
		}
	}
	p.createResources()
	if err := p.createControls(instance); err != nil {
		procDestroyWindow.Call(window)
		p.window = 0
		p.releaseResources()
		return err
	}
	return nil
}

func controlPanelSystemDPI() uint32 {
	if procPanelGetDpiForSystem.Find() == nil {
		if dpi, _, _ := procPanelGetDpiForSystem.Call(); dpi >= defaultDPI {
			return uint32(dpi)
		}
	}
	return defaultDPI
}

// ensureWindowDPI resolves the DPI from the window's actual monitor immediately
// before it is shown. Windows can create a hidden Per-Monitor V2 window at its
// logical fallback size before the monitor DPI is available, without sending a
// later WM_DPICHANGED. Always reconciling the outer bounds here prevents a
// 600x550 physical-pixel panel on 150%/200% displays.
func (p *controlPanel) ensureWindowDPI() {
	if p == nil || p.window == 0 {
		return
	}
	actualDPI := p.dpi
	if procPanelGetDpiForWindow.Find() == nil {
		if dpi, _, _ := procPanelGetDpiForWindow.Call(p.window); dpi >= defaultDPI {
			actualDPI = uint32(dpi)
		}
	}
	if actualDPI < defaultDPI {
		actualDPI = defaultDPI
	}

	var bounds panelRect
	if result, _, _ := procPanelGetWindowRect.Call(p.window, uintptr(unsafe.Pointer(&bounds))); result == 0 {
		return
	}
	width := scaleControlPanelValue(controlPanelLogicalWidth, actualDPI)
	height := scaleControlPanelValue(controlPanelLogicalHeight, actualDPI)
	bounds.Right = bounds.Left + int32(width)
	bounds.Bottom = bounds.Top + int32(height)
	p.handleDPIChanged(actualDPI, &bounds)
}

func scaleControlPanelValue(value int, dpi uint32) int {
	if dpi < defaultDPI {
		dpi = defaultDPI
	}
	return (value*int(dpi) + defaultDPI/2) / defaultDPI
}

func (p *controlPanel) scale(value int) int {
	return scaleControlPanelValue(value, p.dpi)
}

func (p *controlPanel) scale32(value int32) int32 {
	return int32(p.scale(int(value)))
}

func (p *controlPanel) scaledRect(left, top, right, bottom int32) panelRect {
	return panelRect{
		Left:   p.scale32(left),
		Top:    p.scale32(top),
		Right:  p.scale32(right),
		Bottom: p.scale32(bottom),
	}
}

func (p *controlPanel) createResources() {
	p.createFonts()
	p.backgroundBrush = createPanelBrush(rgbColor(248, 248, 250))
	p.cardBrush = createPanelBrush(rgbColor(255, 255, 255))
	p.detailBrush = createPanelBrush(rgbColor(249, 249, 251))
	p.updateStatusBrush(rgbColor(239, 240, 243))
}

func (p *controlPanel) createFonts() {
	p.titleFont = createControlPanelFont(p.scale(24), fontWeightSemibold)
	p.statusFont = createControlPanelFont(p.scale(20), fontWeightSemibold)
	p.normalFont = createControlPanelFont(p.scale(15), fontWeightNormal)
	p.valueFont = createControlPanelFont(p.scale(15), fontWeightMedium)
	p.smallFont = createControlPanelFont(p.scale(13), fontWeightNormal)
	p.buttonFont = createControlPanelFont(p.scale(14), fontWeightMedium)
}

func (p *controlPanel) createControls(instance uintptr) error {
	p.titleLabel = p.createControl(instance, "STATIC", "Mimi Remote", wsChild|wsVisible|ssLeft|ssNoPrefix, 70, 16, 160, 30, 0)
	p.appVersionLabel = p.createControl(instance, "STATIC", "应用 "+formatReleaseVersion(releaseVersion), wsChild|wsVisible|ssLeft|ssNoPrefix, 238, 25, 140, 22, 0)
	p.subtitleLabel = p.createControl(instance, "STATIC", "Windows 控制面板", wsChild|wsVisible|ssLeft|ssNoPrefix, 70, 45, 300, 22, 0)
	p.badgeLabel = p.createControl(instance, "STATIC", "正在检查", wsChild|wsVisible|ssCenter|ssNoPrefix, 434, 25, 118, 24, 0)
	p.statusDotLabel = p.createControl(instance, "STATIC", "●", wsChild|wsVisible|ssCenter|ssNoPrefix, 31, 94, 24, 28, 0)
	p.statusLabel = p.createControl(instance, "STATIC", "正在检查服务", wsChild|wsVisible|ssLeft|ssNoPrefix, 58, 94, 470, 28, 0)
	p.summaryLabel = p.createControl(instance, "STATIC", "正在读取本机服务状态…", wsChild|wsVisible|ssLeft|ssNoPrefix, 58, 124, 480, 24, 0)

	p.endpointLabel = p.createControl(instance, "STATIC", "连接地址", wsChild|wsVisible|ssLeft|ssNoPrefix, 48, 162, 76, 20, 0)
	p.endpointValue = p.createControl(instance, "STATIC", "—", wsChild|wsVisible|ssLeft|ssNoPrefix, 134, 162, 144, 20, 0)
	p.versionLabel = p.createControl(instance, "STATIC", "服务版本", wsChild|wsVisible|ssLeft|ssNoPrefix, 314, 162, 58, 20, 0)
	p.versionValue = p.createControl(instance, "STATIC", "—", wsChild|wsVisible|ssLeft|ssNoPrefix, 382, 162, 158, 20, 0)
	p.networkLabel = p.createControl(instance, "STATIC", "网络", wsChild|wsVisible|ssLeft|ssNoPrefix, 48, 195, 76, 20, 0)
	p.networkValue = p.createControl(instance, "STATIC", "—", wsChild|wsVisible|ssLeft|ssNoPrefix, 134, 195, 144, 20, 0)
	p.projectsLabel = p.createControl(instance, "STATIC", "项目", wsChild|wsVisible|ssLeft|ssNoPrefix, 314, 195, 58, 20, 0)
	p.projectsValue = p.createControl(instance, "STATIC", "—", wsChild|wsVisible|ssLeft|ssNoPrefix, 382, 195, 158, 20, 0)
	p.codexLabel = p.createControl(instance, "STATIC", "Codex", wsChild|wsVisible|ssLeft|ssNoPrefix, 48, 228, 76, 20, 0)
	p.codexValue = p.createControl(instance, "STATIC", "正在检查", wsChild|wsVisible|ssLeft|ssNoPrefix, 134, 228, 144, 20, 0)
	p.claudeLabel = p.createControl(instance, "STATIC", "Claude Code", wsChild|wsVisible|ssLeft|ssNoPrefix, 314, 228, 76, 20, 0)
	p.claudeValue = p.createControl(instance, "STATIC", "正在检查", wsChild|wsVisible|ssLeft|ssNoPrefix, 400, 228, 140, 20, 0)

	p.refresh = p.createControl(instance, "BUTTON", "刷新状态", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 32, 270, 120, 42, panelRefresh)
	p.start = p.createControl(instance, "BUTTON", "启动服务", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 162, 270, 120, 42, panelStart)
	p.restart = p.createControl(instance, "BUTTON", "重新启动", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 292, 270, 120, 42, panelRestart)
	p.stop = p.createControl(instance, "BUTTON", "停止服务", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 422, 270, 120, 42, panelStop)

	p.pair = p.createControl(instance, "BUTTON", "配对设备", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 32, 366, 120, 50, panelPair)
	p.doctor = p.createControl(instance, "BUTTON", "运行诊断", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 162, 366, 120, 50, panelDoctor)
	p.doctorFix = p.createControl(instance, "BUTTON", "诊断并修复", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 292, 366, 120, 50, panelDoctorFix)
	p.logs = p.createControl(instance, "BUTTON", "查看日志", wsChild|wsVisible|wsTabStop|bsOwnerDraw, 422, 366, 120, 50, panelLogs)

	p.footerLabel = p.createControl(instance, "STATIC", "关闭窗口后，Mimi Remote 会继续在系统托盘中运行。", wsChild|wsVisible|ssLeft|ssNoPrefix, 24, 461, 540, 22, 0)
	p.pairTitle = p.createControl(instance, "STATIC", "扫码连接设备", wsChild|ssLeft|ssNoPrefix, 290, 100, 250, 30, 0)
	p.pairSummary = p.createControl(instance, "STATIC", "正在生成安全的短期配对二维码…", wsChild|ssLeft|ssNoPrefix, 290, 137, 250, 44, 0)
	p.pairEndpoint = p.createControl(instance, "STATIC", "连接地址：—", wsChild|ssLeft|ssNoPrefix, 290, 198, 250, 22, 0)
	p.pairExpiry = p.createControl(instance, "STATIC", "有效期：—", wsChild|ssLeft|ssNoPrefix, 290, 225, 250, 22, 0)
	p.pairWarning = p.createControl(instance, "STATIC", "二维码只包含短期票据，不包含长期访问凭据。", wsChild|ssLeft|ssNoPrefix, 290, 263, 250, 54, 0)
	p.pairBack = p.createControl(instance, "BUTTON", "返回面板", wsChild|wsTabStop|bsOwnerDraw, 32, 366, 160, 50, panelPairBack)
	p.pairCopy = p.createControl(instance, "BUTTON", "复制配对链接", wsChild|wsTabStop|bsOwnerDraw, 212, 366, 160, 50, panelPairCopy)
	p.pairRefresh = p.createControl(instance, "BUTTON", "刷新二维码", wsChild|wsTabStop|bsOwnerDraw, 392, 366, 160, 50, panelPairRefresh)

	controls := []uintptr{
		p.titleLabel, p.appVersionLabel, p.subtitleLabel, p.badgeLabel, p.statusDotLabel, p.statusLabel, p.summaryLabel,
		p.endpointLabel, p.endpointValue, p.versionLabel, p.versionValue,
		p.networkLabel, p.networkValue, p.projectsLabel, p.projectsValue,
		p.codexLabel, p.codexValue, p.claudeLabel, p.claudeValue,
		p.refresh, p.start, p.restart, p.stop, p.pair, p.doctor, p.doctorFix, p.logs,
		p.pairTitle, p.pairSummary, p.pairEndpoint, p.pairExpiry, p.pairWarning,
		p.pairBack, p.pairCopy, p.pairRefresh,
		p.footerLabel,
	}
	for _, control := range controls {
		if control == 0 {
			return errors.New("创建 Windows 控制面板控件失败")
		}
	}
	p.applyFonts()
	p.dashboardControls = []uintptr{
		p.statusDotLabel, p.statusLabel, p.summaryLabel,
		p.endpointLabel, p.endpointValue, p.versionLabel, p.versionValue,
		p.networkLabel, p.networkValue, p.projectsLabel, p.projectsValue,
		p.codexLabel, p.codexValue, p.claudeLabel, p.claudeValue,
		p.refresh, p.start, p.restart, p.stop, p.pair, p.doctor, p.doctorFix, p.logs,
	}
	p.pairingControls = []uintptr{
		p.pairTitle, p.pairSummary, p.pairEndpoint, p.pairExpiry, p.pairWarning,
		p.pairBack, p.pairCopy, p.pairRefresh,
	}
	return nil
}

func (p *controlPanel) applyFonts() {
	for _, control := range []uintptr{
		p.titleLabel, p.appVersionLabel, p.subtitleLabel, p.badgeLabel, p.statusDotLabel, p.statusLabel, p.summaryLabel,
		p.endpointLabel, p.endpointValue, p.versionLabel, p.versionValue,
		p.networkLabel, p.networkValue, p.projectsLabel, p.projectsValue,
		p.codexLabel, p.codexValue, p.claudeLabel, p.claudeValue,
		p.refresh, p.start, p.restart, p.stop, p.pair, p.doctor, p.doctorFix, p.logs,
		p.pairTitle, p.pairSummary, p.pairEndpoint, p.pairExpiry, p.pairWarning,
		p.pairBack, p.pairCopy, p.pairRefresh, p.footerLabel,
	} {
		setControlPanelFont(control, p.normalFont)
	}
	setControlPanelFont(p.titleLabel, p.titleFont)
	setControlPanelFont(p.statusDotLabel, p.statusFont)
	setControlPanelFont(p.statusLabel, p.statusFont)
	setControlPanelFont(p.pairTitle, p.statusFont)
	setControlPanelFont(p.endpointValue, p.valueFont)
	setControlPanelFont(p.versionValue, p.valueFont)
	setControlPanelFont(p.networkValue, p.valueFont)
	setControlPanelFont(p.projectsValue, p.valueFont)
	setControlPanelFont(p.codexValue, p.valueFont)
	setControlPanelFont(p.claudeValue, p.valueFont)
	for _, control := range []uintptr{p.appVersionLabel, p.subtitleLabel, p.badgeLabel, p.endpointLabel, p.versionLabel, p.networkLabel, p.projectsLabel, p.codexLabel, p.claudeLabel, p.pairEndpoint, p.pairExpiry, p.pairWarning, p.footerLabel} {
		setControlPanelFont(control, p.smallFont)
	}
	for _, control := range []uintptr{p.refresh, p.start, p.restart, p.stop, p.pair, p.doctor, p.doctorFix, p.logs, p.pairBack, p.pairCopy, p.pairRefresh} {
		setControlPanelFont(control, p.buttonFont)
	}
}

func (p *controlPanel) layoutControls() {
	type layout struct {
		control             uintptr
		x, y, width, height int
	}
	for _, item := range []layout{
		{p.titleLabel, 70, 16, 160, 30},
		{p.appVersionLabel, 238, 25, 140, 22},
		{p.subtitleLabel, 70, 45, 300, 22},
		{p.badgeLabel, 434, 25, 118, 24},
		{p.statusDotLabel, 31, 94, 24, 28},
		{p.statusLabel, 58, 94, 470, 28},
		{p.summaryLabel, 58, 124, 480, 24},
		{p.endpointLabel, 48, 162, 76, 20},
		{p.endpointValue, 134, 162, 144, 20},
		{p.versionLabel, 314, 162, 58, 20},
		{p.versionValue, 382, 162, 158, 20},
		{p.networkLabel, 48, 195, 76, 20},
		{p.networkValue, 134, 195, 144, 20},
		{p.projectsLabel, 314, 195, 58, 20},
		{p.projectsValue, 382, 195, 158, 20},
		{p.codexLabel, 48, 228, 76, 20},
		{p.codexValue, 134, 228, 144, 20},
		{p.claudeLabel, 314, 228, 76, 20},
		{p.claudeValue, 400, 228, 140, 20},
		{p.refresh, 32, 270, 120, 42},
		{p.start, 162, 270, 120, 42},
		{p.restart, 292, 270, 120, 42},
		{p.stop, 422, 270, 120, 42},
		{p.pair, 32, 366, 120, 50},
		{p.doctor, 162, 366, 120, 50},
		{p.doctorFix, 292, 366, 120, 50},
		{p.logs, 422, 366, 120, 50},
		{p.footerLabel, 24, 461, 540, 22},
		{p.pairTitle, 290, 100, 250, 30},
		{p.pairSummary, 290, 137, 250, 44},
		{p.pairEndpoint, 290, 198, 250, 22},
		{p.pairExpiry, 290, 225, 250, 22},
		{p.pairWarning, 290, 263, 250, 54},
		{p.pairBack, 32, 366, 160, 50},
		{p.pairCopy, 212, 366, 160, 50},
		{p.pairRefresh, 392, 366, 160, 50},
	} {
		if item.control == 0 {
			continue
		}
		procPanelSetWindowPos.Call(
			item.control, 0,
			uintptr(p.scale(item.x)), uintptr(p.scale(item.y)),
			uintptr(p.scale(item.width)), uintptr(p.scale(item.height)),
			swpNoZOrder|swpNoActivate,
		)
	}
}

func (p *controlPanel) handleDPIChanged(newDPI uint32, suggested *panelRect) {
	if p == nil || p.window == 0 || newDPI < defaultDPI {
		return
	}
	if suggested != nil {
		procPanelSetWindowPos.Call(
			p.window, 0,
			uintptr(suggested.Left), uintptr(suggested.Top),
			uintptr(suggested.Right-suggested.Left), uintptr(suggested.Bottom-suggested.Top),
			swpNoZOrder|swpNoActivate,
		)
	}
	if p.dpi == newDPI {
		return
	}
	oldFonts := []uintptr{p.titleFont, p.statusFont, p.normalFont, p.valueFont, p.smallFont, p.buttonFont}
	p.dpi = newDPI
	p.createFonts()
	p.applyFonts()
	p.layoutControls()
	for _, font := range oldFonts {
		if font != 0 {
			procPanelDeleteObject.Call(font)
		}
	}
	procPanelInvalidateRect.Call(p.window, 0, 1)
}

func (p *controlPanel) createControl(instance uintptr, class string, text string, style uint32, x, y, width, height int, id uint32) uintptr {
	classPointer, _ := syscall.UTF16PtrFromString(class)
	textPointer, _ := syscall.UTF16PtrFromString(text)
	control, _, _ := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(classPointer)),
		uintptr(unsafe.Pointer(textPointer)),
		uintptr(style),
		uintptr(p.scale(x)), uintptr(p.scale(y)), uintptr(p.scale(width)), uintptr(p.scale(height)),
		p.window, uintptr(id), instance, 0,
	)
	return control
}

func createControlPanelFont(height int, weight int) uintptr {
	face, _ := syscall.UTF16PtrFromString("Segoe UI")
	font, _, _ := procPanelCreateFontW.Call(
		uintptr(height), 0, 0, 0, uintptr(weight),
		0, 0, 0, defaultCharset, 0, 0, clearTypeQuality, 0,
		uintptr(unsafe.Pointer(face)),
	)
	return font
}

func createPanelBrush(color uint32) uintptr {
	brush, _, _ := procPanelCreateBrush.Call(uintptr(color))
	return brush
}

func setControlPanelFont(control uintptr, font uintptr) {
	if control == 0 || font == 0 {
		return
	}
	procPanelSendMessageW.Call(control, wmSetFont, font, 1)
}

func (p *controlPanel) syncFromApplication() {
	p.app.mu.RLock()
	status := p.app.status
	statusErr := p.app.statusErr
	busy := p.app.busy
	pairingBusy := p.app.pairingBusy
	p.app.mu.RUnlock()
	presentation := makeControlPanelPresentation(
		status,
		statusErr,
		busy,
		pairingBusy,
	)
	if !p.pairingView {
		p.statusColor = presentation.StatusColor
		p.statusBackground = presentation.StatusBackground
		p.updateStatusBrush(presentation.StatusBackground)
		setControlPanelText(p.badgeLabel, presentation.StateBadge)
	}
	setControlPanelText(p.statusLabel, presentation.StateTitle)
	setControlPanelText(p.summaryLabel, presentation.StateSummary)
	setControlPanelText(p.endpointValue, presentation.EndpointValue)
	setControlPanelText(p.versionValue, presentation.VersionValue)
	setControlPanelText(p.networkValue, presentation.NetworkValue)
	setControlPanelText(p.projectsValue, presentation.ProjectsValue)
	setControlPanelText(p.codexValue, presentation.CodexValue)
	setControlPanelText(p.claudeValue, presentation.ClaudeValue)
	p.codexStatusColor = presentation.CodexColor
	p.claudeStatusColor = presentation.ClaudeColor
	setControlPanelEnabled(p.refresh, presentation.RefreshEnabled)
	setControlPanelEnabled(p.start, presentation.StartEnabled)
	setControlPanelEnabled(p.restart, presentation.RestartEnabled)
	setControlPanelEnabled(p.stop, presentation.StopEnabled)
	setControlPanelEnabled(p.pair, presentation.PairEnabled)
	setControlPanelEnabled(p.doctor, presentation.DoctorEnabled)
	setControlPanelEnabled(p.doctorFix, presentation.FixEnabled)
	setControlPanelEnabled(p.logs, presentation.LogsEnabled)
	procPanelInvalidateRect.Call(p.window, 0, 1)
}

func (p *controlPanel) showDashboardView() {
	if p == nil || p.window == 0 {
		return
	}
	p.pairingView = false
	setControlPanelText(p.subtitleLabel, "Windows 控制面板")
	setControlPanelVisible(p.dashboardControls, true)
	setControlPanelVisible(p.pairingControls, false)
	procPanelInvalidateRect.Call(p.window, 0, 1)
}

func (p *controlPanel) showPairingView() {
	if p == nil || p.window == 0 {
		return
	}
	p.app.mu.RLock()
	ready := p.app.status.ServiceOK
	p.app.mu.RUnlock()
	if !ready {
		p.app.showError(errors.New("服务尚未就绪，请先启动服务并等待状态变为“运行正常”"))
		return
	}
	p.pairingView = true
	setControlPanelText(p.subtitleLabel, "安全连接新设备")
	setControlPanelVisible(p.dashboardControls, false)
	setControlPanelVisible(p.pairingControls, true)
	p.syncPairingControls()
	procPanelSetFocus.Call(p.pairRefresh)
	p.refreshPairing()
}

func (p *controlPanel) refreshPairing() {
	if p == nil || p.window == 0 {
		return
	}
	p.app.mu.Lock()
	if p.app.pairingBusy {
		p.app.mu.Unlock()
		return
	}
	p.app.pairingBusy = true
	p.app.mu.Unlock()

	p.pairingLoading = true
	p.pairingInfo = pairingInfo{}
	p.pairingMatrix = nil
	p.pairingErr = nil
	p.syncPairingControls()
	window := p.window
	go func() {
		ctx, cancel := actionContext()
		result, err := p.app.controller.pairing(ctx)
		cancel()
		var matrix [][]bool
		if err == nil {
			matrix, err = makePairingMatrix(result.PairURL)
		}
		p.pairingDataMu.Lock()
		p.pendingPairing = result
		p.pendingPairingMatrix = matrix
		p.pendingPairingErr = err
		p.pairingDataMu.Unlock()
		p.app.mu.Lock()
		p.app.pairingBusy = false
		p.app.mu.Unlock()
		procPostMessageW.Call(window, wmPanelPairReady, 0, 0)
	}()
}

func (p *controlPanel) finishPairingRefresh() {
	p.pairingDataMu.Lock()
	p.pairingInfo = p.pendingPairing
	p.pairingMatrix = p.pendingPairingMatrix
	p.pendingPairing = pairingInfo{}
	p.pendingPairingMatrix = nil
	err := p.pendingPairingErr
	p.pendingPairingErr = nil
	p.pairingDataMu.Unlock()
	p.pairingLoading = false
	p.pairingErr = err
	if err != nil {
		trayLogf("in-app pairing request failed: %v", err)
	}
	if p.pairingView {
		p.syncPairingControls()
	} else {
		p.syncFromApplication()
	}
}

func (p *controlPanel) syncPairingControls() {
	if p == nil || p.window == 0 || !p.pairingView {
		return
	}
	badge := "短期配对"
	color := rgbColor(80, 40, 118)
	background := rgbColor(242, 237, 248)
	title := "扫码连接设备"
	summary := "使用 iPad 或 iPhone 上的 Mimi Remote 扫描左侧二维码。"
	endpoint := "连接地址：—"
	expiry := "有效期：—"
	warning := "二维码只包含短期票据，不包含长期访问凭据。"
	ready := strings.TrimSpace(p.pairingInfo.PairURL) != "" && len(p.pairingMatrix) > 0
	err := p.pairingErr
	switch {
	case p.pairingLoading:
		badge = "正在生成"
		title = "正在生成二维码"
		summary = "正在向本机服务申请安全的短期配对票据…"
	case err != nil:
		badge = "配对失败"
		color = rgbColor(184, 42, 50)
		background = rgbColor(255, 239, 240)
		title = "无法生成二维码"
		summary = compactControlPanelError(err)
		warning = "请确认服务与网络配置正常，然后点击“刷新二维码”重试。"
	case ready:
		badge = "10 分钟有效"
		endpoint = "连接地址：" + compactControlPanelEndpoint(p.pairingInfo.Endpoint)
		expiry = "有效期：" + formatPairingExpiry(p.pairingInfo.PairExpiresAt)
		if len(p.pairingInfo.Warnings) > 0 {
			warning = truncateUTF16Text(strings.Join(p.pairingInfo.Warnings, "；"), 56)
		}
	}
	p.statusColor = color
	p.statusBackground = background
	p.updateStatusBrush(background)
	setControlPanelText(p.badgeLabel, badge)
	setControlPanelText(p.pairTitle, title)
	setControlPanelText(p.pairSummary, summary)
	setControlPanelText(p.pairEndpoint, endpoint)
	setControlPanelText(p.pairExpiry, expiry)
	setControlPanelText(p.pairWarning, warning)
	setControlPanelEnabled(p.pairBack, true)
	setControlPanelEnabled(p.pairCopy, ready && !p.pairingLoading)
	setControlPanelEnabled(p.pairRefresh, !p.pairingLoading)
	for _, control := range []uintptr{p.pairBack, p.pairCopy, p.pairRefresh} {
		procPanelInvalidateRect.Call(control, 0, 1)
	}
	procPanelInvalidateRect.Call(p.window, 0, 1)
}

func makePairingMatrix(rawURL string) ([][]bool, error) {
	if strings.TrimSpace(rawURL) == "" {
		return nil, errors.New("短期配对信息缺少二维码链接")
	}
	code, err := qrcode.New(rawURL, qrcode.Medium)
	if err != nil {
		return nil, fmt.Errorf("生成配对二维码失败：%w", err)
	}
	matrix := code.Bitmap()
	if len(matrix) == 0 || len(matrix[0]) == 0 {
		return nil, errors.New("生成的配对二维码为空")
	}
	return matrix, nil
}

func formatPairingExpiry(value string) string {
	expiresAt, err := time.Parse(time.RFC3339, strings.TrimSpace(value))
	if err != nil {
		return fallbackText(strings.TrimSpace(value), "约 10 分钟后")
	}
	return expiresAt.Local().Format("15:04") + "（约 10 分钟）"
}

func makeControlPanelPresentation(status agentStatus, statusErr error, busy bool, pairingBusy bool) controlPanelPresentation {
	neutralRuntimeColor := rgbColor(101, 101, 110)
	presentation := controlPanelPresentation{
		StateTitle:       "正在检查服务",
		StateBadge:       "正在检查",
		StateSummary:     "正在读取本机服务状态…",
		EndpointValue:    "—",
		VersionValue:     "—",
		NetworkValue:     "—",
		ProjectsValue:    "—",
		CodexValue:       "正在检查",
		ClaudeValue:      "正在检查",
		StatusColor:      rgbColor(91, 96, 108),
		StatusBackground: rgbColor(239, 240, 243),
		CodexColor:       neutralRuntimeColor,
		ClaudeColor:      neutralRuntimeColor,
		RefreshEnabled:   !busy,
		StartEnabled:     !busy && !status.ProcessOK,
		RestartEnabled:   !busy && status.ProcessOK,
		StopEnabled:      !busy && status.ProcessOK,
		PairEnabled:      !busy && status.ServiceOK && !pairingBusy,
		DoctorEnabled:    !busy,
		FixEnabled:       !busy,
		LogsEnabled:      !busy,
	}
	if statusErr != nil {
		presentation.StateTitle = "无法读取服务状态"
		presentation.StateBadge = "不可用"
		presentation.StateSummary = compactControlPanelError(statusErr)
		presentation.StatusColor = rgbColor(184, 42, 50)
		presentation.StatusBackground = rgbColor(255, 239, 240)
		presentation.NetworkValue = "检查失败"
		presentation.CodexValue = "不可用"
		presentation.ClaudeValue = "不可用"
		presentation.CodexColor = presentation.StatusColor
		presentation.ClaudeColor = presentation.StatusColor
	} else if status.Version != "" {
		presentation.StateTitle = status.lifecycleTitle()
		presentation.EndpointValue = compactControlPanelEndpoint(status.Endpoint)
		presentation.VersionValue = fallbackText(firstNonEmpty(status.ServerVersion, status.Version), "未知")
		presentation.NetworkValue = compactControlPanelNetwork(status.NetworkStatus)
		presentation.ProjectsValue = fmt.Sprintf("%d", status.Projects)
		codex := makeControlPanelRuntimePresentation(status.RuntimeStatus, "codex", status.ServiceOK)
		claude := makeControlPanelRuntimePresentation(status.RuntimeStatus, "claude", status.ServiceOK)
		presentation.CodexValue = codex.Value
		presentation.CodexColor = codex.Color
		presentation.ClaudeValue = claude.Value
		presentation.ClaudeColor = claude.Color
		switch {
		case status.lifecycleTitle() == "运行正常":
			presentation.StateTitle = "服务运行正常"
			presentation.StateBadge = "运行正常"
			presentation.StateSummary = "服务已就绪，移动设备可以连接。"
			presentation.StatusColor = rgbColor(35, 126, 58)
			presentation.StatusBackground = rgbColor(235, 247, 237)
		case status.ProcessOK:
			presentation.StateTitle = "服务需要处理"
			presentation.StateBadge = "需处理"
			presentation.StateSummary = "后台服务正在运行，但配置或依赖需要处理。"
			presentation.StatusColor = rgbColor(154, 91, 0)
			presentation.StatusBackground = rgbColor(255, 245, 226)
		default:
			presentation.StateTitle = "服务已停止"
			presentation.StateBadge = "已停止"
			presentation.StateSummary = "点击“启动服务”即可恢复连接。"
			presentation.StatusColor = rgbColor(184, 42, 50)
			presentation.StatusBackground = rgbColor(255, 239, 240)
		}
	}
	if busy {
		presentation.StateBadge = "处理中"
		presentation.StateSummary = "正在执行操作，请稍候…"
		presentation.StatusColor = rgbColor(83, 43, 122)
		presentation.StatusBackground = rgbColor(242, 237, 248)
	}
	return presentation
}

type controlPanelRuntimePresentation struct {
	Value string
	Color uint32
}

// 只使用 agentd 返回的脱敏运行时快照。available 只表示运行时可用，
// 不能提升为“已连接”；Claude 关闭时用“未配置”说明用户仍需完成设置。
func makeControlPanelRuntimePresentation(snapshot *runtimeStatus, runtimeID string, serviceAvailable bool) controlPanelRuntimePresentation {
	neutral := controlPanelRuntimePresentation{Value: "暂不可用", Color: rgbColor(101, 101, 110)}
	if !serviceAvailable {
		return controlPanelRuntimePresentation{Value: "不可用", Color: rgbColor(184, 42, 50)}
	}
	if snapshot == nil {
		return neutral
	}
	var selected *runtimeEntry
	for index := range snapshot.Runtimes {
		if strings.EqualFold(strings.TrimSpace(snapshot.Runtimes[index].ID), runtimeID) {
			selected = &snapshot.Runtimes[index]
			break
		}
	}
	if selected == nil {
		return controlPanelRuntimePresentation{Value: "状态未知", Color: neutral.Color}
	}
	if !selected.Enabled || strings.EqualFold(strings.TrimSpace(selected.State), "disabled") {
		return controlPanelRuntimePresentation{Value: "未配置", Color: neutral.Color}
	}
	if snapshot.Stale && !snapshot.Refreshing {
		return controlPanelRuntimePresentation{Value: "状态已过期", Color: rgbColor(154, 91, 0)}
	}
	if snapshot.Refreshing && strings.EqualFold(strings.TrimSpace(selected.Reason), "refresh_in_progress") {
		return controlPanelRuntimePresentation{Value: "正在检查", Color: neutral.Color}
	}
	switch strings.ToLower(strings.TrimSpace(selected.State)) {
	case "connected":
		return controlPanelRuntimePresentation{Value: "已连接", Color: rgbColor(35, 126, 58)}
	case "available":
		return controlPanelRuntimePresentation{Value: "运行时可用", Color: rgbColor(32, 99, 184)}
	case "signed_out":
		return controlPanelRuntimePresentation{Value: "未登录", Color: rgbColor(154, 91, 0)}
	case "unavailable":
		if strings.EqualFold(strings.TrimSpace(selected.Reason), "refresh_in_progress") {
			return controlPanelRuntimePresentation{Value: "正在检查", Color: neutral.Color}
		}
		return controlPanelRuntimePresentation{Value: "不可用", Color: rgbColor(184, 42, 50)}
	default:
		return controlPanelRuntimePresentation{Value: "状态未知", Color: neutral.Color}
	}
}

func compactControlPanelEndpoint(endpoint string) string {
	value := strings.TrimSpace(endpoint)
	value = strings.TrimPrefix(value, "http://")
	value = strings.TrimPrefix(value, "https://")
	return truncateUTF16Text(fallbackText(value, "尚不可用"), 28)
}

func compactControlPanelNetwork(status *networkStatus) string {
	if status == nil {
		return "尚未检测"
	}
	mode := map[string]string{
		"loopback":  "仅本机",
		"tailscale": "Tailscale",
		"lan":       "局域网",
		"specific":  "指定地址",
	}[strings.ToLower(strings.TrimSpace(status.Mode))]
	parts := []string{fallbackText(mode, "未知网络")}
	switch {
	case strings.EqualFold(strings.TrimSpace(status.NetworkCategory), "Private"):
		parts = append(parts, "专用")
	case strings.EqualFold(strings.TrimSpace(status.NetworkCategory), "Public"):
		parts = append(parts, "公用")
	case strings.EqualFold(strings.TrimSpace(status.NetworkCategory), "DomainAuthenticated"):
		parts = append(parts, "域网络")
	}
	if status.PolicyChecked && !status.PolicyOK {
		parts = append(parts, "需处理")
	}
	return truncateUTF16Text(strings.Join(parts, " · "), 18)
}

func compactControlPanelError(err error) string {
	if err == nil {
		return "未知错误"
	}
	value := strings.Join(strings.Fields(err.Error()), " ")
	return truncateUTF16Text(fallbackText(value, "未知错误"), 90)
}

func setControlPanelText(control uintptr, value string) {
	if control == 0 {
		return
	}
	pointer, _ := syscall.UTF16PtrFromString(value)
	procPanelSetWindowTextW.Call(control, uintptr(unsafe.Pointer(pointer)))
}

func setControlPanelEnabled(control uintptr, enabled bool) {
	if control == 0 {
		return
	}
	var value uintptr
	if enabled {
		value = 1
	}
	procPanelEnableWindow.Call(control, value)
}

func setControlPanelVisible(controls []uintptr, visible bool) {
	command := uintptr(swHide)
	if visible {
		command = swShow
	}
	for _, control := range controls {
		if control != 0 {
			procPanelShowWindow.Call(control, command)
		}
	}
}

func copyControlPanelText(window uintptr, value string) error {
	encoded := syscall.StringToUTF16(value)
	if len(encoded) <= 1 {
		return errors.New("没有可复制的配对链接")
	}
	opened, _, openErr := procPanelOpenClipboard.Call(window)
	if opened == 0 {
		return fmt.Errorf("打开 Windows 剪贴板失败：%v", openErr)
	}
	defer procPanelCloseClipboard.Call()
	if emptied, _, emptyErr := procPanelEmptyClipboard.Call(); emptied == 0 {
		return fmt.Errorf("清空 Windows 剪贴板失败：%v", emptyErr)
	}
	handle, _, allocErr := procPanelGlobalAlloc.Call(gmemMoveable, uintptr(len(encoded)*2))
	if handle == 0 {
		return fmt.Errorf("分配剪贴板内存失败：%v", allocErr)
	}
	pointer, _, lockErr := procPanelGlobalLock.Call(handle)
	if pointer == 0 {
		procPanelGlobalFree.Call(handle)
		return fmt.Errorf("锁定剪贴板内存失败：%v", lockErr)
	}
	procPanelMoveMemory.Call(pointer, uintptr(unsafe.Pointer(&encoded[0])), uintptr(len(encoded)*2))
	procPanelGlobalUnlock.Call(handle)
	if result, _, setErr := procPanelSetClipboardData.Call(cfUnicodeText, handle); result == 0 {
		procPanelGlobalFree.Call(handle)
		return fmt.Errorf("写入 Windows 剪贴板失败：%v", setErr)
	}
	return nil
}

func controlPanelWindowProc(window uintptr, msg uint32, wParam uintptr, lParam uintptr) uintptr {
	app := currentTray
	if app == nil || app.panel == nil {
		result, _, _ := procDefWindowProcW.Call(window, uintptr(msg), wParam, lParam)
		return result
	}
	panel := app.panel
	switch msg {
	case wmPanelPairReady:
		panel.finishPairingRefresh()
		return 0
	case wmDPIChanged:
		var suggested *panelRect
		if lParam != 0 {
			var rect panelRect
			procPanelMoveMemory.Call(
				uintptr(unsafe.Pointer(&rect)),
				lParam,
				unsafe.Sizeof(rect),
			)
			suggested = &rect
		}
		panel.handleDPIChanged(uint32(wParam)&0xffff, suggested)
		return 0
	case wmCommand:
		panel.dispatch(uint32(wParam) & 0xffff)
		return 0
	case wmClose:
		procPanelShowWindow.Call(window, swHide)
		return 0
	case wmDestroy:
		panel.window = 0
		panel.releaseResources()
		return 0
	case wmEraseBkgnd:
		panel.eraseBackground(window, wParam)
		return 1
	case wmPaint:
		panel.paint(window)
		return 0
	case wmDrawItem:
		if lParam == 0 {
			break
		}
		var item panelDrawItem
		procPanelMoveMemory.Call(
			uintptr(unsafe.Pointer(&item)),
			lParam,
			unsafe.Sizeof(item),
		)
		if item.ControlType == odtButton {
			panel.drawActionButton(&item)
			return 1
		}
	case wmCtlColorStatic:
		procPanelSetBkMode.Call(wParam, transparentMode)
		procPanelSetTextColor.Call(wParam, uintptr(panel.staticTextColor(lParam)))
		return panel.staticBackgroundBrush(lParam)
	}
	result, _, _ := procDefWindowProcW.Call(window, uintptr(msg), wParam, lParam)
	return result
}

func (p *controlPanel) eraseBackground(window uintptr, dc uintptr) {
	if dc == 0 || p.backgroundBrush == 0 {
		return
	}
	var client panelRect
	procPanelGetClientRect.Call(window, uintptr(unsafe.Pointer(&client)))
	procPanelFillRect.Call(dc, uintptr(unsafe.Pointer(&client)), p.backgroundBrush)
}

func (p *controlPanel) paint(window uintptr) {
	var paint panelPaintStruct
	dc, _, _ := procPanelBeginPaint.Call(window, uintptr(unsafe.Pointer(&paint)))
	if dc == 0 {
		return
	}
	defer procPanelEndPaint.Call(window, uintptr(unsafe.Pointer(&paint)))
	p.eraseBackground(window, dc)

	if p.app.icon != 0 {
		procPanelDrawIconEx.Call(dc, uintptr(p.scale(24)), uintptr(p.scale(18)), p.app.icon, uintptr(p.scale(34)), uintptr(p.scale(34)), 0, 0, diNormal)
	}
	if p.pairingView {
		drawPanelRoundedRect(dc, p.scaledRect(16, 76, 568, 326), p.scale32(16), rgbColor(255, 255, 255), rgbColor(229, 229, 234))
		drawPanelRoundedRect(dc, p.scaledRect(32, 92, 274, 326), p.scale32(12), rgbColor(255, 255, 255), rgbColor(232, 232, 236))
		p.drawPairingQRCode(dc, p.scaledRect(46, 98, 260, 312))
	} else {
		drawPanelRoundedRect(dc, p.scaledRect(16, 76, 568, 326), p.scale32(16), rgbColor(255, 255, 255), rgbColor(229, 229, 234))
		drawPanelRoundedRect(dc, p.scaledRect(32, 154, 552, 254), p.scale32(10), rgbColor(249, 249, 251), rgbColor(232, 232, 236))
		drawPanelLine(dc, p.scale32(48), p.scale32(188), p.scale32(536), p.scale32(188), rgbColor(229, 229, 233), max(1, p.scale(1)))
		drawPanelLine(dc, p.scale32(48), p.scale32(221), p.scale32(536), p.scale32(221), rgbColor(229, 229, 233), max(1, p.scale(1)))
		drawPanelLine(dc, p.scale32(298), p.scale32(160), p.scale32(298), p.scale32(248), rgbColor(229, 229, 233), max(1, p.scale(1)))
	}
	drawPanelRoundedRect(dc, p.scaledRect(16, 340, 568, 440), p.scale32(14), rgbColor(255, 255, 255), rgbColor(229, 229, 234))
	drawPanelRoundedRect(dc, p.scaledRect(430, 20, 560, 54), p.scale32(17), p.statusBackground, p.statusBackground)
}

func (p *controlPanel) drawPairingQRCode(dc uintptr, bounds panelRect) {
	if dc == 0 {
		return
	}
	if len(p.pairingMatrix) == 0 || len(p.pairingMatrix[0]) == 0 {
		message := "正在生成…"
		if !p.pairingLoading {
			message = "暂无二维码"
		}
		drawPanelText(dc, message, &bounds, p.normalFont, rgbColor(118, 118, 126), dtCenter|dtVCenter|dtSingleLine|dtNoPrefix)
		return
	}
	rows := len(p.pairingMatrix)
	columns := len(p.pairingMatrix[0])
	quietZone := 4
	availableWidth := int(bounds.Right - bounds.Left)
	availableHeight := int(bounds.Bottom - bounds.Top)
	moduleSize := availableWidth / (columns + quietZone*2)
	if candidate := availableHeight / (rows + quietZone*2); candidate < moduleSize {
		moduleSize = candidate
	}
	if moduleSize < 1 {
		return
	}
	qrWidth := (columns + quietZone*2) * moduleSize
	qrHeight := (rows + quietZone*2) * moduleSize
	originX := bounds.Left + int32((availableWidth-qrWidth)/2+quietZone*moduleSize)
	originY := bounds.Top + int32((availableHeight-qrHeight)/2+quietZone*moduleSize)
	brush := createPanelBrush(rgbColor(24, 24, 27))
	if brush == 0 {
		return
	}
	defer procPanelDeleteObject.Call(brush)
	for row, values := range p.pairingMatrix {
		for column, dark := range values {
			if !dark {
				continue
			}
			rect := panelRect{
				Left:   originX + int32(column*moduleSize),
				Top:    originY + int32(row*moduleSize),
				Right:  originX + int32((column+1)*moduleSize),
				Bottom: originY + int32((row+1)*moduleSize),
			}
			procPanelFillRect.Call(dc, uintptr(unsafe.Pointer(&rect)), brush)
		}
	}
}

func (p *controlPanel) staticTextColor(control uintptr) uint32 {
	switch control {
	case p.statusDotLabel, p.statusLabel, p.badgeLabel:
		return p.statusColor
	case p.codexValue:
		return p.codexStatusColor
	case p.claudeValue:
		return p.claudeStatusColor
	case p.titleLabel, p.pairTitle, p.endpointValue, p.versionValue, p.networkValue, p.projectsValue:
		return rgbColor(27, 27, 31)
	default:
		return rgbColor(101, 101, 110)
	}
}

func (p *controlPanel) staticBackgroundBrush(control uintptr) uintptr {
	switch control {
	case p.titleLabel, p.appVersionLabel, p.subtitleLabel, p.footerLabel:
		return p.backgroundBrush
	case p.badgeLabel:
		return p.statusBrush
	case p.endpointLabel, p.endpointValue, p.versionLabel, p.versionValue, p.networkLabel, p.networkValue, p.projectsLabel, p.projectsValue,
		p.codexLabel, p.codexValue, p.claudeLabel, p.claudeValue:
		return p.detailBrush
	default:
		return p.cardBrush
	}
}

func (p *controlPanel) drawActionButton(item *panelDrawItem) {
	if item == nil || item.DC == 0 {
		return
	}
	disabled := item.ItemState&odsDisabled != 0
	selected := item.ItemState&odsSelected != 0
	focused := item.ItemState&odsFocus != 0
	fill := rgbColor(255, 255, 255)
	border := rgbColor(220, 220, 226)
	textColor := rgbColor(36, 35, 41)
	iconColor := rgbColor(69, 32, 105)
	if item.ControlID == panelStop {
		fill = rgbColor(255, 248, 248)
		border = rgbColor(241, 208, 209)
		textColor = rgbColor(190, 36, 43)
		iconColor = textColor
	}
	if item.ControlID == panelStart && !disabled {
		fill = rgbColor(80, 40, 118)
		border = fill
		textColor = rgbColor(255, 255, 255)
		iconColor = textColor
	}
	if selected {
		switch item.ControlID {
		case panelStart:
			fill = rgbColor(63, 29, 94)
		case panelStop:
			fill = rgbColor(255, 236, 237)
		default:
			fill = rgbColor(241, 237, 247)
		}
	}
	if focused && !disabled {
		border = rgbColor(94, 51, 136)
	}
	if disabled {
		fill = rgbColor(244, 244, 246)
		border = rgbColor(229, 229, 233)
		textColor = rgbColor(169, 169, 176)
		iconColor = textColor
	}
	drawPanelRoundedRect(item.DC, item.Rect, p.scale32(10), fill, border)
	iconSize := p.scale32(16)
	p.drawButtonIcon(item.DC, item.ControlID, item.Rect.Left+p.scale32(16), item.Rect.Top+(item.Rect.Bottom-item.Rect.Top-iconSize)/2, iconColor)
	textRect := item.Rect
	textRect.Left += p.scale32(36)
	textRect.Right -= p.scale32(8)
	drawPanelText(item.DC, panelActionLabel(item.ControlID), &textRect, p.buttonFont, textColor, dtCenter|dtVCenter|dtSingleLine|dtNoPrefix|dtEndEllipsis)
}

func panelActionLabel(command uint32) string {
	switch command {
	case panelRefresh:
		return "刷新状态"
	case panelStart:
		return "启动服务"
	case panelRestart:
		return "重新启动"
	case panelStop:
		return "停止服务"
	case panelPair:
		return "配对设备"
	case panelDoctor:
		return "运行诊断"
	case panelDoctorFix:
		return "诊断并修复"
	case panelLogs:
		return "查看日志"
	case panelPairBack:
		return "返回面板"
	case panelPairCopy:
		return "复制配对链接"
	case panelPairRefresh:
		return "刷新二维码"
	default:
		return "操作"
	}
}

func (p *controlPanel) drawButtonIcon(dc uintptr, command uint32, x int32, y int32, color uint32) {
	s := p.scale32
	pen := createPanelPen(color, max(1, p.scale(2)))
	if pen == 0 {
		return
	}
	oldPen, _, _ := procPanelSelectObject.Call(dc, pen)
	nullBrush, _, _ := procPanelGetStockObject.Call(stockNullBrush)
	oldBrush, _, _ := procPanelSelectObject.Call(dc, nullBrush)
	defer func() {
		procPanelSelectObject.Call(dc, oldBrush)
		procPanelSelectObject.Call(dc, oldPen)
		procPanelDeleteObject.Call(pen)
	}()

	switch command {
	case panelRefresh, panelRestart, panelPairRefresh:
		procPanelEllipse.Call(dc, uintptr(x+s(1)), uintptr(y+s(1)), uintptr(x+s(15)), uintptr(y+s(15)))
		drawPanelPolyline(dc, []point{{X: x + s(12), Y: y}, {X: x + s(16), Y: y + s(3)}, {X: x + s(12), Y: y + s(6)}})
	case panelStart:
		brush := createPanelBrush(color)
		oldFill, _, _ := procPanelSelectObject.Call(dc, brush)
		points := []point{{X: x + s(4), Y: y + s(2)}, {X: x + s(14), Y: y + s(8)}, {X: x + s(4), Y: y + s(14)}}
		procPanelPolygon.Call(dc, uintptr(unsafe.Pointer(&points[0])), uintptr(len(points)))
		procPanelSelectObject.Call(dc, oldFill)
		procPanelDeleteObject.Call(brush)
	case panelStop:
		procPanelRoundRect.Call(dc, uintptr(x+s(3)), uintptr(y+s(3)), uintptr(x+s(13)), uintptr(y+s(13)), uintptr(s(3)), uintptr(s(3)))
	case panelPair:
		procPanelRoundRect.Call(dc, uintptr(x+s(4)), uintptr(y), uintptr(x+s(13)), uintptr(y+s(16)), uintptr(s(3)), uintptr(s(3)))
		drawPanelLineWithCurrentPen(dc, x+s(7), y+s(13), x+s(10), y+s(13))
	case panelDoctor:
		drawPanelPolyline(dc, []point{{X: x, Y: y + s(9)}, {X: x + s(4), Y: y + s(9)}, {X: x + s(6), Y: y + s(3)}, {X: x + s(9), Y: y + s(14)}, {X: x + s(11), Y: y + s(9)}, {X: x + s(16), Y: y + s(9)}})
	case panelDoctorFix:
		procPanelEllipse.Call(dc, uintptr(x+s(1)), uintptr(y+s(1)), uintptr(x+s(15)), uintptr(y+s(15)))
		drawPanelLineWithCurrentPen(dc, x+s(8), y+s(4), x+s(8), y+s(12))
		drawPanelLineWithCurrentPen(dc, x+s(4), y+s(8), x+s(12), y+s(8))
	case panelLogs:
		procPanelRectangle.Call(dc, uintptr(x+s(3)), uintptr(y+s(1)), uintptr(x+s(14)), uintptr(y+s(15)))
		drawPanelLineWithCurrentPen(dc, x+s(6), y+s(6), x+s(11), y+s(6))
		drawPanelLineWithCurrentPen(dc, x+s(6), y+s(10), x+s(11), y+s(10))
	case panelPairBack:
		drawPanelPolyline(dc, []point{{X: x + s(13), Y: y + s(2)}, {X: x + s(6), Y: y + s(8)}, {X: x + s(13), Y: y + s(14)}})
	case panelPairCopy:
		procPanelRoundRect.Call(dc, uintptr(x+s(1)), uintptr(y+s(4)), uintptr(x+s(11)), uintptr(y+s(15)), uintptr(s(3)), uintptr(s(3)))
		procPanelRoundRect.Call(dc, uintptr(x+s(5)), uintptr(y), uintptr(x+s(15)), uintptr(y+s(11)), uintptr(s(3)), uintptr(s(3)))
	}
}

func drawPanelRoundedRect(dc uintptr, rect panelRect, radius int32, fill uint32, border uint32) {
	brush := createPanelBrush(fill)
	pen := createPanelPen(border, 1)
	if brush == 0 || pen == 0 {
		if brush != 0 {
			procPanelDeleteObject.Call(brush)
		}
		if pen != 0 {
			procPanelDeleteObject.Call(pen)
		}
		return
	}
	oldBrush, _, _ := procPanelSelectObject.Call(dc, brush)
	oldPen, _, _ := procPanelSelectObject.Call(dc, pen)
	procPanelRoundRect.Call(dc, uintptr(rect.Left), uintptr(rect.Top), uintptr(rect.Right), uintptr(rect.Bottom), uintptr(radius), uintptr(radius))
	procPanelSelectObject.Call(dc, oldPen)
	procPanelSelectObject.Call(dc, oldBrush)
	procPanelDeleteObject.Call(pen)
	procPanelDeleteObject.Call(brush)
}

func drawPanelCircle(dc uintptr, x int32, y int32, size int32, color uint32) {
	brush := createPanelBrush(color)
	pen := createPanelPen(color, 1)
	if brush == 0 || pen == 0 {
		return
	}
	oldBrush, _, _ := procPanelSelectObject.Call(dc, brush)
	oldPen, _, _ := procPanelSelectObject.Call(dc, pen)
	procPanelEllipse.Call(dc, uintptr(x), uintptr(y), uintptr(x+size), uintptr(y+size))
	procPanelSelectObject.Call(dc, oldPen)
	procPanelSelectObject.Call(dc, oldBrush)
	procPanelDeleteObject.Call(pen)
	procPanelDeleteObject.Call(brush)
}

func drawPanelLine(dc uintptr, x1 int32, y1 int32, x2 int32, y2 int32, color uint32, width int) {
	pen := createPanelPen(color, width)
	if pen == 0 {
		return
	}
	oldPen, _, _ := procPanelSelectObject.Call(dc, pen)
	drawPanelLineWithCurrentPen(dc, x1, y1, x2, y2)
	procPanelSelectObject.Call(dc, oldPen)
	procPanelDeleteObject.Call(pen)
}

func drawPanelLineWithCurrentPen(dc uintptr, x1 int32, y1 int32, x2 int32, y2 int32) {
	procPanelMoveToEx.Call(dc, uintptr(x1), uintptr(y1), 0)
	procPanelLineTo.Call(dc, uintptr(x2), uintptr(y2))
}

func drawPanelPolyline(dc uintptr, points []point) {
	if len(points) < 2 {
		return
	}
	procPanelMoveToEx.Call(dc, uintptr(points[0].X), uintptr(points[0].Y), 0)
	for _, value := range points[1:] {
		procPanelLineTo.Call(dc, uintptr(value.X), uintptr(value.Y))
	}
}

func drawPanelText(dc uintptr, text string, rect *panelRect, font uintptr, color uint32, flags uint32) {
	if dc == 0 || rect == nil {
		return
	}
	pointer, _ := syscall.UTF16PtrFromString(text)
	oldFont, _, _ := procPanelSelectObject.Call(dc, font)
	procPanelSetBkMode.Call(dc, transparentMode)
	procPanelSetTextColor.Call(dc, uintptr(color))
	procPanelDrawTextW.Call(dc, uintptr(unsafe.Pointer(pointer)), ^uintptr(0), uintptr(unsafe.Pointer(rect)), uintptr(flags))
	procPanelSelectObject.Call(dc, oldFont)
}

func createPanelPen(color uint32, width int) uintptr {
	pen, _, _ := procPanelCreatePen.Call(penStyleSolid, uintptr(width), uintptr(color))
	return pen
}

func (p *controlPanel) updateStatusBrush(color uint32) {
	if p.statusBrush != 0 {
		procPanelDeleteObject.Call(p.statusBrush)
	}
	p.statusBrush = createPanelBrush(color)
}

func (p *controlPanel) dispatch(command uint32) {
	switch command {
	case panelRefresh:
		p.app.refreshStatusInteractive()
	case panelStart:
		p.app.runAction("启动", "start")
	case panelRestart:
		p.app.runAction("重新启动", "restart")
	case panelStop:
		p.app.runAction("停止", "stop")
	case panelPair:
		p.app.requestPairing()
	case panelDoctor:
		p.app.runDoctor(false)
	case panelDoctorFix:
		p.app.runDoctor(true)
	case panelLogs:
		if err := p.app.controller.openLogsTerminal(); err != nil {
			p.app.showError(err)
		}
	case panelPairBack:
		p.showDashboardView()
		p.syncFromApplication()
		procPanelSetFocus.Call(p.refresh)
	case panelPairCopy:
		if err := copyControlPanelText(p.window, p.pairingInfo.PairURL); err != nil {
			setControlPanelText(p.pairSummary, compactControlPanelError(err))
		} else {
			setControlPanelText(p.pairSummary, "配对链接已复制。请在 10 分钟内使用。")
		}
	case panelPairRefresh:
		p.refreshPairing()
	}
}

func (p *controlPanel) releaseResources() {
	for _, font := range []*uintptr{&p.titleFont, &p.statusFont, &p.normalFont, &p.valueFont, &p.smallFont, &p.buttonFont} {
		if *font != 0 {
			procPanelDeleteObject.Call(*font)
			*font = 0
		}
	}
	for _, brush := range []*uintptr{&p.backgroundBrush, &p.cardBrush, &p.detailBrush, &p.statusBrush} {
		if *brush != 0 {
			procPanelDeleteObject.Call(*brush)
			*brush = 0
		}
	}
}

func rgbColor(red uint8, green uint8, blue uint8) uint32 {
	return uint32(red) | uint32(green)<<8 | uint32(blue)<<16
}
