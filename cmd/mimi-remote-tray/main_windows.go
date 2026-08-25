//go:build windows

package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	trayWindowClass = "MimiRemoteTrayWindow"
	trayMutexName   = "Local\\MimiRemoteTray-7D413E71-19C5-4F02-8AFC-437E1B8019FD"
	trayIconID      = 1

	wmDestroy      = 0x0002
	wmClose        = 0x0010
	wmCommand      = 0x0111
	wmNull         = 0x0000
	wmContextMenu  = 0x007B
	wmLButtonDblCl = 0x0203
	wmRButtonUp    = 0x0205
	wmApp          = 0x8000

	wmTrayCallback = wmApp + 1
	wmTrayRefresh  = wmApp + 2
	wmTrayShow     = wmApp + 3
	wmTrayPair     = wmApp + 4

	nimAdd        = 0x00000000
	nimModify     = 0x00000001
	nimDelete     = 0x00000002
	nimSetVersion = 0x00000004
	notifyVersion = 4

	nifMessage = 0x00000001
	nifIcon    = 0x00000002
	nifTip     = 0x00000004
	nifInfo    = 0x00000010

	niifInfo    = 0x00000001
	niifWarning = 0x00000002
	niifError   = 0x00000003

	mfString    = 0x00000000
	mfGray      = 0x00000001
	mfSeparator = 0x00000800

	tpmRightButton = 0x0002
	tpmReturnCmd   = 0x0100
	tpmNoNotify    = 0x0080

	mbOK          = 0x00000000
	mbIconInfo    = 0x00000040
	mbIconWarning = 0x00000030
	mbIconError   = 0x00000010
	mbYesNo       = 0x00000004
	idYes         = 6

	idiApplication = 32512
	idcArrow       = 32512
	imageIcon      = 1
	lrLoadFromFile = 0x00000010
	lrDefaultSize  = 0x00000040

	errorAlreadyExists syscall.Errno = 183
)

const (
	menuStatus = 100 + iota
	menuRefresh
	menuStart
	menuRestart
	menuStop
	menuPair
	menuDoctor
	menuLogs
	menuExitAndStop
	menuDoctorFix
	menuControlPanel
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")

	procRegisterClassExW      = user32.NewProc("RegisterClassExW")
	procCreateWindowExW       = user32.NewProc("CreateWindowExW")
	procDefWindowProcW        = user32.NewProc("DefWindowProcW")
	procDestroyWindow         = user32.NewProc("DestroyWindow")
	procGetMessageW           = user32.NewProc("GetMessageW")
	procTranslateMessage      = user32.NewProc("TranslateMessage")
	procDispatchMessageW      = user32.NewProc("DispatchMessageW")
	procPostQuitMessage       = user32.NewProc("PostQuitMessage")
	procPostMessageW          = user32.NewProc("PostMessageW")
	procCreatePopupMenu       = user32.NewProc("CreatePopupMenu")
	procAppendMenuW           = user32.NewProc("AppendMenuW")
	procTrackPopupMenu        = user32.NewProc("TrackPopupMenu")
	procDestroyMenu           = user32.NewProc("DestroyMenu")
	procGetCursorPos          = user32.NewProc("GetCursorPos")
	procSetForegroundWindow   = user32.NewProc("SetForegroundWindow")
	procMessageBoxW           = user32.NewProc("MessageBoxW")
	procLoadIconW             = user32.NewProc("LoadIconW")
	procLoadImageW            = user32.NewProc("LoadImageW")
	procLoadCursorW           = user32.NewProc("LoadCursorW")
	procDestroyIcon           = user32.NewProc("DestroyIcon")
	procRegisterWindowMessage = user32.NewProc("RegisterWindowMessageW")
	procEnumWindows           = user32.NewProc("EnumWindows")
	procGetClassNameW         = user32.NewProc("GetClassNameW")
	procSetProcessDPIContext  = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetProcessDPIAware    = user32.NewProc("SetProcessDPIAware")

	procShellNotifyIconW = shell32.NewProc("Shell_NotifyIconW")
	procGetModuleHandleW = kernel32.NewProc("GetModuleHandleW")
	procCreateMutexW     = kernel32.NewProc("CreateMutexW")
)

