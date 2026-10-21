//go:build windows

package doctor

import (
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestWindowsSystemProxyCheckReportsExplicitCodexProxy(t *testing.T) {
	checker := &Checker{cfg: config.Config{Codex: config.CodexConfig{Env: map[string]string{"HTTPS_PROXY": "http://corp.example:3128"}}}}
	check := checker.systemProxyCheck()
	if check.Name != "windows-system-proxy" || !check.OK || !strings.Contains(check.Message, "codex.env") {
		t.Fatalf("explicit codex.env proxy should be reported as in use: %+v", check)
	}
	if strings.Contains(check.Message, "corp.example") {
		t.Fatal("doctor must not reveal the proxy address")
	}
}

func TestWindowsSystemProxyCheckNeverRevealsProxyAddress(t *testing.T) {
	check := (&Checker{}).systemProxyCheck()
	if check.Name == "" {
		return // 系统代理关闭时不显示这一项。
	}
	if strings.Contains(check.Message, "://") || strings.Contains(check.Message, "127.0.0.1") {
		t.Fatalf("doctor must describe the proxy mode without its address: %q", check.Message)
	}
}
