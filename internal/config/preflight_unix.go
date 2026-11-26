//go:build !windows

package config

import (
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
		return errFileNotOwned
	}
	if info.Mode() != 0600 {
		return errPreflightFileNotPrivate
	}
	return checkExtendedACL(file)
}

func directoryAccessible(path string, info os.FileInfo, write bool) bool {
	if write {
		return info.Mode().Perm()&0222 != 0 && unix.Access(path, unix.W_OK|unix.X_OK) == nil
	}
	return info.Mode().Perm()&0444 != 0 && info.Mode().Perm()&0111 != 0 && unix.Access(path, unix.R_OK|unix.X_OK) == nil
}
