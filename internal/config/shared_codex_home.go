package config

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// ValidateSharedCodexHome 也供只加载诊断配置的前门使用，避免绕过平台和 transport 边界。
func (c Config) ValidateSharedCodexHome() error {
	home := c.AppServer.SharedCodexHome
	if home == "" {
		return nil
	}
	if runtime.GOOS != "darwin" || !strings.EqualFold(strings.TrimSpace(c.AppServer.Transport), "local") {
		return fmt.Errorf("app_server.shared_codex_home 只支持 macOS 的 local 前门")
	}
	if !filepath.IsAbs(home) {
		return fmt.Errorf("app_server.shared_codex_home 必须是绝对路径")
	}
	info, err := os.Stat(home)
	if err != nil {
		return fmt.Errorf("app_server.shared_codex_home 必须是已存在的独立目录：%w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("app_server.shared_codex_home 不是目录")
	}
	return nil
}
