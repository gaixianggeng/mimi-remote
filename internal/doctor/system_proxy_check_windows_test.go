//go:build windows

package doctor

import (
	"errors"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/systemproxy"
)

func TestWindowsSystemProxyCheckReportsEachRuntimeRoute(t *testing.T) {
	checker := &Checker{cfg: config.Config{
		Codex:  config.CodexConfig{Env: map[string]string{"HTTPS_PROXY": "http://codex.example:3128"}},
		Claude: config.ClaudeConfig{Env: map[string]string{"NO_PROXY": "*"}},
	}}
	settingsRead := false
	check := checker.systemProxyCheckWith([]string{"PATH=x"}, func() (systemproxy.Settings, error) {
		settingsRead = true
		return systemproxy.Settings{Proxy: "system.example:8080"}, nil
	})
	if settingsRead {
		t.Fatal("both runtimes have explicit proxy variables, so Windows settings must not be read")
	}
	for _, want := range []string{"Codex 按 codex.env", "Claude 按 claude.env", "不使用系统代理中转"} {
		if !strings.Contains(check.Message, want) {
			t.Fatalf("proxy route check %+v is missing %q", check, want)
		}
	}
	if !check.OK || strings.Contains(check.Message, "codex.example") || strings.Contains(check.Message, "system.example") {
		t.Fatalf("doctor must report sources without proxy addresses: %+v", check)
	}
}

func TestWindowsSystemProxyCheckCombinesExplicitAndSystemRoutes(t *testing.T) {
	checker := &Checker{cfg: config.Config{
		Claude: config.ClaudeConfig{Env: map[string]string{"HTTPS_PROXY": "http://claude.example:3128"}},
	}}
	check := checker.systemProxyCheckWith([]string{"PATH=x"}, func() (systemproxy.Settings, error) {
		return systemproxy.Settings{AutoConfigURL: "http://pac.example/proxy.pac"}, nil
	})
	for _, want := range []string{"Codex 经本机中转按 Windows PAC 联网", "Claude 按 claude.env"} {
		if !strings.Contains(check.Message, want) {
			t.Fatalf("mixed proxy route check %+v is missing %q", check, want)
		}
	}
	if strings.Contains(check.Message, "pac.example") || strings.Contains(check.Message, "claude.example") {
		t.Fatal("doctor must not reveal the proxy address")
	}
}

func TestWindowsSystemProxyCheckIncludesInheritedProxyVariables(t *testing.T) {
	checker := &Checker{cfg: config.Config{
		Codex: config.CodexConfig{Env: map[string]string{"NO_PROXY": "localhost"}},
	}}
	check := checker.systemProxyCheckWith([]string{"HTTPS_PROXY=http://inherited.example:3128"}, func() (systemproxy.Settings, error) {
		t.Fatal("explicit inherited proxy variables must bypass Windows settings")
		return systemproxy.Settings{}, nil
	})
	for _, want := range []string{
		"Codex 按 codex.env 与 agentd 继承环境",
		"Claude 按 agentd 继承环境",
	} {
		if !strings.Contains(check.Message, want) {
			t.Fatalf("inherited proxy route check %+v is missing %q", check, want)
		}
	}
}

func TestWindowsSystemProxyCheckWarnsOnlyForRuntimeWithoutExplicitProxy(t *testing.T) {
	checker := &Checker{cfg: config.Config{
		Codex: config.CodexConfig{Env: map[string]string{"HTTPS_PROXY": "http://codex.example:3128"}},
	}}
	check := checker.systemProxyCheckWith([]string{"PATH=x"}, func() (systemproxy.Settings, error) {
		return systemproxy.Settings{}, errors.New("registry unavailable")
	})
	if check.OK || check.Level != "warning" {
		t.Fatalf("unreadable Windows settings must remain a warning: %+v", check)
	}
	for _, want := range []string{"Codex 按 codex.env", "Claude 无法读取 Windows 系统代理设置，将直连"} {
		if !strings.Contains(check.Message, want) {
			t.Fatalf("warning %+v is missing %q", check, want)
		}
	}
	if strings.Contains(check.Message, "registry unavailable") {
		t.Fatal("doctor must not expose the underlying settings error")
	}
}

func TestWindowsSystemProxyCheckStaysHiddenWhenEverythingIsDirect(t *testing.T) {
	check := (&Checker{}).systemProxyCheckWith([]string{"PATH=x"}, func() (systemproxy.Settings, error) {
		return systemproxy.Settings{}, nil
	})
	if check.Name != "" {
		t.Fatalf("direct networking needs no system proxy check: %+v", check)
	}
}
