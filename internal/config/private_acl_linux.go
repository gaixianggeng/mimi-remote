package config

import (
	"errors"
	"os"
	"strconv"

	"golang.org/x/sys/unix"
)

const accessACL = "system.posix_acl_access"

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