var (
	foundTrayWindow        uintptr
	trayWindowEnumCallback = syscall.NewCallback(findTrayWindowCallback)
)

type point struct {
	X int32
	Y int32
}

type message struct {
	Window  uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Point   point
	Private uint32
}

type windowClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   uintptr
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSmall  uintptr
}

type notifyIconData struct {
	Size             uint32
	Window           uintptr
	ID               uint32
	Flags            uint32
	CallbackMessage  uint32
	Icon             uintptr
	Tip              [128]uint16
	State            uint32
	StateMask        uint32
	Info             [256]uint16
	VersionOrTimeout uint32
	InfoTitle        [64]uint16
	InfoFlags        uint32
	GUIDItem         [16]byte
	BalloonIcon      uintptr
}

type trayApplication struct {
	window         uintptr
	icon           uintptr
	ownsIcon       bool
	taskbarCreated uint32
	controller     *agentController
	mu             sync.RWMutex
	status         agentStatus
	statusErr      error
	busy           bool
	pairingBusy    bool
	quitting       bool
	initialPairing bool
	initialShow    bool
	refreshStop    chan struct{}
	panel          *controlPanel
}

var currentTray *trayApplication

func main() {
	pairAfterInstall := flag.Bool("pair", false, "启动后打开本机配对窗口")
	showAfterStart := flag.Bool("show", false, "启动后打开 Windows 控制面板")
	serviceHost := flag.Bool("service-host", false, "内部：无窗口托管 Windows agentd 服务")
	serviceAgentPath := flag.String("service-agent-path", "", "内部：Windows agentd 服务程序路径")
	serviceLogPath := flag.String("service-log-path", "", "内部：Windows agentd 服务日志路径")
	flag.Parse()
	if *serviceHost {
		if err := runManagedServiceHost(*serviceAgentPath, *serviceLogPath); err != nil {
			appendManagedServiceHostError(*serviceLogPath, err)
			os.Exit(1)
		}
		return
	}

	enablePerMonitorDPIAwareness()

	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	controller, err := newAgentController()
	if err != nil {
		showMessage(0, "Mimi Remote", err.Error(), mbOK|mbIconError)
		return
	}
	app := &trayApplication{
		controller:     controller,
		initialPairing: *pairAfterInstall,
		initialShow:    *showAfterStart,
		refreshStop:    make(chan struct{}),
	}
	if err := app.run(); err != nil {
		showMessage(0, "Mimi Remote", err.Error(), mbOK|mbIconError)
	}
}

func enablePerMonitorDPIAwareness() {
	// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is the signed handle value -4.
	// Find first so the tray can still start on older Windows versions.
	if procSetProcessDPIContext.Find() == nil {
		if result, _, _ := procSetProcessDPIContext.Call(^uintptr(3)); result != 0 {
			return
		}
	}
	if procSetProcessDPIAware.Find() == nil {
		procSetProcessDPIAware.Call()
	}
}

func (a *trayApplication) run() error {
	alreadyRunning, mutexHandle, err := acquireTrayMutex()
	if err != nil {
		return err
	}
	if mutexHandle == 0 {
		return errors.New("无法创建托盘单实例锁")
	}
	if alreadyRunning {
		messageID := uintptr(wmTrayShow)
		if a.initialPairing {
			messageID = wmTrayPair
		}
		if existing := findTrayWindow(); existing != 0 {
			procPostMessageW.Call(existing, messageID, 0, 0)
		}
		return nil
	}

	if err := a.createWindow(); err != nil {
		return err
	}
	currentTray = a
	if err := a.addIcon(); err != nil {
		return err
	}
	defer a.removeIcon()
	defer close(a.refreshStop)

	go a.bootstrap()
	go a.refreshLoop()
	if a.initialShow {
		a.showControlPanel()
	}

	var msg message
	for {
		result, _, callErr := procGetMessageW.Call(
			uintptr(unsafe.Pointer(&msg)),
			0,
			0,
			0,
		)
		if int32(result) == -1 {
			return fmt.Errorf("读取 Windows 托盘消息失败：%v", callErr)
		}
		if result == 0 {
			return nil
		}
		if translateControlPanelMessage(a.panel, &msg) {
			continue
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
	}
}

func acquireTrayMutex() (bool, uintptr, error) {
	name, err := syscall.UTF16PtrFromString(trayMutexName)
	if err != nil {
		return false, 0, err
	}
	handle, _, callErr := procCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(name)))
	if handle == 0 {
		return false, 0, fmt.Errorf("创建托盘单实例锁失败：%v", callErr)
	}
	return errors.Is(callErr, errorAlreadyExists), handle, nil
}

