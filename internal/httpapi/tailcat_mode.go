package httpapi

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

var (
	errTailcatManagedModeRequired  = errors.New("请先在电脑的「中转服务」里选择 Mimi 中转，再重新生成二维码并扫码")
	errTailcatManagedRelayLocked   = errors.New("正在使用 Mimi 中转，不能手动修改中继；请先在「中转服务」里改回默认或自建中转")
	errTailcatManagedGrantRequired = errors.New("免费线路还没有就绪，请稍后重新扫码；也可以在 App 的「Mimi 中转」里扫码配对")
	errTailcatOfficialRelayManaged = errors.New("Mimi 中转的服务器只给开通的设备使用，这里不用填写；留空会使用 Tailcat 默认中继")
)

// leaveOfficialRelayWhenSelfHosted 修复「不是托管模式却连着官方中继」的旧配置。官方中继开启准入后
// 这样的节点一定被拒绝，已配对设备本来就连不上，所以直接回到免费的默认中继并换新身份。
// 只比较内置官方地址：managed_derp_map_url 可被测试或自建控制面覆盖，覆盖后的地址不一定开启准入。
func (s *tailcatSidecarSupervisor) leaveOfficialRelayWhenSelfHosted() error {
	s.mu.Lock()
	current := s.config
	s.mu.Unlock()
	normalized, err := config.NormalizeTailcatDERPMapURL(current.DERPMapURL)
	if err != nil || normalized != config.DefaultManagedTailcatDERPMapURL ||
		current.ConnectionMode() == config.TailcatModeManaged {
		return nil
	}
	if _, err := agentsetup.ConfigureTailcatDERPMap(s.configPath, ""); err != nil {
		return fmt.Errorf("切回默认中继：%w", err)
	}
	if err := clearTailcatIdentityState(s.stateDir); err != nil {
		return err
	}
	s.mu.Lock()
	s.config.DERPMapURL = ""
	s.mu.Unlock()
	log.Printf("tailcat sidecar: 官方中继只接受托管节点，已切回默认中继")
	return nil
}

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
	if normalized == config.DefaultManagedTailcatDERPMapURL {
		return s.Status(ctx), errTailcatOfficialRelayManaged
	}
	previousURL, _ := config.NormalizeTailcatDERPMapURL(next.DERPMapURL)
	if normalized == previousURL {
		return s.Status(ctx), nil
	}
	next.DERPMapURL = normalized
	return s.reconfigure(ctx, next, clearTailcatIdentityState, func() error {
		_, err := agentsetup.ConfigureTailcatDERPMap(s.configPath, normalized)
		return err
	})
}

// ConfigureMode 的注册清理回调由托管控制器持锁提供；配置是最后的提交点。
// 托管节点总用新身份，已有免费授权不会带进托管模式。原节点变成免费节点继续工作，
// 所以切换模式不影响已配对的免费设备；退出托管时再把它换回来。
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
	var prepareIdentity func(string) error
	if managed {
		official, err := previous.ManagedRelayURL()
		if err != nil {
			return s.Status(ctx), err
		}
		next.Mode = config.TailcatModeManaged
		next.PreviousDERPMapURL = previous.DERPMapURL
		next.DERPMapURL = official
		prepareIdentity = keepHostAsFreeNode
		if previous.IsManagedRelay(previous.DERPMapURL) {
			// 原节点连着官方中继，当免费节点也会被准入拒绝，不如让免费节点从默认中继重新开始。
			prepareIdentity = clearTailcatIdentityState
		}
	} else {
		next.Mode = config.TailcatModeSelfHosted
		next.DERPMapURL = previous.FreeRelayURL()
		next.PreviousDERPMapURL = ""
		prepareIdentity = restoreHostFromFreeNode
	}
	return s.reconfigure(ctx, next, prepareIdentity, func() error {
		if err := clearRegistration(); err != nil {
			return err
		}
		return agentsetup.ConfigureTailcatMode(s.configPath, previous, next)
	})
}

