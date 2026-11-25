// Package configtest creates filesystem fixtures for configuration tests.
package configtest

import (
	"errors"
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