func findTrayWindow() uintptr {
	// FindWindow does not consistently return a hidden, zero-style top-level
	// window. Enumerating top-level windows does, so use the class name as the
	// stable identifier for the existing tray instance.
	foundTrayWindow = 0
	procEnumWindows.Call(trayWindowEnumCallback, 0)
	return foundTrayWindow
}

func findTrayWindowCallback(window uintptr, _ uintptr) uintptr {
	var className [128]uint16
	length, _, _ := procGetClassNameW.Call(
		window,
		uintptr(unsafe.Pointer(&className[0])),
		uintptr(len(className)),
	)
	if length == 0 || syscall.UTF16ToString(className[:int(length)]) != trayWindowClass {
		return 1
	}
	foundTrayWindow = window
	return 0
}

func loadTrayIcon() (uintptr, bool) {
	if executable, err := os.Executable(); err == nil {
		iconPath := filepath.Join(filepath.Dir(executable), "mimi-remote.ico")
		if icon := loadIconFromPath(iconPath); icon != 0 {
			return icon, true
		}
	}
	// Keep a system fallback so a damaged or partially upgraded installation
	// still exposes service controls instead of failing to start the tray.
	icon, _, _ := procLoadIconW.Call(0, idiApplication)
	return icon, false
}

func loadIconFromPath(path string) uintptr {
	encodedPath, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0
	}
	icon, _, _ := procLoadImageW.Call(
		0,
		uintptr(unsafe.Pointer(encodedPath)),
		imageIcon,
		0,
		0,
		lrLoadFromFile|lrDefaultSize,
	)
	return icon
}

func (a *trayApplication) createWindow() error {
	instance, _, err := procGetModuleHandleW.Call(0)
	if instance == 0 {
		return fmt.Errorf("获取 Windows 模块句柄失败：%v", err)
	}
	className, _ := syscall.UTF16PtrFromString(trayWindowClass)
	icon, ownsIcon := loadTrayIcon()
	cursor, _, _ := procLoadCursorW.Call(0, idcArrow)
	class := windowClassEx{
		Size:      uint32(unsafe.Sizeof(windowClassEx{})),
		WndProc:   syscall.NewCallback(trayWindowProc),
		Instance:  instance,
		Icon:      icon,
		Cursor:    cursor,
		ClassName: className,
		IconSmall: icon,
	}
	registered, _, registerErr := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&class)))
	if registered == 0 {
		if ownsIcon {
			procDestroyIcon.Call(icon)
		}
		return fmt.Errorf("注册 Windows 托盘窗口失败：%v", registerErr)
	}
	title, _ := syscall.UTF16PtrFromString("Mimi Remote")
	window, _, createErr := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(title)),
		0,
		0, 0, 0, 0,
		0, 0, instance, 0,
	)
	if window == 0 {
		if ownsIcon {
			procDestroyIcon.Call(icon)
		}
		return fmt.Errorf("创建 Windows 托盘窗口失败：%v", createErr)
	}
	taskbarCreatedName, _ := syscall.UTF16PtrFromString("TaskbarCreated")
	taskbarCreated, _, _ := procRegisterWindowMessage.Call(uintptr(unsafe.Pointer(taskbarCreatedName)))
	a.window = window
	a.icon = icon
	a.ownsIcon = ownsIcon
	a.taskbarCreated = uint32(taskbarCreated)
	return nil
}

