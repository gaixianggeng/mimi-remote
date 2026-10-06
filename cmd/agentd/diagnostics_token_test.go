package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestDiagnosticControlTokenStaysLocalAndStable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if _, err := diagnosticControlToken(path, false); !os.IsNotExist(err) {
		t.Fatalf("读取不能生成凭据：%v", err)
	}
	first, err := diagnosticControlToken(path, true)
	if err != nil || len(first) != 64 {
		t.Fatalf("创建凭据失败：%v", err)
	}
	for _, create := range []bool{true, false} {
		again, err := diagnosticControlToken(path, create)
		if err != nil || again != first {
			t.Fatal("重复启动或 CLI 读取不应更换本机凭据")
		}
	}
	if runtime.GOOS == "windows" {
		return
	}
	if err := os.Chmod(path+".diagnostics.token", 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := diagnosticControlToken(path, true); err == nil {
		t.Fatal("不能使用其他用户可读的凭据")
	}
}

func TestDiagnosticControlTokenRejectsSymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 测试环境不保证符号链接权限")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	target := filepath.Join(dir, "unrelated")
	if err := os.WriteFile(target, []byte("untouched"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path+".diagnostics.token"); err != nil {
		t.Fatal(err)
	}
	if _, err := diagnosticControlToken(path, true); err == nil {
		t.Fatal("不能沿符号链接读取或覆盖凭据")
	}
	data, _ := os.ReadFile(target)
	if string(data) != "untouched" {
		t.Fatal("修改了其它文件")
	}
}

func TestDiagnosticControlTokenExpandsConfigPathLikeServe(t *testing.T) {
	userDirectory, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	first, err := diagnosticControlToken(path, true)
	if err != nil {
		t.Fatal(err)
	}
	relative, err := filepath.Rel(userDirectory, path)
	if err != nil {
		t.Skip("临时目录不在用户目录所在卷")
	}
	again, err := diagnosticControlToken("~/"+filepath.ToSlash(relative), false)
	if err != nil || again != first {
		t.Fatalf("CLI 与服务端必须使用相同的配置路径展开：%v", err)
	}
}
