//go:build linux || darwin

package appserver

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
)

type sharedLocalLstatFunc func(string) (os.FileInfo, uint32, error)

// Linux systemd unit 允许在 /tmp/codex-daemon-%U 被占位或不安全时继续启动核心服务，
// 因此 Go 侧在连接或拉起本机共享 Codex 前做二次 Lstat 校验；macOS 与 Windows 保持原行为。
var (
	sharedLocalDirCheckEnabled = runtime.GOOS == "linux"
	sharedLocalCurrentUID      = func() uint32 { return uint32(os.Getuid()) }
	sharedLocalLinuxDaemonDir  = func() string {
		return filepath.Join("/tmp", fmt.Sprintf("codex-daemon-%d", sharedLocalCurrentUID()))
	}
	sharedLocalLstat    sharedLocalLstatFunc = defaultSharedLocalLstat
	sharedLocalReadlink                      = os.Readlink
)

func defaultSharedLocalLstat(path string) (os.FileInfo, uint32, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, 0, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return info, 0, fmt.Errorf("无法读取 %s 的属主信息", path)
	}
	return info, stat.Uid, nil
}

func validateSharedLocalSocketSafety(socketPath string) error {
	if !sharedLocalDirCheckEnabled {
		return nil
	}
	return checkSharedLocalSocketDirs(
		socketPath,
		sharedLocalLinuxDaemonDir(),
		sharedLocalCurrentUID(),
		sharedLocalLstat,
		sharedLocalReadlink,
	)
}

func checkSharedLocalSocketDirs(
	socketPath string,
	daemonDir string,
	expectedUID uint32,
	lstat sharedLocalLstatFunc,
	readlink func(string) (string, error),
) error {
	if daemonDir != "" {
		if err := validateSharedLocalDir(daemonDir, expectedUID, true, lstat); err != nil {
			return err
		}
	}
	if socketPath == "" {
		return nil
	}
	sockInfo, _, err := lstat(socketPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("共享 Codex socket %s 无法校验（%v），已忽略", socketPath, err)
	}
	if sockInfo.Mode()&os.ModeSymlink == 0 {
		return nil
	}
	linkTarget, err := readlink(socketPath)
	if err != nil {
		return fmt.Errorf("共享 Codex socket 符号链接 %s 无法读取（%v），已忽略", socketPath, err)
	}
	target := linkTarget
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(socketPath), target)
	}
	target = filepath.Clean(target)
	targetDir := filepath.Dir(target)
	if err := validateSharedLocalDir(targetDir, expectedUID, false, lstat); err != nil {
		return err
	}
	if targetInfo, _, targetErr := lstat(target); targetErr == nil && targetInfo.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("共享 Codex 目录 %s 内的目标 socket 不安全（嵌套符号链接），已忽略", targetDir)
	}
	return nil
}

func validateSharedLocalDir(dir string, expectedUID uint32, allowMissing bool, lstat sharedLocalLstatFunc) error {
	info, uid, err := lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		if allowMissing {
			return nil
		}
		return fmt.Errorf("共享 Codex 目录 %s 不安全（目录不存在），已忽略", dir)
	}
	if err != nil {
		return fmt.Errorf("共享 Codex 目录 %s 无法校验（%v），已忽略", dir, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("共享 Codex 目录 %s 不安全（是符号链接），已忽略", dir)
	}
	if !info.IsDir() {
		return fmt.Errorf("共享 Codex 目录 %s 不安全（不是目录），已忽略", dir)
	}
	if uid != expectedUID {
		return fmt.Errorf("共享 Codex 目录 %s 不安全（属主 UID=%d 与当前用户 %d 不符），已忽略", dir, uid, expectedUID)
	}
	return nil
}
