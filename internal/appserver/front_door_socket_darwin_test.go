//go:build darwin

package appserver

import (
	"crypto/sha256"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateBackendSocketAliasRejectsUntrustedTargets(t *testing.T) {
	directory, err := filepath.EvalSymlinks(shortSharedLocalCodexHome(t))
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(directory, "advertised.sock")
	target := filepath.Join(directory, fmt.Sprintf("%x", sha256.Sum256([]byte(socket))))
	listener, err := net.Listen("unix", target)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(target, 0o600); err != nil {
		t.Fatal(err)
	}
	uid := uint32(os.Getuid())
	resolved, err := validatePrivateBackendSocketAlias(socket, target, directory, uid)
	if err != nil || resolved != target {
		t.Fatalf("合法映射未被接受：%s %v", resolved, err)
	}
	if _, err := validatePrivateBackendSocketAlias(socket, target+"-other", directory, uid); err == nil {
		t.Fatal("不得释放另一个公开路径对应的 backend")
	}
	if _, err := validatePrivateBackendSocketAlias(socket, target, directory, uid+1); err == nil {
		t.Fatal("不得释放其他用户的 backend")
	}
	if err := os.Chmod(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := validatePrivateBackendSocketAlias(socket, target, directory, uid); err == nil {
		t.Fatal("不得接受非私有 socket 目录")
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(target, 0o666); err != nil {
		t.Fatal(err)
	}
	if _, err := validatePrivateBackendSocketAlias(socket, target, directory, uid); err == nil {
		t.Fatal("不得接受非私有 socket")
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("not a socket"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := validatePrivateBackendSocketAlias(socket, target, directory, uid); err == nil {
		t.Fatal("不得把同名普通文件当作 backend")
	}
}

func TestPrivateBackendSocketPathRejectsArbitrarySymlink(t *testing.T) {
	home := shortSharedLocalCodexHome(t)
	socket := filepath.Join(home, "backend.sock")
	if err := os.Symlink(filepath.Join(home, "other.sock"), socket); err != nil {
		t.Fatal(err)
	}
	if _, err := privateBackendSocketPath(socket); err == nil {
		t.Fatal("不得把任意符号链接当作官方 socket 映射")
	}
}
