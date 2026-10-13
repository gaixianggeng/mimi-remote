package claudebridge

import (
	"os"
	"path/filepath"
	"testing"
)

// 适配器以 claude.env 构造的环境启动，它找到的 claude 由那份环境里的 PATH 决定；探测必须一致。
func TestLookPathInSearchesTheGivenPath(t *testing.T) {
	ext := filepath.Ext(AdapterBinaryName)
	configured := t.TempDir()
	other := t.TempDir()
	for _, dir := range []string{configured, other} {
		writeExecutableFixture(t, filepath.Join(dir, "fake-claude"+ext))
	}

	got, err := LookPathIn("fake-claude", []string{"HOME=/nowhere", "PATH=" + configured})
	if err != nil || got != filepath.Join(configured, "fake-claude"+ext) {
		t.Fatalf("应按给定环境的 PATH 查找：got=(%q,%v)", got, err)
	}
	ordered := "PATH=" + other + string(os.PathListSeparator) + configured
	if got, err := LookPathIn("fake-claude", []string{ordered}); err != nil || got != filepath.Join(other, "fake-claude"+ext) {
		t.Fatalf("PATH 里靠前的目录优先：got=(%q,%v)", got, err)
	}
	if _, err := LookPathIn("fake-claude", []string{"PATH=" + t.TempDir()}); err == nil {
		t.Fatal("给定 PATH 里没有时不应退回当前进程的 PATH")
	}
	explicit := filepath.Join(other, "fake-claude"+ext)
	if got, err := LookPathIn(explicit, []string{"PATH=" + configured}); err != nil || got != explicit {
		t.Fatalf("带路径的命令只检查它本身：got=(%q,%v)", got, err)
	}
	if _, err := LookPathIn("  ", nil); err == nil {
		t.Fatal("空命令应查找失败")
	}
}