// keepHostAsFreeNode 把当前稳定节点改名成免费节点。身份和内嵌的中继都没变，已配对设备手里的
// 地址继续有效；clients.json 本来就属于免费节点，不用动。
func keepHostAsFreeNode(stateDir string) error {
	if err := removeTailcatStateFiles(stateDir,
		"pair.private.json", "pair.address", "free.private.json", "free.address",
		"free-pair.private.json", "free-pair.address"); err != nil {
		return err
	}
	return renameTailcatStateFiles(stateDir, map[string]string{
		"host.private.json": "free.private.json",
		"host.address":      "free.address",
	})
}

func restoreHostFromFreeNode(stateDir string) error {
	if err := removeTailcatStateFiles(stateDir,
		"host.private.json", "host.address", "pair.private.json", "pair.address",
		"free-pair.private.json", "free-pair.address"); err != nil {
		return err
	}
	return renameTailcatStateFiles(stateDir, map[string]string{
		"free.private.json": "host.private.json",
		"free.address":      "host.address",
	})
}

// clearManagedNodeIdentity 只换托管节点的身份，免费节点和它的设备不受影响。
func clearManagedNodeIdentity(stateDir string) error {
	return removeTailcatStateFiles(stateDir, "host.private.json", "host.address", "pair.private.json", "pair.address")
}

func removeTailcatStateFiles(stateDir string, names ...string) error {
	for _, name := range names {
		if err := os.Remove(filepath.Join(stateDir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("清理 Tailcat %s：%w", name, err)
		}
	}
	return nil
}

func renameTailcatStateFiles(stateDir string, names map[string]string) error {
	for from, to := range names {
		err := os.Rename(filepath.Join(stateDir, from), filepath.Join(stateDir, to))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("移动 Tailcat %s：%w", from, err)
		}
	}
	return nil
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
	return s.reconfigure(ctx, next, clearManagedNodeIdentity, func() error {
		if err := clearRegistration(); err != nil {
			return err
		}
		return agentsetup.ConfigureTailcatMode(s.configPath, previous, next)
	})
}

// AllowClient 写入免费白名单。托管模式下它只进免费节点，托管节点的放行名单只由云端策略写入，
// 所以不带托管授权的 claim 绕不过订阅。与模式切换共用 operationMu，写入不会被切换插队。
func (s *tailcatSidecarSupervisor) AllowClient(ctx context.Context, publicKey string) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	var status tailcatStatus
	err := s.call(ctx, s.controlCallTimeout(), http.MethodPost, "/allow", map[string]string{"public_key": publicKey}, &status)
	s.applyConfigurationToStatus(&status)
	return status, err
}

// reconfigure 在 operationMu 内执行。身份、免费白名单及进程先切换，持久配置最后提交；
// 任一步失败都复用原中继事务的身份快照回滚，取消请求也不能取消恢复。
func (s *tailcatSidecarSupervisor) reconfigure(
	ctx context.Context,
	next config.TailcatConfig,
	prepareIdentity func(stateDir string) error,
	commit func() error,
) (tailcatStatus, error) {
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
	if err := prepareIdentity(stateDir); err != nil {
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
	return c.configureConnection(ctx, func(clearRegistration func() error) (tailcatStatus, error) {
		return c.tailcat.ConfigureMode(ctx, managed, clearRegistration)
	})
}

// 两种入口共用注册快照与失败策略重放，不能先提交退出托管再单独换中继。
func (c *managedPairingController) ConfigureRelay(ctx context.Context, url string) (tailcatStatus, error) {
	return c.configureConnection(ctx, func(clearRegistration func() error) (tailcatStatus, error) {
		return c.tailcat.ConfigureRelay(ctx, url, clearRegistration)
	})
}

func (c *managedPairingController) configureConnection(ctx context.Context, apply func(func() error) (tailcatStatus, error)) (tailcatStatus, error) {
	c.operationMu.Lock()
	defer c.operationMu.Unlock()
	if c.stateLoadError != nil {
		return tailcatStatus{}, c.stateLoadError
	}
	previous := c.state
	touched := false
	status, err := apply(func() error {
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
