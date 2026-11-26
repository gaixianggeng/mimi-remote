package setup

import (
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"golang.org/x/sys/windows"
)

// Windows has no portable directory fsync. Publish flushed files with write-through.
func renameSetupFile(source, destination string) error {
	// The destination can acquire a different DACL without changing bytes.
	// Check rollback links as well as forward publications.
	if err := config.CopyPrivatePermissions(destination, source); err != nil {
		return err
	}
	return moveSetupFile(source, destination, windows.MOVEFILE_REPLACE_EXISTING)
}
func renameNewSetupFile(source, destination string) error {
	return moveSetupFile(source, destination, 0)
}
func moveSetupFile(source, destination string, flags uint32) error {
	from, err := windows.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(destination)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(from, to, flags|windows.MOVEFILE_WRITE_THROUGH)
}

func publishSetupCompanion(stage, path string, ops setupFileTransactionOps) error {
	alias := stage + ".publish"
	if err := ops.link(stage, alias); err != nil {
		return err
	}
	return renameNewSetupFile(alias, path)
}
