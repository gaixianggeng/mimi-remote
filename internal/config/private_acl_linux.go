package config

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// The group mode bits include the POSIX access ACL's effective mask. When
// those bits are clear, named non-owner entries cannot access the file.
func checkExtendedACL(*os.File) error  { return nil }
func repairExtendedACL(*os.File) error { return nil }

func copyExtendedACL(source, target *os.File) error {
	const name = "system.posix_acl_access"
	size, err := unix.Fgetxattr(int(source.Fd()), name, nil)
	if errors.Is(err, unix.ENODATA) || errors.Is(err, unix.ENOTSUP) {
		err = unix.Fremovexattr(int(target.Fd()), name)
		if errors.Is(err, unix.ENODATA) || errors.Is(err, unix.ENOTSUP) {
			return nil
		}
		return err
	}
	if err != nil {
		return err
	}
	b := make([]byte, size)
	n, err := unix.Fgetxattr(int(source.Fd()), name, b)
	if err != nil {
		return err
	}
	return unix.Fsetxattr(int(target.Fd()), name, b[:n], 0)
}
