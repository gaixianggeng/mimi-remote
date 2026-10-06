package harnessclient

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// 凭据文件必须是 0600，过宽的权限直接拒绝加载。
func TestReadTokenFileEnforcesPrivatePermissions(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 没有 POSIX 权限位")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "deepseek.token")
	if err := os.WriteFile(path, []byte("startup-token-fixture\n"), 0o600); err != nil {
		t.Fatalf("写入 fixture 失败：%v", err)
	}
	token, err := ReadTokenFile(path)
	if err != nil {
		t.Fatalf("0600 文件应可读取：%v", err)
	}
	if token != "startup-token-fixture" {
		t.Fatalf("token 内容不符：%q", token)
	}

	for _, mode := range []os.FileMode{0o644, 0o640, 0o604, 0o666, 0o777} {
		t.Run(mode.String(), func(t *testing.T) {
			if err := os.Chmod(path, mode); err != nil {
				t.Fatalf("chmod 失败：%v", err)
			}
			if _, err := ReadTokenFile(path); err == nil {
				t.Fatalf("权限 %#o 应被拒绝", mode)
			}
		})
	}
}

// 多行内容说明文件被误当成别的东西，不能当成 token。
func TestReadTokenFileRejectsMultilineContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "deepseek.token")
	if err := os.WriteFile(path, []byte("first-line\nsecond-line\n"), 0o600); err != nil {
		t.Fatalf("写入 fixture 失败：%v", err)
	}
	if _, err := ReadTokenFile(path); err == nil {
		t.Fatal("多行内容应被拒绝")
	}
}

// 空白与缺失路径都要有明确错误，不能返回空 token 让上层去认证。
func TestReadTokenFileRejectsEmptyAndMissing(t *testing.T) {
	if _, err := ReadTokenFile(""); err == nil {
		t.Fatal("空路径应被拒绝")
	}
	if _, err := ReadTokenFile("   "); err == nil {
		t.Fatal("纯空白路径应被拒绝")
	}
	if _, err := ReadTokenFile(filepath.Join(t.TempDir(), "absent.token")); err == nil {
		t.Fatal("不存在的文件应被拒绝")
	}

	dir := t.TempDir()
	if _, err := ReadTokenFile(dir); err == nil {
		t.Fatal("目录路径应被拒绝")
	}

	empty := filepath.Join(dir, "empty.token")
	if err := os.WriteFile(empty, []byte("  \n"), 0o600); err != nil {
		t.Fatalf("写入 fixture 失败：%v", err)
	}
	if _, err := ReadTokenFile(empty); err == nil {
		t.Fatal("空文件应被拒绝")
	}
}

// 超大文件说明路径指向了别的东西，不能整份读进内存。
func TestReadTokenFileRejectsOversizedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "big.token")
	if err := os.WriteFile(path, []byte(strings.Repeat("a", maxTokenFileBytes+1)), 0o600); err != nil {
		t.Fatalf("写入 fixture 失败：%v", err)
	}
	if _, err := ReadTokenFile(path); err == nil {
		t.Fatal("超过上限的文件应被拒绝")
	}
}

// 读到的 token 要能直接用于认证，不必再加工。
func TestReadTokenFileFeedsAuthenticate(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	path := filepath.Join(t.TempDir(), "deepseek.token")
	if err := os.WriteFile(path, []byte("  startup-token-fixture  \n"), 0o600); err != nil {
		t.Fatalf("写入 fixture 失败：%v", err)
	}
	token, err := ReadTokenFile(path)
	if err != nil {
		t.Fatalf("读取 token 失败：%v", err)
	}
	client, err := New(Config{BaseURL: server.URL, AccessToken: token})
	if err != nil {
		t.Fatalf("构造客户端失败：%v", err)
	}
	if err := client.Authenticate(t.Context()); err != nil {
		t.Fatalf("用文件里的 token 认证失败：%v", err)
	}
}
