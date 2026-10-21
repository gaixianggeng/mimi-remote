package httpapi

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

var (
	errTailcatManagedModeRequired  = errors.New("请先在电脑上进入托管模式，再重新生成二维码并扫码")
	errTailcatManagedRelayLocked   = errors.New("托管模式下不能手动修改中继，请先退出托管模式")
	errTailcatManagedGrantRequired = errors.New("这台电脑已开启托管连接，请在 App 的「Mimi 托管连接」里扫码配对")
)

// ConfigureDERPMap 与模式切换共用同一个事务，只有自建模式允许手动改中继。
func (s *tailcatSidecarSupervisor) ConfigureDERPMap(ctx context.Context, rawURL string) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	s.mu.Lock()
	next := s.config
	s.mu.Unlock()
	if next.ConnectionMode() == config.TailcatModeManaged {
		return s.Status(ctx), errTailcatManagedRelayLocked
	}
	normalized, err := config.NormalizeTailcatDERPMapURL(rawURL)
	if err != nil {
		return s.Status(ctx), err
	}
	previousURL, _ := config.NormalizeTailcatDERPMapURL(next.DERPMapURL)
	if normalized == previousURL {
		return s.Status(ctx), nil
	}
	next.DERPMapURL = normalized
	return s.reconfigure(ctx, next, func() error {
		_, err := agentsetup.ConfigureTailcatDERPMap(s.configPath, normalized)
		return err
	})
}

// ConfigureMode 的注册清理回调由托管控制器持锁提供；配置是最后的提交点。
// 即使两个模式的 URL 相同也重建身份，避免将已有免费授权带入托管模式。
func (s *tailcatSidecarSupervisor) ConfigureMode(ctx context.Context, managed bool, clearRegistration func() error) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	s.mu.Lock()
	previous := s.config
	s.mu.Unlock()
	if (previous.ConnectionMode() == config.TailcatModeManaged) == managed {
		if !managed {
			return s.Status(ctx), nil
		}
		return s.reconcileManagedRelay(ctx, previous, clearRegistration)
	}
	next := previous
	if managed {
		official, err := previous.ManagedRelayURL()
		if err != nil {
			return s.Status(ctx), err
		}
		next.Mode = config.TailcatModeManaged
		next.PreviousDERPMapURL = previous.DERPMapURL
		next.DERPMapURL = official
	} else {
		next.Mode = config.TailcatModeSelfHosted
		next.DERPMapURL = previous.PreviousDERPMapURL
		next.PreviousDERPMapURL = ""
	}
	return s.reconfigure(ctx, next, func() error {
		if err := clearRegistration(); err != nil {
			return err
		}
		return agentsetup.ConfigureTailcatMode(s.configPath, previous, next)
	})
}

// reconcileManagedRelay 处理已在托管模式、但中继与当前托管地址不一致的情况
// （配置覆盖变化或新版本更换官方地址）。启动时容忍这种不一致，再次进入托管
// 模式时在这里收敛：重建身份切到新地址，进入前的原中继记录保持不变。
func (s *tailcatSidecarSupervisor) reconcileManagedRelay(
	ctx context.Context,
	previous config.TailcatConfig,
	clearRegistration func() error,
) (tailcatStatus, error) {
	official, err := previous.ManagedRelayURL()
	if err != nil {
		return s.Status(ctx), err
	}
	current, _ := config.NormalizeTailcatDERPMapURL(previous.DERPMapURL)
	if current == official {
		return s.Status(ctx), nil
	}
	next := previous
	next.DERPMapURL = official
	return s.reconfigure(ctx, next, func() error {
		if err := clearRegistration(); err != nil {
			return err
		}
		return agentsetup.ConfigureTailcatMode(s.configPath, previous, next)
	})
}

