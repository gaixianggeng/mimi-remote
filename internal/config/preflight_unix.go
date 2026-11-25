//go:build !windows

package config

import (
	"errors"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func openSnapshotFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
}
func checkPreflightFileAccess(file *os.File, info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return errors.New("文件不属于当前用户")
	}
	if info.Mode().Perm()&0077 != 0 {
		return errPreflightFileNotPrivate
	}
	return checkExtendedACL(file)
}

func checkTokenFileAccess(file *os.File, info os.FileInfo) error {
	return checkPreflightFileAccess(file, info)
}

func directoryAccessible(path string, info os.FileInfo, write bool) bool {
	if write {
		return info.Mode().Perm()&0222 != 0 && unix.Access(path, unix.W_OK|unix.X_OK) == nil
	}
	return info.Mode().Perm()&0444 != 0 && info.Mode().Perm()&0111 != 0 && unix.Access(path, unix.R_OK|unix.X_OK) == nil
}
