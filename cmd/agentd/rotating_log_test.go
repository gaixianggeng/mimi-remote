package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRotatingLogWriterCapsAndProtectsLogs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "agentd.log")
	writer, err := newRotatingLogWriter(path, 12)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("first-line\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("second\n")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	current, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	previous, err := os.ReadFile(path + ".previous")
	if err != nil {
		t.Fatal(err)
	}
	if string(current) != "second\n" || string(previous) != "first-line\n" {
		t.Fatalf("日志轮转内容不正确 current=%q previous=%q", current, previous)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("日志权限必须是 0600，实际 %o", got)
	}
}

func TestRotatingLogWriterExpandsHomeAndRejectsSymlink(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writer, err := newRotatingLogWriter("~/Library/Logs/mimi-remote/agentd.log", 1024)
	if err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, "Library", "Logs", "mimi-remote", "agentd.log")); err != nil {
		t.Fatal(err)
	}

	target := filepath.Join(home, "target.log")
	if err := os.WriteFile(target, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(home, "linked.log")
	if err := os.Symlink(target, symlink); err != nil {
		t.Fatal(err)
	}
	_, err = newRotatingLogWriter(symlink, 1024)
	if err == nil || !strings.Contains(err.Error(), "不能是目录或符号链接") {
		t.Fatalf("日志写入必须拒绝符号链接，实际 err=%v", err)
	}
}

func TestRotatingLogWriterCapsSingleOversizedWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentd.log")
	writer, err := newRotatingLogWriter(path, 5)
	if err != nil {
		t.Fatal(err)
	}
	written, err := writer.Write([]byte("0123456789"))
	if err != nil {
		t.Fatal(err)
	}
	if written != 10 {
		t.Fatalf("io.Writer 必须报告已消费完整输入，实际 %d", written)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "56789" {
		t.Fatalf("超大单条日志应只保留末尾，实际 %q", content)
	}
}
