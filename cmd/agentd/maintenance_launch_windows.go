package main

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"golang.org/x/sys/windows"
)

const (
	maintenanceUACCancelledExitCode = 1223
	jobObjectMsgActiveProcessZero   = 4
)

type jobObjectAssociateCompletionPort struct {
	CompletionKey  uintptr
	CompletionPort windows.Handle
}

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
	return withLockedMaintenanceIdentity(filepath.Dir(agent), maintenanceImageSHA256, verifyMaintenancePublisher, func(identity pinnedFileIdentity) error {
		system, err := windows.GetSystemDirectory()
		if err != nil {
			return errMaintenanceLaunch
		}
		if action.elevate {
			return runElevatedMaintenance(identity.path, action.parameters, system)
		}
		exitCode, err := runBoundMaintenanceProcess(identity, action.parameters, system)
		if err != nil {
			return err
		}
		if exitCode == maintenanceUACCancelledExitCode {
			return maintenanceUACCancelledError()
		}
		if exitCode != 0 {
			return errMaintenanceLaunch
		}
		return nil
	})
}

func maintenanceUACCancelledError() error {
	return &exitCodeError{
		exitCode: maintenanceUACCancelledExitCode,
		err: onboardingFailure(
			"lan_firewall_blocked",
			"network_lan",
			true,
			errors.New("管理员授权已取消，请回到桌面应用检查局域网设置"),
		),
	}
}

func runBoundMaintenanceProcess(identity pinnedFileIdentity, rawParams, dir string) (uint32, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, errMaintenanceLaunch
	}
	defer windows.CloseHandle(job)

	var limits windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&limits)),
		uint32(unsafe.Sizeof(limits)),
	); err != nil {
		return 0, errMaintenanceLaunch
	}

	iocp, err := windows.CreateIoCompletionPort(windows.InvalidHandle, 0, 0, 1)
	if err != nil {
		return 0, errMaintenanceLaunch
	}
	defer windows.CloseHandle(iocp)

	const completionKey uintptr = 1
	assoc := jobObjectAssociateCompletionPort{
		CompletionKey:  completionKey,
		CompletionPort: iocp,
	}
	if _, err := windows.SetInformationJobObject(
		job,
		windows.JobObjectAssociateCompletionPortInformation,
		uintptr(unsafe.Pointer(&assoc)),
		uint32(unsafe.Sizeof(assoc)),
	); err != nil {
		return 0, errMaintenanceLaunch
	}

	appName, err := windows.UTF16PtrFromString(identity.path)
	if err != nil {
		return 0, errMaintenanceIdentity
	}
	commandText := windows.EscapeArg(identity.path)
	if strings.TrimSpace(rawParams) != "" {
		commandText += " " + rawParams
	}
	cmdLine, err := windows.UTF16FromString(commandText)
	if err != nil {
		return 0, errMaintenanceLaunch
	}
	cwd, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		return 0, errMaintenanceLaunch
	}

	var si windows.StartupInfo
	si.Cb = uint32(unsafe.Sizeof(si))
	var pi windows.ProcessInformation
	if err := windows.CreateProcess(
		appName,
		&cmdLine[0],
		nil,
		nil,
		false,
		windows.CREATE_SUSPENDED,
		nil,
		cwd,
		&si,
		&pi,
	); err != nil {
		return 0, errMaintenanceLaunch
	}
	defer windows.CloseHandle(pi.Thread)
	defer windows.CloseHandle(pi.Process)

	if err := verifyProcessMatchesIdentity(pi.Process, identity); err != nil {
		_ = windows.TerminateProcess(pi.Process, 1)
		_, _ = windows.WaitForSingleObject(pi.Process, 5000)
		return 0, errMaintenanceIdentity
	}
	if err := windows.AssignProcessToJobObject(job, pi.Process); err != nil {
		_ = windows.TerminateProcess(pi.Process, 1)
		_, _ = windows.WaitForSingleObject(pi.Process, 5000)
		return 0, errMaintenanceLaunch
	}
	if _, err := windows.ResumeThread(pi.Thread); err != nil {
		_ = windows.TerminateJobObject(job, 1)
		waitForJobZeroProcesses(iocp, completionKey)
		return 0, errMaintenanceLaunch
	}

	waitResult, waitErr := windows.WaitForSingleObject(pi.Process, windows.INFINITE)
	var exitCode uint32
	if waitErr != nil || waitResult != windows.WAIT_OBJECT_0 || windows.GetExitCodeProcess(pi.Process, &exitCode) != nil {
		_ = windows.TerminateJobObject(job, 1)
		waitForJobZeroProcesses(iocp, completionKey)
		return 0, errMaintenanceLaunch
	}
	// Keep verification pins held until Inno's unpacked setup child processes
	// in the job have also completely exited.
	waitForJobZeroProcesses(iocp, completionKey)
	return exitCode, nil
}

func waitForJobZeroProcesses(iocp windows.Handle, expectedKey uintptr) {
	for {
		var msg uint32
		var key uintptr
		var overlapped *windows.Overlapped
		if err := windows.GetQueuedCompletionStatus(iocp, &msg, &key, &overlapped, windows.INFINITE); err != nil {
			return
		}
		if key == expectedKey && msg == jobObjectMsgActiveProcessZero {
			return
		}
	}
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
			return maintenanceUACCancelledError()
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