func trayWindowProc(window uintptr, msg uint32, wParam uintptr, lParam uintptr) uintptr {
	app := currentTray
	if app == nil {
		result, _, _ := procDefWindowProcW.Call(window, uintptr(msg), wParam, lParam)
		return result
	}
	if msg == app.taskbarCreated {
		_ = app.addIcon()
		return 0
	}
	switch msg {
	case wmTrayCallback:
		switch uint32(lParam) & 0xffff {
		case wmContextMenu, wmRButtonUp:
			app.showMenu()
		case wmLButtonDblCl:
			app.showControlPanel()
		}
		return 0
	case wmTrayRefresh:
		app.modifyIcon()
		app.syncControlPanel()
		return 0
	case wmTrayShow:
		app.showControlPanel()
		return 0
	case wmTrayPair:
		app.showPairingPanel()
		return 0
	case wmCommand:
		app.dispatchMenu(uint32(wParam) & 0xffff)
		return 0
	case wmClose:
		procDestroyWindow.Call(window)
		return 0
	case wmDestroy:
		app.destroyControlPanel()
		app.removeIcon()
		if app.ownsIcon && app.icon != 0 {
			procDestroyIcon.Call(app.icon)
			app.icon = 0
			app.ownsIcon = false
		}
		procPostQuitMessage.Call(0)
		return 0
	}
	result, _, _ := procDefWindowProcW.Call(window, uintptr(msg), wParam, lParam)
	return result
}

func (a *trayApplication) iconData(flags uint32) notifyIconData {
	data := notifyIconData{
		Size:            uint32(unsafe.Sizeof(notifyIconData{})),
		Window:          a.window,
		ID:              trayIconID,
		Flags:           flags,
		CallbackMessage: wmTrayCallback,
		Icon:            a.icon,
	}
	a.mu.RLock()
	tooltip := "Mimi Remote - 正在检查服务"
	if a.status.Version != "" {
		tooltip = a.status.tooltip()
	} else if a.statusErr != nil {
		tooltip = "Mimi Remote - 服务不可用"
	}
	if a.busy {
		tooltip = "Mimi Remote - 正在执行操作"
	}
	a.mu.RUnlock()
	copy(data.Tip[:], syscall.StringToUTF16(tooltip))
	return data
}

func (a *trayApplication) addIcon() error {
	data := a.iconData(nifMessage | nifIcon | nifTip)
	result, _, err := procShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&data)))
	if result == 0 {
		return fmt.Errorf("添加 Windows 托盘图标失败：%v", err)
	}
	data.VersionOrTimeout = notifyVersion
	procShellNotifyIconW.Call(nimSetVersion, uintptr(unsafe.Pointer(&data)))
	return nil
}

func (a *trayApplication) modifyIcon() {
	data := a.iconData(nifMessage | nifIcon | nifTip)
	procShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(&data)))
}

func (a *trayApplication) removeIcon() {
	if a.window == 0 {
		return
	}
	data := a.iconData(0)
	procShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&data)))
}

func (a *trayApplication) bootstrap() {
	// The installer can restart agentd immediately before the tray starts. A
	// single status check in that short gap used to leave the tray showing an
	// unavailable service until the next 20-second refresh, making a manual
	// start look necessary. Retry the initial handshake a few times instead.
	for attempt := 0; attempt < 3; attempt++ {
		ctx, cancel := statusContext()
		status, err := a.controller.status(ctx)
		cancel()
		if err != nil {
			trayLogf("bootstrap status check %d failed: %v", attempt+1, err)
		}
		if err == nil && !status.ProcessOK {
			trayLogf("bootstrap status check %d found agentd stopped; starting it", attempt+1)
			actionCtx, actionCancel := actionContext()
			_ = a.controller.action(actionCtx, "start")
			actionCancel()
		}
		a.refreshStatus()

		a.mu.RLock()
		ready := a.status.ServiceOK
		a.mu.RUnlock()
		if ready {
			trayLogf("bootstrap reached a ready service state on check %d", attempt+1)
			break
		}
		if attempt < 2 {
			time.Sleep(2 * time.Second)
		}
	}
	if a.initialPairing {
		trayLogf("startup requested the in-app pairing view")
		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			a.mu.RLock()
			ready := a.status.ServiceOK
			a.mu.RUnlock()
			if ready {
				break
			}
			time.Sleep(time.Second)
			a.refreshStatus()
		}
		// Startup readiness runs on a worker. Post the request through the hidden
		// tray window so all native control creation stays on the UI thread.
		a.requestPairing()
	}
}

