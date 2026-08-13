package setup

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestConfigCommitLockMakesCASAndRenameAtomicAcrossMimiWriters(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	original := []byte("{\"generation\":1}\n")
	newer := []byte("{\"generation\":2}\n")
	stale := []byte("{\"generation\":3}\n")
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}

	entered := make(chan struct{})
	release := make(chan struct{})
	firstDone := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		firstDone <- withConfigCommitLock(ctx, path, func() error {
			close(entered)
			<-release
			return writePrivateFileAtomically(path, newer)
		})
	}()
	<-entered

	staleDone := make(chan error, 1)
	go func() {
		staleDone <- writePrivateFileAtomicallyCAS(path, original, stale)
	}()
	select {
	case err := <-staleDone:
		t.Fatalf("第二个 Mimi writer 不得穿过提交锁：%v", err)
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	if err := <-firstDone; err != nil {
		t.Fatal(err)
	}
	if err := <-staleDone; err == nil || !strings.Contains(err.Error(), "配置已被其他进程修改") {
		t.Fatalf("锁释放后 stale CAS 必须拒绝覆盖：%v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(newer) {
		t.Fatalf("最终配置必须保留先提交的新版本：%s", got)
	}
}

func TestConfigCommitLockPathMatchesFilesystemCaseSemantics(t *testing.T) {
	dir := t.TempDir()
	lower := filepath.Join(dir, "config.json")
	upper := filepath.Join(dir, "Config.json")
	if err := os.WriteFile(lower, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	lowerLock, err := configCommitLockPath(lower)
	if err != nil {
		t.Fatal(err)
	}
	upperLock, err := configCommitLockPath(upper)
	if err != nil {
		t.Fatal(err)
	}
	_, upperStatErr := os.Stat(upper)
	if upperStatErr == nil && lowerLock != upperLock {
		t.Fatalf("大小写不敏感卷的别名必须共用锁：lower=%q upper=%q", lowerLock, upperLock)
	}
	if os.IsNotExist(upperStatErr) && lowerLock == upperLock {
		t.Fatalf("大小写敏感卷的不同文件不能误用同一把锁：%q", lowerLock)
	}
}
