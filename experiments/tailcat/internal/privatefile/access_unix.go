//go:build !windows

package privatefile

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func openNoFollow(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
}
func checkAccess(file *os.File, info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return errNotPrivate
	}
	if err := checkPermissionVolume(file); err != nil {
		return err
	}
	if info.Mode() != 0600 {
		return errNotPrivate
	}
	return checkExtendedACL(file)
}

func identity(path string) (os.FileInfo, error) { return os.Lstat(path) }
