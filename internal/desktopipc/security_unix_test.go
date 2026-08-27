//go:build unix

package desktopipc

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestVerifySocketAcceptsCurrentUserPrivateSocket(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "mimi-ipc-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	path := filepath.Join(directory, "ipc.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := VerifySocket(path); err != nil {
		t.Fatalf("private current-user socket was rejected: %v", err)
	}
	if err := os.Chmod(path, 0o660); err != nil {
		t.Fatal(err)
	}
	if err := VerifySocket(path); err == nil {
		t.Fatal("group-accessible socket must be rejected")
	}
}
