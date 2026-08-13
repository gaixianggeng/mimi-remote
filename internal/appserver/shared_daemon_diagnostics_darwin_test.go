//go:build darwin

package appserver

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"unsafe"
)

func TestDarwinProcFDInfoLayout(t *testing.T) {
	// proc_info 是 ABI，不经过 Go 类型检查；布局变化必须在测试中显式暴露。
	if got := unsafe.Sizeof(darwinProcFDInfo{}); got != 8 {
		t.Fatalf("proc_fdinfo 布局大小异常：got=%d want=8", got)
	}
}

func TestSharedDaemonProcessMetricsReadCurrentProcess(t *testing.T) {
	before, err := sharedDaemonProcessOpenFileCount(os.Getpid())
	if err != nil {
		t.Fatalf("读取当前进程 FD 数失败：%v", err)
	}
	if before <= 0 {
		t.Fatalf("当前进程 FD 数必须大于 0：%d", before)
	}
	opened := make([]*os.File, 0, 3)
	for range 3 {
		file, openErr := os.Open("/dev/null")
		if openErr != nil {
			t.Fatal(openErr)
		}
		opened = append(opened, file)
	}
	t.Cleanup(func() {
		for _, file := range opened {
			_ = file.Close()
		}
	})
	after, err := sharedDaemonProcessOpenFileCount(os.Getpid())
	if err != nil {
		t.Fatalf("打开文件后读取当前进程 FD 数失败：%v", err)
	}
	if after < before+len(opened) {
		t.Fatalf("PROC_PIDLISTFDS 必须反映实际新增 FD：before=%d after=%d opened=%d", before, after, len(opened))
	}
	children, err := sharedDaemonDirectChildCount(os.Getpid())
	if err != nil {
		t.Fatalf("读取当前进程直接子进程数失败：%v", err)
	}
	if children < 0 {
		t.Fatalf("直接子进程数不能为负数：%d", children)
	}
}

func TestInspectSharedDaemonDiagnosticsUsesSocketPeerAndKeepsExternalLimitUnknown(t *testing.T) {
	// Unix socket 路径有固定长度上限；系统测试临时目录在 macOS 上可能很深。
	codexHome, err := os.MkdirTemp("/tmp", "mimi-daemon-diag-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(codexHome) })
	socketPath, err := LocalDaemonSocketPath(map[string]string{"CODEX_HOME": codexHome})
	if err != nil {
		t.Fatalf("解析临时 socket 失败：%v", err)
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		t.Fatalf("创建临时 socket 目录失败：%v", err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("创建临时 Unix listener 失败：%v", err)
	}
	defer listener.Close()

	status, err := InspectSharedDaemonDiagnostics(context.Background(), LocalDaemonOptions{
		Env: map[string]string{"CODEX_HOME": codexHome},
	})
	if err != nil {
		t.Fatalf("共享 daemon 诊断失败：%v", err)
	}
	if status.ListenerPID != os.Getpid() {
		t.Fatalf("必须以 socket 的真实 peer PID 为准：got=%d want=%d", status.ListenerPID, os.Getpid())
	}
	if status.OpenFileDescriptors <= 0 || status.ListenerStartedAt.IsZero() {
		t.Fatalf("进程资源证据不完整：%+v", status)
	}
	if status.OwnerState != SharedDaemonOwnerStateExternal {
		t.Fatalf("非 StableOwner 配置必须标记为 external：%+v", status)
	}
	if status.OwnerTargetFDSoftLimit != nil || status.FDUsagePercent != nil ||
		status.ResourceState != SharedDaemonResourceStateUnknown {
		t.Fatalf("外部 owner 的上限未知，不能套用 Mimi 配置：%+v", status)
	}
}
