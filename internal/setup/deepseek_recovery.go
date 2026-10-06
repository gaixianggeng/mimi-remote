package setup

import (
	"context"
	"errors"
	"path/filepath"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件处理“Harness 重启后已存启动 token 作废”的恢复（#587）。
//
// dsh web 的启动 token 在每个进程启动时随机生成，只写在 LaunchAgent 的 stdout 日志里，
// Harness 一重启，已保存的 token 必然被拒。这与“服务不可达”不同：服务仍在同一地址上，
// 只是凭据换了，因此可以从本机 LaunchAgent 重新取得同一地址上的新 token。
//
// 恢复只在同一地址上换凭据，且新凭据必须先被该地址上的服务实际接受，所以不会把连接
// 换成另一个服务（见 config.DeepSeekConfig.AutoDiscover）。服务离线、地址不同或使用
// 外部 token 文件时都不替换。

var errDeepSeekRecoveryNotEligible = errors.New("当前 DeepSeek 连接不支持自动更新启动凭据")

const (
	deepSeekCredentialRenewedMessage = "Harness 重启后已自动更新启动凭据，当前连接可用。"
	deepSeekRejectedGuidance         = "Harness 拒绝了保存的启动凭据，通常是 Harness 重启过。" +
		"本机没能自动取得新凭据时，重启 Harness 后点击重新检测，或在手动连接中粘贴新的启动链接。"
	deepSeekOfflineGuidance = "确认 Harness 仍在运行后，点击重新检测。"
)

// RotateDeepSeekCredential 供运行中的 agentd 在 Harness 拒绝已存 token 时调用。
//
// 只处理已启用的受管自动发现连接，且服务地址必须仍是 agentd 启动时加载的
// expectedBaseURL：运行中的 agentd 不能切换服务地址，地址变化仍由 Mac App 的
// refresh 处理并重载 agentd。返回 nil 表示受管 token 文件里已是 Harness 接受的凭据。
func RotateDeepSeekCredential(ctx context.Context, configPath, expectedBaseURL string) error {
	return rotateDeepSeekCredential(ctx, configPath, expectedBaseURL, defaultDeepSeekRuntimeDependencies())
}

func rotateDeepSeekCredential(
	ctx context.Context,
	configPath string,
	expectedBaseURL string,
	dependencies deepSeekRuntimeDependencies,
) error {
	document, err := loadDeepSeekConfigDocument(configPath)
	if err != nil {
		return err
	}
	expected, err := config.NormalizeDeepSeekBaseURL(expectedBaseURL)
	if err != nil || expected == "" || !document.enabled || !document.autoDiscover || document.baseURL != expected {
		return errDeepSeekRecoveryNotEligible
	}
	_, err = recoverRejectedDeepSeek(ctx, document, dependencies)
	return err
}

// recoverRejectedDeepSeek 在已存凭据被拒后，采用同一地址上重新发现并验证过的凭据。
// 成功时已原子写入受管 token，连接保持启用并标记为受管自动发现。
func recoverRejectedDeepSeek(
	ctx context.Context,
	document deepSeekConfigDocument,
	dependencies deepSeekRuntimeDependencies,
) (bool, error) {
	if filepath.Clean(document.tokenFile) != managedDeepSeekTokenPath(document.configPath) {
		return false, errDeepSeekRecoveryNotEligible
	}
	candidate, err := dependencies.discover(ctx)
	if err != nil {
		return false, err
	}
	if candidate.BaseURL != document.baseURL {
		return false, errDeepSeekRecoveryNotEligible
	}
	if err := probeAndRecheckDeepSeek(ctx, candidate, true, dependencies); err != nil {
		return false, err
	}
	return storeDeepSeekConnection(ctx, document, candidate, true, true)
}

// refreshManualDeepSeek 处理手动连接的重新检测。手动连接默认不跟随发现的服务；
// 只有已存凭据被拒、且同一地址上的 Harness 换了新凭据时才更新，这是同一服务的
// 凭据轮换，不是换服务。
func refreshManualDeepSeek(
	ctx context.Context,
	document deepSeekConfigDocument,
	result DeepSeekConfigurationResult,
	dependencies deepSeekRuntimeDependencies,
) DeepSeekConfigurationResult {
	probeErr := probeConfiguredDeepSeek(ctx, document, dependencies)
	if probeErr == nil {
		result.Available = true
		result.Message = "当前 DeepSeek Harness 连接可用。"
		return result
	}
	if errors.Is(probeErr, harnessclient.ErrCredentialsRejected) {
		if changed, err := recoverRejectedDeepSeek(ctx, document, dependencies); err == nil {
			result.Available = true
			result.Discovered = true
			result.RestartRequired = changed
			result.Message = deepSeekCredentialRenewedMessage
			return result
		}
	}
	result.Message = "DeepSeek 已启用，但当前连接不可用。" + deepSeekProbeFailureGuidance(probeErr)
	return result
}

// probeConfiguredDeepSeek 验证已保存的连接；读不到凭据也按不可用处理。
func probeConfiguredDeepSeek(
	ctx context.Context,
	document deepSeekConfigDocument,
	dependencies deepSeekRuntimeDependencies,
) error {
	configured, err := configuredDeepSeekCandidate(document)
	if err != nil {
		return err
	}
	return dependencies.probe(ctx, configured)
}

// deepSeekProbeFailureGuidance 把探测失败翻译成可执行的下一步，不回显底层错误。
func deepSeekProbeFailureGuidance(err error) string {
	if errors.Is(err, harnessclient.ErrCredentialsRejected) {
		return deepSeekRejectedGuidance
	}
	return deepSeekOfflineGuidance
}
