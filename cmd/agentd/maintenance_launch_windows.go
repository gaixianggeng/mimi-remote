package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"golang.org/x/sys/windows"
)

var errMaintenanceLaunch = errors.New("维护程序未完成，请返回桌面应用重新检查状态")
var shellExecuteMaintenance = windows.NewLazySystemDLL("shell32.dll").NewProc("ShellExecuteExW")

type maintenanceAction struct {
	parameters string
	elevate    bool
}

func maintenanceRequest(args []string) (maintenanceAction, error) {
	if len(args) == 1 {
		switch args[0] {
		case "modify":
			return maintenanceAction{parameters: "/MIMIMODE=modify"}, nil
		case "enable-lan", "disable-lan":
			return maintenanceAction{parameters: "/MIMIMODE=" + args[0] + " /VERYSILENT /SUPPRESSMSGBOXES /NORESTART", elevate: true}, nil
		}
	}
	return maintenanceAction{}, invalidOnboardingRequest(errors.New("请选择安装程序提供的固定维护操作"))
}

func runInstallerMaintenance(args []string) error {
	if len(args) == 1 && args[0] == "workspace-confirmed" {
		if installerWorkspaceConfirmed(config.PlatformDefaultPath(), config.LegacyDefaultPath()) {
			return nil
		}
		return errors.New("请先确认要共享的代码目录")
	}
	action, err := maintenanceRequest(args)
	if err != nil {
		return err
	}
	var elevated, size uint32
	if windows.GetTokenInformation(windows.GetCurrentProcessToken(), windows.TokenElevation, (*byte)(unsafe.Pointer(&elevated)), uint32(unsafe.Sizeof(elevated)), &size) != nil || elevated != 0 {
		return errors.New("请在当前用户的普通桌面会话中启动维护程序")
	}
	agent, err := os.Executable()
	if err != nil {
		return errMaintenanceIdentity
	}
	return withLockedMaintenance(filepath.Dir(agent), maintenanceImageSHA256, verifyMaintenancePublisher, func(path string) error {
		system, err := windows.GetSystemDirectory()
		if err != nil {
			return errMaintenanceLaunch
		}
		if action.elevate {
			return runElevatedMaintenance(path, action.parameters, system)
		}
		cmd := exec.Command(path, action.parameters)
		cmd.Dir = system
		if cmd.Run() != nil {
			return errMaintenanceLaunch
		}
		return nil
	})
}

// Native SHELLEXECUTEINFOW. Request a process handle so the locks cover UAC
// and the lifetime of the Inno loader, including its embedded setup process.
type maintenanceShellExecuteInfo struct {
	Size, Mask                        uint32
	Window                            windows.Handle
	Verb, File, Parameters, Directory *uint16
	Show                              int32
	Instance                          windows.Handle
	IDList                            uintptr
	Class                             *uint16
	ClassKey                          windows.Handle
	HotKey                            uint32
	IconOrMonitor, Process            windows.Handle
}

func runElevatedMaintenance(path, args, dir string) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	err := windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED|windows.COINIT_DISABLE_OLE1DDE)
	if err != nil && !errors.Is(err, syscall.Errno(1)) {
		return errMaintenanceLaunch
	}
	defer windows.CoUninitialize()
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return errMaintenanceLaunch
	}
	cwd, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		return errMaintenanceLaunch
	}
	verb, _ := windows.UTF16PtrFromString("runas")
	params, err := windows.UTF16PtrFromString(args)
	if err != nil {
		return errMaintenanceLaunch
	}
	const noCloseProcess = 0x40
	const noAsync = 0x100
	const noShellErrorUI = 0x400
	info := maintenanceShellExecuteInfo{
		Size: uint32(unsafe.Sizeof(maintenanceShellExecuteInfo{})), Mask: noCloseProcess | noAsync | noShellErrorUI,
		Verb: verb, File: p, Parameters: params, Directory: cwd, Show: windows.SW_SHOWNORMAL,
	}
	ok, _, callErr := shellExecuteMaintenance.Call(uintptr(unsafe.Pointer(&info)))
	if ok == 0 || info.Process == 0 {
		if errors.Is(callErr, windows.ERROR_CANCELLED) {
			return onboardingFailure("lan_firewall_blocked", "network_lan", true, errors.New("管理员授权已取消，请回到桌面应用检查局域网设置"))
		}
		return errMaintenanceLaunch
	}
	defer windows.CloseHandle(info.Process)
	result, err := windows.WaitForSingleObject(info.Process, windows.INFINITE)
	var code uint32
	if err != nil || result != windows.WAIT_OBJECT_0 || windows.GetExitCodeProcess(info.Process, &code) != nil || code != 0 {
		return errMaintenanceLaunch
	}
	return nil
}
