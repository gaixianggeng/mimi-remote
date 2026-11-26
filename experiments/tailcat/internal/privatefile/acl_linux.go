package privatefile

import (
	"errors"
	"fmt"
	"os"

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
		return fmt.Errorf("%w：无法验证文件系统的访问控制", errNotPrivate)
	}
	return nil
}

func missingACL(err error) bool { return errors.Is(err, unix.ENODATA) || errors.Is(err, unix.ENOTSUP) }

func checkExtendedACL(file *os.File) error {
	_, err := unix.Fgetxattr(int(file.Fd()), accessACL, nil)
	if missingACL(err) {
		return nil
	}
	if err == nil {
		return errNotPrivate
	}
	return err
}

// A POSIX default ACL may be inherited with its group mask zeroed by 0600.
// Strip it on the empty stage before any credential bytes are written.
func prepareStage(file *os.File) error {
	err := unix.Fremovexattr(int(file.Fd()), accessACL)
	if err != nil && !missingACL(err) {
		return err
	}
	return file.Chmod(0600)
}

func createPrivateNew(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
}
