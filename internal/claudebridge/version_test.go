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
	if IsSupported("0.2.0") {
		t.Fatal("0.2.0 不应通过最低版本门禁")
	}
	if IsSupported("0.2.7") {
		t.Fatal("0.2.7 会主动触发隐藏 OAuth 刷新，不应通过最低版本门禁")
	}
	if !IsSupported("0.2.8") || !IsSupported("1.0.0") {
		t.Fatal("0.2.8 及更高版本应通过最低版本门禁")
	}
	if IsSupported("0.2.8-beta.1") {
		t.Fatal("最低正式版门禁不能被预发布版本绕过")
	}
}

func TestSupportsThreadItemsList(t *testing.T) {
	if SupportsThreadItemsList("0.2.8") {
		t.Fatal("0.2.8 无视 itemsView 也没有 thread/items/list，不应声明能力")
	}
	if !SupportsThreadItemsList("0.2.9") || !SupportsThreadItemsList("1.0.0") {
		t.Fatal("0.2.9 及更高版本应声明 thread/items/list")
	}
	if SupportsThreadItemsList("0.2.9-beta.1") || SupportsThreadItemsList("") {
		t.Fatal("预发布或缺失版本不能通过能力门禁")
	}
}

func TestSupportsThreadTakeover(t *testing.T) {
	if SupportsThreadTakeover("0.2.10") {
		t.Fatal("0.2.10 没有 thread/takeover，不应声明能力")
	}
	if !SupportsThreadTakeover("0.2.11") || !SupportsThreadTakeover("1.0.0") {
		t.Fatal("0.2.11 及更高版本应声明 thread/takeover")
	}
	if SupportsThreadTakeover("0.2.11-beta.1") || SupportsThreadTakeover("") {
		t.Fatal("预发布或缺失版本不能通过能力门禁")
	}
}

func TestIsComparableRejectsPrereleaseAndUnparsedVersions(t *testing.T) {
	if !IsComparable("2.1.270") || !IsComparable("v0.2.8") {
		t.Fatal("正式三段式版本应可参与比较")
	}
	if IsComparable("2.1.270-beta.1") || IsComparable("2.1") || IsComparable("") {
		t.Fatal("预发布、缺段或空版本不得参与择优比较")
	}
}

func TestInstallHintUsesMonorepo(t *testing.T) {
	if !strings.Contains(InstallHint, BridgeRepository) {
		t.Fatalf("安装提示未指向 Mimi Remote monorepo：%s", InstallHint)
	}
	if strings.Contains(InstallHint, "gaixianggeng/alleycat") {
		t.Fatalf("安装提示不应继续依赖独立 Alleycat fork：%s", InstallHint)
	}
}

func TestSupportsFullAccess(t *testing.T) {
	for _, version := range []string{"", "0.2.12", "0.2.13-beta.1"} {
		if SupportsFullAccess(version) {
			t.Fatalf("旧版或未知版本不能声明完全访问：%q", version)
		}
	}
	if !SupportsFullAccess("0.2.13") || !SupportsFullAccess("1.0.0") {
		t.Fatal("正式版应支持完全访问")
	}
}
