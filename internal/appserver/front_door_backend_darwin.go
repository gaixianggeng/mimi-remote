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
	return f.checkIdleBackend(ctx, true, false)
}

// stopConfirmedBackend 仅用于用户明确确认断连及任务中断后的版本切换。
// 使用 Codex 自身的退出协议，不发送 SIGKILL，也不删除会话目录或 writer 锁。
func (f *FrontDoor) stopConfirmedBackend(ctx context.Context) error {
	return f.checkIdleBackend(ctx, true, true)
}

// CanReload 只读确认已有私有 backend 没有连接、活动回合或队列。
func (f *FrontDoor) CanReload(ctx context.Context) error {
	return f.checkIdleBackend(ctx, false, false)
}

func (f *FrontDoor) checkIdleBackend(ctx context.Context, stop, confirmed bool) error {
	socket, err := privateBackendSocketPath(f.backend)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("检查私有 Codex backend 失败：%w", err)
	}
	conn, err := dialSharedLocalRepairTransport(ctx, &SharedLocalTransport{socket: socket})
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
		if confirmed {
			return nil
		}
		count, err := realSharedLocalRepairSocketNames(ctx, pid, socket)
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
	if !confirmed {
		if err := requireSharedLocalRepairIdle(ctx, conn.RPC()); err != nil {
			return err
		}
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
	if err := check(); err != nil {
		return err
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
	var interrupt <-chan time.Time
	if confirmed {
		// 已验证版本的 Codex 收到 SIGHUP 后，再收到 SIGTERM 会结束 drain、退出并中断任务。
		// 首先给 SIGHUP 一秒收尾；后续仍每次核对 PID 和启动时间，绝不误杀 replacement。
		forceTicker := time.NewTicker(time.Second)
		defer forceTicker.Stop()
		interrupt = forceTicker.C
	}
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
			if confirmed {
				return errors.New("Codex 后台尚未退出，未启动第二个后台；请稍后重新检查")
			}
			return errors.New("私有 Codex backend 退出超时；未发送强制退出信号")
		case <-interrupt:
			if err := check(); err != nil {
				return err
			}
			if err := unix.Kill(pid, unix.SIGTERM); err != nil {
				return fmt.Errorf("请求 Codex 中断任务并退出失败：%w", err)
			}
		case <-ticker.C:
		}
	}
}
