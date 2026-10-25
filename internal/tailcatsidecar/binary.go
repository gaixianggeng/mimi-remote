// Package tailcatsidecar 定位随 agentd 安装的 Tailcat 辅助程序。agentd 启动 sidecar
// 与 agentd doctor 共用同一套查找顺序，诊断结论才与实际启动行为一致。
package tailcatsidecar

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// BaseName 是辅助程序不含平台扩展名的文件名。
const BaseName = "mimi-tailcat-experiment"

const versionProbeTimeout = 5 * time.Second

// BinaryName 返回当前平台上的辅助程序文件名。
func BinaryName() string {
	if runtime.GOOS == "windows" {
		return BaseName + ".exe"
	}
	return BaseName
}

// Resolve 依次使用 tailcat.sidecar_bin、AGENTD_TAILCAT_BIN、agentd 同目录与 PATH。
func Resolve(configured string) (string, error) {
	if value := strings.TrimSpace(configured); value != "" {
		if path, err := exec.LookPath(value); err == nil {
			return path, nil
		}
		return "", fmt.Errorf("找不到 Tailcat sidecar：%s", value)
	}
	if value := strings.TrimSpace(os.Getenv("AGENTD_TAILCAT_BIN")); value != "" {
		if path, err := exec.LookPath(value); err == nil {
			return path, nil
		}
		return "", fmt.Errorf("AGENTD_TAILCAT_BIN 不可执行：%s", value)
	}
	name := BinaryName()
	if executable, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(executable), name)
		if info, statErr := os.Stat(candidate); statErr == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	if path, err := exec.LookPath(name); err == nil {
		return path, nil
	}
	switch runtime.GOOS {
	case "linux":
		return "", fmt.Errorf("未安装 %s；请下载完整 Linux Release 包，在解压目录执行 bash ./scripts/install-linux.sh upgrade 后重试；Tailcat 保持关闭", name)
	case "windows":
		return "", fmt.Errorf("安装目录中缺少 %s；请重新运行最新的 Mimi Remote Windows 安装器后重试；Tailcat 保持关闭", name)
	}
	return "", fmt.Errorf("未安装 %s；Tailcat 实验保持关闭", name)
}

// Version 运行辅助程序的 version 子命令（不是 --version）。
func Version(ctx context.Context, path string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, versionProbeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "version")
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return "", errors.New("Tailcat 辅助程序版本探测超时")
		}
		return "", fmt.Errorf("Tailcat 辅助程序无法运行：%w", err)
	}
	version := strings.TrimSpace(stdout.String())
	if version == "" || strings.ContainsAny(version, "\r\n") || len(version) > 64 {
		return "", errors.New("Tailcat 辅助程序没有返回可识别的版本")
	}
	return version, nil
}
