//go:build windows

package config

import (
	"io/fs"
	"os"
)

// Windows does not expose a writable file as POSIX mode 0600: Go reports it
// as 0666 and Chmod only maps the owner-write bit to the read-only attribute.
// CreatePrivateTemp installs and verifies the protected DACL on new files.
func prepareInstallationIDFile(_ *os.File) error {
	return nil
}

func validateInstallationIDFilePermissions(_ fs.FileInfo) error {
	return nil
}

// Directory fsync is a Unix durability primitive. The identity file itself is
// flushed before the hard-link publication; Windows has no equivalent
// directory sync operation exposed by os.File.Sync.
func syncInstallationIDDirectory(_ string) error {
	return nil
}
