package claudebridge

import (
	"strings"
	"testing"
)

func TestParseVersion(t *testing.T) {
	tests := []struct {
		input string
		want  string
		ok    bool
	}{
		{input: "alleycat-claude-bridge 0.2.0", want: "0.2.0", ok: true},
		{input: "v0.2.1\n", want: "0.2.1", ok: true},
		{input: "alleycat-claude-bridge 1.4.0-beta.1", want: "1.4.0-beta.1", ok: true},
		{input: "2026-07-16 bridge starting", ok: false},
		{input: "", ok: false},
	}
	for _, test := range tests {
		got, ok := ParseVersion(test.input)
		if got != test.want || ok != test.ok {
			t.Fatalf("ParseVersion(%q)=(%q,%t), want=(%q,%t)", test.input, got, ok, test.want, test.ok)
		}
	}
}

func TestIsSupported(t *testing.T) {
	if IsSupported("0.1.9") {
		t.Fatal("0.1.9 不应通过最低版本门禁")
	}
	if !IsSupported("0.2.0") || !IsSupported("1.0.0") {
		t.Fatal("0.2.0 及更高版本应通过最低版本门禁")
	}
	if IsSupported("0.2.0-beta.1") {
		t.Fatal("最低正式版门禁不能被预发布版本绕过")
	}
}

func TestInstallHintPinsReviewedRevision(t *testing.T) {
	if !strings.Contains(InstallHint, "https://github.com/gaixianggeng/alleycat.git") {
		t.Fatalf("安装提示未指向公开 bridge 仓库：%s", InstallHint)
	}
	if !strings.Contains(InstallHint, "--rev "+BridgeRevision) {
		t.Fatalf("安装提示未固定已审阅 revision：%s", InstallHint)
	}
}
