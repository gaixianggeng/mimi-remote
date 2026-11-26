//go:build !windows

package configtest

import (
	"os"
	"testing"
)

func createPrivateFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
}

func SetNoncanonicalPermissions(t testing.TB, path string, narrow bool) {
	t.Helper()
	mode := os.FileMode(0644)
	if narrow {
		mode = 0400
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}
