//go:build darwin

package appserver

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// StopIdleBackend 用于永久退出 Mac App 托管。先确认没有其它连接、活动回合或队列，
// 再让私有 backend 退出；否则 Homebrew 会在标准 socket 启动第二个 writer。
func (f *FrontDoor) StopIdleBackend(ctx context.Context) error {
	return f.checkIdleBackend(ctx, true)
}

// CanReload 只读确认已有私有 backend 没有连接、活动回合或队列。
func (f *FrontDoor) CanReload(ctx context.Context) error {
	return f.checkIdleBackend(ctx, false)
}

func (f *FrontDoor) checkIdleBackend(ctx context.Context, stop bool) error {
	info, err := os.Lstat(f.backend)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("检查私有 Codex backend 失败：%w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return errors.New("私有 Codex backend 路径不是 socket，拒绝回退 Homebrew")
	}
	conn, err := dialSharedLocalRepairTransport(ctx, &SharedLocalTransport{socket: f.backend})
	if err != nil {
		return fmt.Errorf("无法确认私有 Codex backend 已空闲：%w", err)
	}
	defer conn.Close()
	if err := conn.Initialize(ctx); err != nil {
		return fmt.Errorf("初始化私有 Codex backend 失败：%w", err)
	}
	pid, uid, err := conn.PeerIdentity()
	if err != nil || pid <= 1 || uid != uint32(os.Getuid()) {
		return errors.New("无法确认私有 Codex backend 属于当前用户，拒绝回退 Homebrew")
	}
	process, alive, err := realSharedLocalRepairProcess(pid)
	if err != nil || !alive {
		return errors.New("无法确认私有 Codex backend 进程身份，拒绝回退 Homebrew")
	}
	if err := validateSharedLocalRepairProcess(process, pid, uid); err != nil {
		return err
	}
	check := func() error {
		current, alive, err := realSharedLocalRepairProcess(pid)
		if err != nil || !alive || current != process {
			return errors.New("私有 Codex backend 进程身份已变化，拒绝回退 Homebrew")
		}
		count, err := realSharedLocalRepairSocketNames(ctx, pid, f.backend)
		if err != nil {
			return fmt.Errorf("无法核对私有 Codex backend 的 socket 引用：%w", err)
		}
		if count != 2 {
			return fmt.Errorf("私有 Codex backend 仍有其它客户端或 socket 状态未知（引用数=%d）", count)
		}
		return nil
	}
	if err := check(); err != nil {
		return err
	}
	if err := requireSharedLocalRepairIdle(ctx, conn.RPC()); err != nil {
		return err
	}
	if err := check(); err != nil {
		return err
	}
	if !stop {
		return nil
	}
	if err := canGracefullyDrainFrontDoorOrphan(ctx, process); err != nil {
		return fmt.Errorf("无法确认私有 Codex backend 的安全退出语义：%w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := unix.Kill(pid, unix.SIGHUP); err != nil {
		return fmt.Errorf("请求私有 Codex backend 优雅退出失败：%w", err)
	}
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		current, alive, err := realSharedLocalRepairProcess(pid)
		if err != nil {
			return fmt.Errorf("等待私有 Codex backend 退出失败：%w", err)
		}
		if !alive || current != process {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("等待私有 Codex backend 退出已取消：%w", ctx.Err())
		case <-deadline.C:
			return errors.New("私有 Codex backend 退出超时；未发送强制退出信号")
		case <-ticker.C:
		}
	}
}
