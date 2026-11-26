package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// 隧道会把远程 TCP 请求转为回环连接，因此不能用配对 Token 管理本机日志。
// 独立凭据只留在配置文件旁，不进入配对信息或任何远程响应。
func diagnosticControlToken(configPath string, create bool) (string, error) {
	path := config.ExpandPath(configPath) + ".diagnostics.token"
	value, err := readDiagnosticControlToken(path)
	if err == nil || !create || !errors.Is(err, os.ErrNotExist) {
		return value, err
	}
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	value = hex.EncodeToString(random)
	file, err := config.CreatePrivateTemp(filepath.Dir(path), ".diagnostics-token-")
	if err != nil {
		return "", err
	}
	defer os.Remove(file.Name())
	if _, err := io.WriteString(file, value); err != nil {
		_ = file.Close()
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	// 原子发布完整凭据且不覆盖已有值，避免重复启动使仍在运行的服务失联。
	if err := os.Link(file.Name(), path); err != nil && !errors.Is(err, os.ErrExist) {
		return "", err
	}
	return readDiagnosticControlToken(path)
}

func readDiagnosticControlToken(path string) (string, error) {
	data, err := config.ReadPrivatePreflightFile(path, 64)
	if err != nil {
		return "", err
	}
	if len(data) != 64 {
		return "", errors.New("本机诊断凭据长度无效")
	}
	if _, err := hex.DecodeString(string(data)); err != nil {
		return "", errors.New("本机诊断凭据格式无效")
	}
	return string(data), nil
}
