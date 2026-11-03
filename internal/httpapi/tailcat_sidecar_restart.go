package httpapi

import (
	"context"
	"log"
	"os/exec"
	"time"
)

const (
	tailcatRestartBaseDelay = time.Second
	// 只封顶间隔、不封顶次数：断网或中继故障可能持续很久，放弃重试就又回到
	// 「只有重启 agentd 才能恢复」。启动即崩时每 5 分钟试一次，不构成死循环。
	tailcatRestartMaxDelay = 5 * time.Minute
	// 稳定运行超过这个时长才清零退避，否则「就绪后马上崩」的进程永远按首次失败重试。
	tailcatRestartStableUptime = 2 * time.Minute
	// 与定时同步同一预算；失败时由定时同步继续收敛。
	tailcatRestartSyncTimeout = 10 * time.Second
)

// setRestartHandler 注册自动重启成功后的回调，在 operationMu 之外调用。
func (s *tailcatSidecarSupervisor) setRestartHandler(handler func(context.Context)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onRestarted = handler
}

// scheduleRestartLocked 在进程已经退出后判断是否自动重启。主动停止都不重启；
// 启动期间的退出由 start 的调用方处理（启用失败要回滚配置，不能再被拉起来）。
func (s *tailcatSidecarSupervisor) scheduleRestartLocked(cmd *exec.Cmd) {
	if s.closing || !s.config.Enabled || s.starting || s.stoppingCmd == cmd {
		return
	}
	stable := s.restartStableUptime
	if stable <= 0 {
		stable = tailcatRestartStableUptime
	}
	if !s.readyAt.IsZero() && time.Since(s.readyAt) >= stable {
		s.restartFailures = 0
	}
	// 已有循环时不新开：它结束前会重新检查进程是否还在。
	if s.restartCancel != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.restartCancel = cancel
	go s.restartLoop(ctx, cancel)
}

// cancelRestartLocked 让等待中的循环退出，也让正在等待就绪的重启立刻放弃，
// 否则用户关闭和 agentd 退出都要等 operationMu 等满就绪超时。
func (s *tailcatSidecarSupervisor) cancelRestartLocked() {
	if s.restartCancel != nil {
		s.restartCancel()
		s.restartCancel = nil
	}
}

func (s *tailcatSidecarSupervisor) restartLoop(ctx context.Context, cancel context.CancelFunc) {
	defer cancel()
	for {
		s.mu.Lock()
		delay := s.nextRestartDelayLocked()
		s.mu.Unlock()
		log.Printf("tailcat sidecar: %s 后自动重启", delay)
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		if s.attemptRestart(ctx) {
			s.notifyRestarted(ctx)
		}
		if s.finishRestartLoop(ctx) {
			return
		}
	}
}

func (s *tailcatSidecarSupervisor) nextRestartDelayLocked() time.Duration {
	base, limit := s.restartBaseDelay, s.restartMaxDelay
	if base <= 0 {
		base = tailcatRestartBaseDelay
	}
	if limit <= 0 {
		limit = tailcatRestartMaxDelay
	}
	delay := base
	for range s.restartFailures {
		delay *= 2
		if delay >= limit {
			delay = limit
			break
		}
	}
	s.restartFailures++
	return min(delay, limit)
}

// attemptRestart 经 operationMu 与配对、改配置串行。等锁期间状态可能已变，必须重新判断。
func (s *tailcatSidecarSupervisor) attemptRestart(ctx context.Context) bool {
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	if ctx.Err() != nil || !s.restartNeeded() {
		return false
	}
	if err := s.start(ctx); err != nil {
		// 取消来自用户关闭或 agentd 退出，不是失败。
		if ctx.Err() == nil {
			log.Printf("tailcat sidecar: 自动重启失败：%v", err)
		}
		return false
	}
	log.Printf("tailcat sidecar: 自动重启成功")
	return true
}

func (s *tailcatSidecarSupervisor) restartNeeded() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.closing && s.config.Enabled && s.cmd == nil
}

func (s *tailcatSidecarSupervisor) notifyRestarted(ctx context.Context) {
	s.mu.Lock()
	handler := s.onRestarted
	s.mu.Unlock()
	if handler == nil {
		return
	}
	syncContext, cancel := context.WithTimeout(ctx, tailcatRestartSyncTimeout)
	defer cancel()
	handler(syncContext)
}

// finishRestartLoop 与 scheduleRestartLocked 用同一把锁交接：循环还登记着时新进程退出，
// reap 不会新开循环，这里必须看到进程又没了并继续重试，否则这次退出就丢了。
func (s *tailcatSidecarSupervisor) finishRestartLoop(ctx context.Context) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	// 已取消的循环在 cancelRestartLocked 时就注销了，字段可能属于新循环。
	if ctx.Err() != nil {
		return true
	}
	if !s.closing && s.config.Enabled && s.cmd == nil {
		return false
	}
	s.restartCancel = nil
	return true
}
