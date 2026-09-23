//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"os"
	"sync"

	"golang.org/x/sys/unix"
)

// 孤儿实例：前门加载前（例如 Mac 停在登录窗口时远程 Desktop 先连接）由 SSH 创建、
// 绑定在标准路径上的 Codex。launchd 加载前门时会删除旧 socket 文件并重新绑定，
// 旧实例仍在运行但再也收不到新连接。前门只在它没有任何客户端连接时发送一次
// SIGTERM，由 Codex 自己的优雅退出等待运行中的回合结束；从不发送 SIGKILL。

type FrontDoorOrphan struct {
	PID      int  `json:"pid"`
	Clients  int  `json:"clients"`
	Signaled bool `json:"signaled"`
}

type frontDoorOrphanOps struct {
	listCodex   func() ([]sharedLocalRepairProcess, error)
	args        func(int) ([]string, error)
	socketNames func(context.Context, int, string) (int, error)
	process     func(int) (sharedLocalRepairProcess, bool, error)
	signalTERM  func(int) error
	signaledMu  *sync.Mutex
	signaled    map[sharedLocalRepairProcess]struct{}
}

func defaultFrontDoorOrphanOps() frontDoorOrphanOps {
	return frontDoorOrphanOps{
		listCodex:   listCurrentUserCodexProcesses,
		args:        darwinProcessArgs,
		socketNames: realSharedLocalRepairSocketNames,
		process:     realSharedLocalRepairProcess,
		signalTERM:  func(pid int) error { return unix.Kill(pid, unix.SIGTERM) },
		signaledMu:  &sync.Mutex{},
		signaled:    map[sharedLocalRepairProcess]struct{}{},
	}
}

// ReleaseIdleOrphans 查找仍以标准 socket 路径监听的 Codex，并请求空闲者退出。
// 只有前门已经持有标准路径时才能调用，否则会误把正常实例当成孤儿。
func (f *FrontDoor) ReleaseIdleOrphans(ctx context.Context) ([]FrontDoorOrphan, error) {
	ops := f.orphans
	processes, err := ops.listCodex()
	if err != nil {
		return nil, err
	}
	var found []FrontDoorOrphan
	for _, process := range processes {
		if process.PID == os.Getpid() || !isAppServerListener(ops.args, process.PID) {
			continue
		}
		names, err := ops.socketNames(ctx, process.PID, f.public)
		if err != nil || names == 0 {
			continue
		}
		orphan := FrontDoorOrphan{PID: process.PID, Clients: names - 1}
		ops.signaledMu.Lock()
		_, already := ops.signaled[process]
		ops.signaledMu.Unlock()
		if already {
			orphan.Signaled = true
			found = append(found, orphan)
			continue
		}
		if orphan.Clients == 0 {
			current, alive, processErr := ops.process(process.PID)
			if processErr == nil && alive && current == process && ops.signalTERM(process.PID) == nil {
				ops.signaledMu.Lock()
				ops.signaled[process] = struct{}{}
				ops.signaledMu.Unlock()
				orphan.Signaled = true
				f.logf("codex front door asked idle orphan pid=%d to exit", process.PID)
			}
		} else {
			f.logf("codex front door found orphan pid=%d with %d client(s); waiting", process.PID, orphan.Clients)
		}
		found = append(found, orphan)
	}
	return found, nil
}

func isAppServerListener(args func(int) ([]string, error), pid int) bool {
	argv, err := args(pid)
	if err != nil {
		return false
	}
	hasAppServer, hasListen := false, false
	for _, arg := range argv {
		switch arg {
		case "app-server":
			hasAppServer = true
		case "--listen":
			hasListen = true
		case "proxy":
			return false
		}
	}
	return hasAppServer && hasListen
}

func listCurrentUserCodexProcesses() ([]sharedLocalRepairProcess, error) {
	infos, err := unix.SysctlKinfoProcSlice("kern.proc.uid", os.Getuid())
	if err != nil {
		return nil, err
	}
	var result []sharedLocalRepairProcess
	for index := range infos {
		info := &infos[index]
		if darwinProcessName(info.Proc.P_comm[:]) != "codex" {
			continue
		}
		result = append(result, sharedLocalRepairProcess{
			PID:       int(info.Proc.P_pid),
			UID:       info.Eproc.Ucred.Uid,
			StartSec:  info.Proc.P_starttime.Sec,
			StartUSec: info.Proc.P_starttime.Usec,
			Name:      "codex",
		})
	}
	return result, nil
}

// darwinProcessArgs 解析 kern.procargs2：argc、可执行路径、对齐用 NUL，然后是 argv。
func darwinProcessArgs(pid int) ([]string, error) {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return nil, err
	}
	return parseDarwinProcArgs(raw)
}

func parseDarwinProcArgs(raw []byte) ([]string, error) {
	if len(raw) < 4 {
		return nil, errors.New("procargs2 过短")
	}
	argc := int(binary.LittleEndian.Uint32(raw[:4]))
	rest := raw[4:]
	end := bytes.IndexByte(rest, 0)
	if end < 0 {
		return nil, errors.New("procargs2 缺少可执行路径")
	}
	rest = rest[end:]
	for len(rest) > 0 && rest[0] == 0 {
		rest = rest[1:]
	}
	args := make([]string, 0, argc)
	for len(args) < argc && len(rest) > 0 {
		end = bytes.IndexByte(rest, 0)
		if end < 0 {
			end = len(rest)
		}
		args = append(args, string(rest[:end]))
		if end == len(rest) {
			break
		}
		rest = rest[end+1:]
	}
	if len(args) != argc {
		return nil, errors.New("procargs2 参数数量不符")
	}
	return args, nil
}
