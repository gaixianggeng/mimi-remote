//go:build darwin

package appserver

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

func privateBackendSocketPath(socket string) (string, error) {
	info, err := os.Lstat(socket)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSocket != 0 {
		return socket, nil
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return "", errors.New("私有 Codex backend 路径不是 socket，拒绝释放")
	}
	uid := uint32(os.Getuid())
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uid {
		return "", errors.New("私有 Codex backend 链接不属于当前用户，拒绝释放")
	}
	temporaryRoot, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		return "", err
	}
	directory := filepath.Join(temporaryRoot, "codex-daemon-"+strconv.Itoa(os.Getuid()))
	target, err := os.Readlink(socket)
	if err != nil {
		return "", err
	}
	return validatePrivateBackendSocketAlias(socket, target, directory, uid)
}

func validatePrivateBackendSocketAlias(socket, target, directory string, uid uint32) (string, error) {
	// Codex 0.161 将监听文件移至固定的用户私有目录，以公开路径的 SHA-256 命名。
	// 只接受这一映射，不能把任意符号链接当成可停止的 backend；后续直接连接实际
	// socket，避免验证后链接被更换，同时让 lsof 统计实际监听文件的客户端。
	parent, err := filepath.EvalSymlinks(filepath.Dir(socket))
	if err != nil {
		return "", err
	}
	canonical := filepath.Join(parent, filepath.Base(socket))
	expected := filepath.Join(directory, fmt.Sprintf("%x", sha256.Sum256([]byte(canonical))))
	if target != expected {
		return "", errors.New("私有 Codex backend 链接目标不匹配，拒绝释放")
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return "", err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || stat.Uid != uid || info.Mode().Perm() != 0o700 {
		return "", errors.New("Codex backend socket 目录权限或归属不安全，拒绝释放")
	}
	info, err = os.Lstat(target)
	if err != nil {
		return "", err
	}
	stat, ok = info.Sys().(*syscall.Stat_t)
	if info.Mode()&os.ModeSocket == 0 || !ok || stat.Uid != uid || info.Mode().Perm() != 0o600 {
		return "", errors.New("Codex backend 链接未指向当前用户的私有 socket，拒绝释放")
	}
	return target, nil
}