func (a *trayApplication) refreshLoop() {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			a.refreshStatus()
		case <-a.refreshStop:
			return
		}
	}
}

func (a *trayApplication) refreshStatus() {
	ctx, cancel := statusContext()
	status, err := a.controller.status(ctx)
	cancel()
	a.mu.Lock()
	a.status = status
	a.statusErr = err
	a.mu.Unlock()
	procPostMessageW.Call(a.window, wmTrayRefresh, 0, 0)
}

func (a *trayApplication) showMenu() {
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)

	a.mu.RLock()
	status := a.status
	statusErr := a.statusErr
	busy := a.busy
	pairingBusy := a.pairingBusy
	a.mu.RUnlock()

	header := "状态：" + status.lifecycleTitle()
	if status.Version == "" {
		header = "状态：正在检查"
	}
	if statusErr != nil {
		header = "状态：服务不可用"
	}
	appendMenu(menu, mfString, menuControlPanel, "打开控制面板")
	appendMenu(menu, mfSeparator, 0, "")
	appendMenu(menu, mfString|mfGray, menuStatus, header)
	appendMenu(menu, mfString, menuRefresh, "刷新状态")
	appendMenu(menu, mfSeparator, 0, "")
	appendMenu(menu, menuFlags(busy || status.ProcessOK), menuStart, "启动服务")
	appendMenu(menu, menuFlags(busy || !status.ProcessOK), menuRestart, "重新启动服务")
	appendMenu(menu, menuFlags(busy || !status.ProcessOK), menuStop, "停止服务")
	appendMenu(menu, mfSeparator, 0, "")
	appendMenu(menu, menuFlags(busy || !status.ServiceOK || pairingBusy), menuPair, "配对设备…")
	appendMenu(menu, menuFlags(busy), menuDoctor, "运行诊断…")
	appendMenu(menu, menuFlags(busy), menuDoctorFix, "修复诊断问题…")
	appendMenu(menu, mfString, menuLogs, "查看日志…")
	appendMenu(menu, mfSeparator, 0, "")
	appendMenu(menu, menuFlags(busy), menuExitAndStop, "退出并停止服务…")

	var cursor point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&cursor)))
	procSetForegroundWindow.Call(a.window)
	command, _, _ := procTrackPopupMenu.Call(
		menu,
		tpmRightButton|tpmReturnCmd|tpmNoNotify,
		uintptr(cursor.X),
		uintptr(cursor.Y),
		0,
		a.window,
		0,
	)
	procPostMessageW.Call(a.window, wmNull, 0, 0)
	if command != 0 {
		a.dispatchMenu(uint32(command))
	}
}

func appendMenu(menu uintptr, flags uint32, id uint32, label string) {
	var labelPointer uintptr
	if label != "" {
		value, _ := syscall.UTF16PtrFromString(label)
		labelPointer = uintptr(unsafe.Pointer(value))
	}
	procAppendMenuW.Call(menu, uintptr(flags), uintptr(id), labelPointer)
}

func menuFlags(disabled bool) uint32 {
	if disabled {
		return mfString | mfGray
	}
	return mfString
}

func (a *trayApplication) dispatchMenu(command uint32) {
	switch command {
	case menuControlPanel:
		a.showControlPanel()
	case menuRefresh:
		a.refreshStatusInteractive()
	case menuStart:
		a.runAction("启动", "start")
	case menuRestart:
		a.runAction("重新启动", "restart")
	case menuStop:
		a.runAction("停止", "stop")
	case menuPair:
		a.requestPairing()
	case menuDoctor:
		a.runDoctor(false)
	case menuDoctorFix:
		a.runDoctor(true)
	case menuLogs:
		if err := a.controller.openLogsTerminal(); err != nil {
			a.showError(err)
		}
	case menuExitAndStop:
		a.exitAndStop()
	}
}

func (a *trayApplication) refreshStatusInteractive() {
	if !a.beginBusy() {
		return
	}
	go func() {
		defer a.endBusy()
		a.refreshStatus()
	}()
}

