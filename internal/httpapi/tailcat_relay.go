package httpapi

import (
	"context"
	"errors"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

// ConfigureRelay 将退出托管与切换免费中继放进同一个身份快照事务。
// 新中继无法启动时直接恢复原来的托管节点、免费节点和注册，连接不会停在中间模式。
func (s *tailcatSidecarSupervisor) ConfigureRelay(ctx context.Context, rawURL string, clearRegistration func() error) (tailcatStatus, error) {
	if s == nil {
		return tailcatStatus{}, errors.New("Tailcat 管理器未初始化")
	}
	s.operationMu.Lock()
	defer s.operationMu.Unlock()
	s.mu.Lock()
	previous := s.config
	s.mu.Unlock()
	normalized, err := config.NormalizeTailcatDERPMapURL(rawURL)
	if err != nil {
		return s.Status(ctx), err
	}
	if previous.IsManagedRelay(normalized) {
		return s.Status(ctx), errTailcatOfficialRelayManaged
	}
	managed := previous.ConnectionMode() == config.TailcatModeManaged
	current, _ := config.NormalizeTailcatDERPMapURL(previous.DERPMapURL)
	if !managed && normalized == current {
		return s.Status(ctx), nil
	}
	next := previous
	next.Mode = config.TailcatModeSelfHosted
	next.DERPMapURL = normalized
	next.PreviousDERPMapURL = ""
	prepareIdentity := clearTailcatIdentityState
	freeRelay, _ := config.NormalizeTailcatDERPMapURL(previous.FreeRelayURL())
	if managed && normalized == freeRelay {
		prepareIdentity = restoreHostFromFreeNode
	}
	return s.reconfigure(ctx, next, prepareIdentity, func() error {
		if managed {
			if err := clearRegistration(); err != nil {
				return err
			}
		}
		return agentsetup.ConfigureTailcatMode(s.configPath, previous, next)
	})
}
