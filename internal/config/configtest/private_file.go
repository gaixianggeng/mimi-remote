// Package configtest creates filesystem fixtures for configuration tests.
package configtest

import (
	"errors"
	"os"
	"testing"
)

// CreatePrivateFile creates a new fixture owned by the current user.
func CreatePrivateFile(t testing.TB, path string, data []byte) {
	t.Helper()
	f, err := createPrivateFile(path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.Write(data)
	if err := errors.Join(err, f.Close()); err != nil {
		t.Fatal(err)
	}
}

// WritePrivateFile creates a private fixture or updates the contents of its
// existing inode, preserving its owner and access policy.
func WritePrivateFile(t testing.TB, path string, data []byte) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if errors.Is(err, os.ErrNotExist) {
		CreatePrivateFile(t, path, data)
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.Write(data)
	if err := errors.Join(err, file.Close()); err != nil {
		t.Fatal(err)
	}
}
