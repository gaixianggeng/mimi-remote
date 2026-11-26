package setup

import "golang.org/x/sys/unix"

func renameNewSetupFile(old, new string) error {
	return unix.Renameat2(unix.AT_FDCWD, old, unix.AT_FDCWD, new, unix.RENAME_NOREPLACE)
}