// AllowClient 只服务自建模式。托管模式的白名单只能由云端授权的策略写入，
// 不带托管授权的 claim 不能借免费白名单绕过订阅；与模式切换共用 operationMu，
// 检查与写入之间不会被切换插队。
func (s *tailcatSidecarSupervisor) AllowClient(ctx context.Context, publicKey string) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	var status tailcatStatus
	s.mu.Lock()
	managed := s.config.ConnectionMode() == config.TailcatModeManaged
	s.mu.Unlock()
	if managed {
		s.applyConfigurationToStatus(&status)
		return status, errTailcatManagedGrantRequired
	}
	err := s.call(ctx, s.controlCallTimeout(), http.MethodPost, "/allow", map[string]string{"public_key": publicKey}, &status)
	s.applyConfigurationToStatus(&status)
	return status, err
}

// reconfigure 在 operationMu 内执行。身份、免费白名单及进程先切换，持久配置最后提交；
// 任一步失败都复用原中继事务的身份快照回滚，取消请求也不能取消恢复。
func (s *tailcatSidecarSupervisor) reconfigure(ctx context.Context, next config.TailcatConfig, commit func() error) (tailcatStatus, error) {
	s.mu.Lock()
	if s.closing || s.starting {
		s.mu.Unlock()
		return tailcatStatus{}, errors.New("Tailcat 正在启动或关闭")
	}
	previous := s.config
	wasRunning := s.cmd != nil
	stateDir := s.stateDir
	s.mu.Unlock()
	if stateDir == "" {
		return tailcatStatus{}, errors.New("Tailcat 缺少配置文件路径")
	}
	snapshot, err := snapshotTailcatIdentityState(stateDir)
	if err != nil {
		return s.Status(ctx), err
	}
	if err := s.stopForReconfiguration(ctx); err != nil {
		return s.rollbackDERPMap(ctx, previous, wasRunning, snapshot, err)
	}
	s.mu.Lock()
	s.config = next
	s.mu.Unlock()
	if err := clearTailcatIdentityState(stateDir); err != nil {
		return s.rollbackDERPMap(ctx, previous, wasRunning, snapshot, err)
	}
	if previous.Enabled {
		if err := s.start(ctx); err != nil {
			return s.rollbackDERPMap(ctx, previous, wasRunning, snapshot, err)
		}
	}
	if err := ctx.Err(); err != nil {
		return s.rollbackDERPMap(ctx, previous, wasRunning, snapshot, err)
	}
	if err := commit(); err != nil {
		return s.rollbackDERPMap(ctx, previous, wasRunning, snapshot, err)
	}
	s.pairTimedOut = false
	return s.Status(ctx), nil
}

func (c *managedPairingController) ConfigureMode(ctx context.Context, managed bool) (tailcatStatus, error) {
	c.operationMu.Lock()
	defer c.operationMu.Unlock()
	if c.stateLoadError != nil {
		return tailcatStatus{}, c.stateLoadError
	}
	previous := c.state
	touched := false
	status, err := c.tailcat.ConfigureMode(ctx, managed, func() error {
		touched = true
		return c.saveStateLocked(managedPairingState{Version: 1})
	})
	if err == nil {
		if touched {
			c.hasApplied = false
		}
		return status, nil
	}
	if touched {
		if restoreErr := c.saveStateLocked(previous); restoreErr != nil {
			// 无法恢复磁盘策略时保持撤销，后台只重试落盘，不能复活旧授权。
			c.state = managedPairingState{Version: 1}
			c.stateWritePending = true
			err = errors.Join(err, restoreErr)
		}
	}
	// 回滚会重启旧进程，托管白名单只在内存中，必须立即重放仍有效的旧策略。
	// 原请求可能已取消，不能用它返回的 Running=false 判断恢复后的实际进程。
	c.hasApplied = false
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	status = c.tailcat.Status(cleanup)
	if status.Running {
		var applyErr error
		if status.Mode == config.TailcatModeManaged && c.cachedPolicyFreshLocked() {
			_, applyErr = c.applyRegisteredPolicyLocked(cleanup, c.state.AllowedMobileKeys)
		} else {
			_, applyErr = c.applyPolicyLocked(cleanup, nil)
		}
		err = errors.Join(err, applyErr)
	}
	return status, err
}
