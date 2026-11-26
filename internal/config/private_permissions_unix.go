//go:build !windows

package config

import (
	"errors"
	"os"
	"syscall"
)

func setPrivateAccess(file *os.File) error {
	if err := setPrivateMode(file); err != nil {
		return err
	}
	return repairExtendedACL(file)
}

func permissionIdentity(path string) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if !errors.Is(err, os.ErrPermission) {
		return info, err
	}
	// On Darwin a deny-readsecurity ACE can deny lstat while still
	// permitting a no-follow open. fstat identifies the opened inode.
	file, err := openPermissionFile(path, false)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return file.Stat()
}

func permissionLinkCount(_ *os.File, info os.FileInfo) (uint64, error) {
	return uint64(info.Sys().(*syscall.Stat_t).Nlink), nil
}
