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

// EffectiveLocalCodexHome 返回当前本机 App Server 实际使用的 CODEX_HOME。
// SSH 后端的目录只能由远端主机解析，调用方不能用本机路径冒充远端目录。
func (c Config) EffectiveLocalCodexHome() (string, bool) {
	transport := normalizeTransport(c.AppServer.Transport)
	if strings.EqualFold(transport, "ssh") {
		return "", false
	}
	if strings.EqualFold(transport, "local") {
		if home := c.AppServer.SharedCodexHome; home != "" {
			return home, true
		}
	}
	// CODEX_HOME 与 App Server 的 socket 解析保持一致，目录名中的空格不能被裁剪。
	if home := c.Codex.Env["CODEX_HOME"]; home != "" {
		return home, true
	}
	if home := os.Getenv("CODEX_HOME"); home != "" {
		return home, true
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".codex"), true
	}
	return filepath.Join(home, ".codex"), true
}
