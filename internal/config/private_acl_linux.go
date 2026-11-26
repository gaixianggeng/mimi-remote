package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"

	"golang.org/x/sys/unix"
)

const accessACL = "system.posix_acl_access"

// A synthetic mode on a network or virtual mount does not describe the
// server's ACL. Only accept filesystems enforcing Unix mode and POSIX ACLs.
func supportsPrivateMode(fsType uint32) bool {
	switch fsType {
	case unix.EXT4_SUPER_MAGIC, unix.XFS_SUPER_MAGIC, unix.BTRFS_SUPER_MAGIC,
		unix.F2FS_SUPER_MAGIC, unix.TMPFS_MAGIC, unix.RAMFS_MAGIC, unix.OVERLAYFS_SUPER_MAGIC:
		return true
	}
	return false
}

func checkPermissionVolume(file *os.File) error {
	var fs unix.Statfs_t
	if err := unix.Fstatfs(int(file.Fd()), &fs); err != nil {
		return err
	}
	if !supportsPrivateMode(uint32(fs.Type)) {
		return fmt.Errorf("%w：无法验证文件系统的访问控制", errPreflightFileNotPrivate)
	}
	return nil
}

func openPermissionFile(path string, _ bool) (*os.File, error) {
	file, err := openSnapshotFile(path)
	if errors.Is(err, os.ErrPermission) {
		// O_PATH pins an unreadable inode so its owner can still repair mode 0000.
		return os.OpenFile(path, unix.O_PATH|unix.O_NOFOLLOW, 0)
	}
	return file, err
}

// Linux xattr and chmod calls on an O_PATH descriptor use its pinned procfs link.
func descriptorPath(file *os.File) string {
	return "/proc/self/fd/" + strconv.FormatUint(uint64(file.Fd()), 10)
}

func setPrivateMode(file *os.File) error {
	err := file.Chmod(0600)
	if errors.Is(err, unix.EBADF) {
		return unix.Chmod(descriptorPath(file), 0600)
	}
	return err
}

func missingACL(err error) bool { return errors.Is(err, unix.ENODATA) || errors.Is(err, unix.ENOTSUP) }

func checkExtendedACL(file *os.File) error {
	_, err := unix.Fgetxattr(int(file.Fd()), accessACL, nil)
	if errors.Is(err, unix.EBADF) {
		_, err = unix.Getxattr(descriptorPath(file), accessACL, nil)
	}
	if missingACL(err) {
		return nil
	}
	if err == nil {
		return errPreflightFileNotPrivate
	}
	return err
}

func repairExtendedACL(file *os.File) error {
	err := unix.Fremovexattr(int(file.Fd()), accessACL)
	if errors.Is(err, unix.EBADF) {
		err = unix.Removexattr(descriptorPath(file), accessACL)
	}
	if missingACL(err) {
		return nil
	}
	return err
}

func createPrivateNew(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
}

func prepareNewPrivateFile(file *os.File) error { return MakeFilePrivate(file) }