func (a *trayApplication) runAction(label string, action string) {
	if !a.beginBusy() {
		return
	}
	go func() {
		defer a.endBusy()
		ctx, cancel := actionContext()
		err := a.controller.action(ctx, action)
		cancel()
		a.refreshStatus()
		if err != nil {
			a.showError(fmt.Errorf("%s服务失败：%w", label, err))
			return
		}
		a.showBalloon("Mimi Remote", "服务已"+label, niifInfo)
	}()
}

func (a *trayApplication) runDoctor(fix bool) {
	if !a.beginBusy() {
		return
	}
	go func() {
		defer a.endBusy()
		ctx, cancel := actionContext()
		result, err := a.controller.doctor(ctx, fix)
		cancel()
		a.refreshStatus()
		if err != nil {
			a.showError(err)
			return
		}
		title := "Mimi Remote 诊断"
		fallback := "诊断完成，没有返回详细信息。"
		if fix {
			title = "Mimi Remote 诊断修复"
			fallback = "诊断修复完成，没有返回详细信息。"
		}
		showMessage(a.window, title, fallbackText(result, fallback), mbOK|mbIconInfo)
	}()
}

func (a *trayApplication) requestPairing() {
	a.mu.RLock()
	ready := a.status.ServiceOK
	a.mu.RUnlock()
	if !ready {
		trayLogf("pairing request rejected because the tray status is not ready")
		a.showError(errors.New("服务尚未就绪，请先启动服务并等待状态变为“运行正常”"))
		return
	}
	procPostMessageW.Call(a.window, wmTrayPair, 0, 0)
}

func (a *trayApplication) showPairingPanel() {
	a.showControlPanel()
	if a.panel != nil {
		a.panel.showPairingView()
	}
}

func (a *trayApplication) showStatus() {
	a.mu.RLock()
	status := a.status
	err := a.statusErr
	a.mu.RUnlock()
	if err != nil {
		a.showError(err)
		return
	}
	showMessage(a.window, "Mimi Remote", status.details(), mbOK|mbIconInfo)
}

func (a *trayApplication) exitAndStop() {
	result := showMessage(
		a.window,
		"退出并停止 Mimi Remote？",
		"这会立即中断手机和平板的连接。\r\n下次登录 Windows 或重新打开托盘程序时会再次启动服务。",
		mbYesNo|mbIconWarning,
	)
	if result != idYes || !a.beginBusy() {
		return
	}
	go func() {
		defer a.endBusy()
		ctx, cancel := actionContext()
		err := a.controller.action(ctx, "stop")
		cancel()
		if err != nil {
			a.showError(fmt.Errorf("停止服务失败：%w", err))
			return
		}
		a.mu.Lock()
		a.quitting = true
		a.mu.Unlock()
		procPostMessageW.Call(a.window, wmClose, 0, 0)
	}()
}

func (a *trayApplication) beginBusy() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.busy {
		return false
	}
	a.busy = true
	procPostMessageW.Call(a.window, wmTrayRefresh, 0, 0)
	return true
}

func (a *trayApplication) endBusy() {
	a.mu.Lock()
	a.busy = false
	a.mu.Unlock()
	procPostMessageW.Call(a.window, wmTrayRefresh, 0, 0)
}

func (a *trayApplication) showError(err error) {
	if err == nil {
		return
	}
	showMessage(a.window, "Mimi Remote", err.Error(), mbOK|mbIconError)
	a.showBalloon("Mimi Remote", err.Error(), niifError)
}

func (a *trayApplication) showBalloon(title string, text string, infoFlags uint32) {
	data := a.iconData(nifInfo)
	copy(data.InfoTitle[:], syscall.StringToUTF16(truncateUTF16Text(title, 63)))
	copy(data.Info[:], syscall.StringToUTF16(truncateUTF16Text(text, 255)))
	data.InfoFlags = infoFlags
	procShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(&data)))
}

func showMessage(window uintptr, title string, text string, flags uint32) int {
	titlePointer, _ := syscall.UTF16PtrFromString(title)
	textPointer, _ := syscall.UTF16PtrFromString(text)
	result, _, _ := procMessageBoxW.Call(
		window,
		uintptr(unsafe.Pointer(textPointer)),
		uintptr(unsafe.Pointer(titlePointer)),
		uintptr(flags),
	)
	return int(result)
}
