//go:build darwin

package appserver

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSharedDaemonUsageFencesBlockExclusiveRestart(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	firstRelease, err := AcquireSharedDaemonUsageFence(context.Background())
	if err != nil {
		t.Fatalf("获取第一个使用锁失败：%v", err)
	}
	secondRelease, err := AcquireSharedDaemonUsageFence(context.Background())
	if err != nil {
		t.Fatalf("获取第二个使用锁失败：%v", err)
	}

	entered := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, lockErr := withSharedDaemonOperationLock(context.Background(), func() (LocalDaemonStatus, error) {
			close(entered)
			return LocalDaemonStatus{}, nil
		})
		done <- lockErr
	}()

	select {
	case <-entered:
		t.Fatal("仍有使用锁时不应进入重启事务")
	case <-time.After(150 * time.Millisecond):
	}
	firstRelease()
	firstRelease()
	select {
	case <-entered:
		t.Fatal("仍有第二个使用锁时不应进入重启事务")
	case <-time.After(150 * time.Millisecond):
	}
	secondRelease()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("释放全部使用锁后重启事务未进入")
	}
	if err := <-done; err != nil {
		t.Fatalf("重启事务失败：%v", err)
	}
}

func TestSharedDaemonUsageFenceHonorsContextWhileRestartHeld(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	entered := make(chan struct{})
	releaseExclusive := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, lockErr := withSharedDaemonOperationLock(context.Background(), func() (LocalDaemonStatus, error) {
			close(entered)
			<-releaseExclusive
			return LocalDaemonStatus{}, nil
		})
		done <- lockErr
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("重启事务未取得排他锁")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Millisecond)
	defer cancel()
	if _, err := AcquireSharedDaemonUsageFence(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("排他锁期间应等待到超时，实际 %v", err)
	}
	close(releaseExclusive)
	if err := <-done; err != nil {
		t.Fatalf("重启事务失败：%v", err)
	}
}
