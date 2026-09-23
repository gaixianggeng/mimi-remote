//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// 孤儿实例：前门加载前（例如 Mac 停在登录窗口时远程 Desktop 先连接）由 SSH 创建、
// 绑定在标准路径上的 Codex。launchd 加载前门时会删除旧 socket 文件并重新绑定，
// 旧实例仍在运行但再也收不到新连接。前门确认没有客户端、且运行版本支持
// graceful-only 退出时才发送 SIGHUP；旧实例真正退出前，新 backend 不开放。

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
	canDrain    func(context.Context, sharedLocalRepairProcess) error
	signalHUP   func(int) error
	signaledMu  *sync.Mutex
	signaled    map[sharedLocalRepairProcess]struct{}
}

const frontDoorOrphanMarkerPattern = "app-server-orphan-*.json"

func defaultFrontDoorOrphanOps() frontDoorOrphanOps {
	return frontDoorOrphanOps{
		listCodex:   listCurrentUserCodexProcesses,
		args:        darwinProcessArgs,
		socketNames: realSharedLocalRepairSocketNames,
		process:     realSharedLocalRepairProcess,
		canDrain:    canGracefullyDrainFrontDoorOrphan,
		signalHUP:   func(pid int) error { return unix.Kill(pid, unix.SIGHUP) },
		signaledMu:  &sync.Mutex{},
		signaled:    map[sharedLocalRepairProcess]struct{}{},
	}
}

// ReleaseIdleOrphans 查找仍以标准 socket 路径监听的 Codex，并请求空闲者退出。
// 只有前门已经持有标准路径时才能调用，否则会误把正常实例当成孤儿。
func (f *FrontDoor) ReleaseIdleOrphans(ctx context.Context) ([]FrontDoorOrphan, error) {
	ops := f.orphans
	tracked, err := f.trackedDrainingOrphans(ctx)
	if err != nil {
		return nil, err
	}
	processes, err := ops.listCodex()
	if err != nil {
		return nil, err
	}
	var found []FrontDoorOrphan
	for process := range tracked {
		found = append(found, FrontDoorOrphan{PID: process.PID, Signaled: true})
	}
	for _, process := range processes {
		if process.PID == os.Getpid() {
			continue
		}
		if _, draining := tracked[process]; draining {
			continue
		}
		argv, argsErr := ops.args(process.PID)
		if argsErr != nil {
			current, alive, processErr := ops.process(process.PID)
			if processErr == nil && !alive {
				continue
			}
			if processErr != nil || current != process {
				return found, errors.New("无法确认 Codex 进程身份，拒绝开放新 backend")
			}
			return found, fmt.Errorf("无法读取 Codex 进程参数，拒绝开放新 backend：%w", argsErr)
		}
		if !isPublicAppServerArgs(argv, f.public) {
			continue
		}
		names, err := ops.socketNames(ctx, process.PID, f.public)
		if err != nil {
			current, alive, processErr := ops.process(process.PID)
			if processErr == nil && !alive {
				continue
			}
			if processErr != nil || current != process {
				return found, errors.New("无法确认旧 Codex 进程身份，拒绝开放新 backend")
			}
			return found, fmt.Errorf("无法核对旧 Codex socket 引用：%w", err)
		}
		if names == 0 {
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
			if processErr != nil || !alive || current != process {
				return found, errors.New("旧 Codex 进程身份在迁移期间变化，拒绝开放新 backend")
			}
			if err := ops.canDrain(ctx, process); err != nil {
				return found, fmt.Errorf("旧 Codex 版本无法确认安全退出，拒绝自动迁移：%w", err)
			}
			// 先落盘再发信号。前门若在两步之间退出，下一代前门会补发幂等的 SIGHUP。
			if err := f.markDrainingOrphan(process); err != nil {
				return found, fmt.Errorf("记录旧 Codex 退出状态失败：%w", err)
			}
			current, alive, processErr = ops.process(process.PID)
			if processErr != nil || !alive || current != process {
				return found, errors.New("旧 Codex 进程身份在退出前变化，拒绝发送信号")
			}
			if err := ops.signalHUP(process.PID); err != nil {
				return found, fmt.Errorf("请求旧 Codex 优雅退出失败：%w", err)
			}
			ops.signaledMu.Lock()
			ops.signaled[process] = struct{}{}
			ops.signaledMu.Unlock()
			orphan.Signaled = true
			f.logf("codex front door asked idle orphan pid=%d to drain", process.PID)
		} else {
			f.logf("codex front door found orphan pid=%d with %d client(s); waiting", process.PID, orphan.Clients)
		}
		found = append(found, orphan)
	}
	return found, nil
}

