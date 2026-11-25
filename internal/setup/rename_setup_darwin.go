package setup

import "golang.org/x/sys/unix"

func renameNewSetupFile(old, new string) error { return unix.RenamexNp(old, new, unix.RENAME_EXCL) }
