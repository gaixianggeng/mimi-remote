//go:build darwin

package appserver

import (
	"strings"
	"testing"
)

func TestRenderSharedDaemonLaunchAgentSetsControlledSoftFileLimit(t *testing.T) {
	rendered, err := renderSharedDaemonLaunchAgent(
		"/opt/codex/bin/codex",
		map[string]string{"CODEX_HOME": "/Users/tester/.codex"},
		"",
	)
	if err != nil {
		t.Fatalf("渲染 plist 失败：%v", err)
	}
	content := string(rendered)
	want := "<key>SoftResourceLimits</key>\n\t<dict>\n\t\t<key>NumberOfFiles</key>\n\t\t<integer>8192</integer>\n\t</dict>"
	if !strings.Contains(content, want) {
		t.Fatalf("LaunchAgent 必须设置受控的文件描述符 soft limit 8192：\n%s", content)
	}
	if strings.Contains(content, "<key>HardResourceLimits</key>") {
		t.Fatalf("LaunchAgent 不应设置 hard 文件描述符限制：\n%s", content)
	}
}