func (f *FrontDoor) orphanMarkerPath(process sharedLocalRepairProcess) string {
	return filepath.Join(filepath.Dir(f.public), fmt.Sprintf("app-server-orphan-%d-%d-%d.json", process.PID, process.StartSec, process.StartUSec))
}

func (f *FrontDoor) markDrainingOrphan(process sharedLocalRepairProcess) error {
	path := f.orphanMarkerPath(process)
	data, err := json.Marshal(process)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".app-server-orphan-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

func (f *FrontDoor) trackedDrainingOrphans(ctx context.Context) (map[sharedLocalRepairProcess]struct{}, error) {
	paths, err := filepath.Glob(filepath.Join(filepath.Dir(f.public), frontDoorOrphanMarkerPattern))
	if err != nil {
		return nil, err
	}
	tracked := make(map[sharedLocalRepairProcess]struct{}, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("读取旧 Codex 退出记录失败：%w", err)
		}
		var process sharedLocalRepairProcess
		if err := json.Unmarshal(data, &process); err != nil || path != f.orphanMarkerPath(process) || process.UID != uint32(os.Getuid()) {
			return nil, errors.New("旧 Codex 退出记录无效，拒绝开放新 backend")
		}
		current, alive, err := f.orphans.process(process.PID)
		if err != nil {
			return nil, fmt.Errorf("核对旧 Codex 退出状态失败：%w", err)
		}
		if !alive || current != process {
			if err := os.Remove(path); err != nil {
				return nil, fmt.Errorf("清理旧 Codex 退出记录失败：%w", err)
			}
			continue
		}
		f.orphans.signaledMu.Lock()
		_, signaled := f.orphans.signaled[process]
		f.orphans.signaledMu.Unlock()
		if !signaled {
			if err := f.orphans.canDrain(ctx, process); err != nil {
				return nil, fmt.Errorf("旧 Codex 版本无法确认安全退出，拒绝自动迁移：%w", err)
			}
			current, alive, err = f.orphans.process(process.PID)
			if err != nil || !alive || current != process {
				return nil, errors.New("旧 Codex 进程身份在退出前变化，拒绝发送信号")
			}
			if err := f.orphans.signalHUP(process.PID); err != nil {
				return nil, fmt.Errorf("请求旧 Codex 优雅退出失败：%w", err)
			}
			f.orphans.signaledMu.Lock()
			f.orphans.signaled[process] = struct{}{}
			f.orphans.signaledMu.Unlock()
		}
		tracked[process] = struct{}{}
	}
	return tracked, nil
}

func canGracefullyDrainFrontDoorOrphan(ctx context.Context, process sharedLocalRepairProcess) error {
	path, err := darwinProcessExecutable(process.PID)
	if err != nil || !filepath.IsAbs(path) {
		return errors.New("无法读取旧 Codex 的可执行文件")
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("旧 Codex 的可执行文件已不可用")
	}
	started := time.Unix(process.StartSec, int64(process.StartUSec)*1000)
	if info.ModTime().After(started) {
		return errors.New("旧 Codex 启动后可执行文件已更新")
	}
	// Codex 0.149.1 起已核对：重复 SIGHUP 不会把 drain 升级成强制退出。
	_, err = CheckLocalCodex(ctx, path)
	return err
}

func darwinProcessExecutable(pid int) (string, error) {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", err
	}
	if len(raw) < 5 {
		return "", errors.New("procargs2 过短")
	}
	end := bytes.IndexByte(raw[4:], 0)
	if end <= 0 {
		return "", errors.New("procargs2 缺少可执行路径")
	}
	return string(raw[4 : 4+end]), nil
}

func isPublicAppServerArgs(argv []string, public string) bool {
	hasAppServer, listensPublic := false, false
	for index, arg := range argv {
		if arg == "proxy" {
			return false
		}
		if arg == "app-server" {
			hasAppServer = true
		}
		if arg == "--listen" && index+1 < len(argv) {
			listen := argv[index+1]
			listensPublic = listen == "unix://" || listen == "unix://"+public
		}
	}
	return hasAppServer && listensPublic
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
