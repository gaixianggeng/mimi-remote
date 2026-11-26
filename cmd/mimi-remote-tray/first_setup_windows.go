//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
)

func (a *trayApplication) newMaintenanceRunner() maintenanceRunner {
	if a.maintenanceOverride != nil {
		return *a.maintenanceOverride
	}
	installDir := ""
	if a.controller != nil && a.controller.agentPath != "" {
		installDir = filepath.Dir(a.controller.agentPath)
	} else if executable, err := os.Executable(); err == nil {
		installDir = filepath.Dir(executable)
	}
	return maintenanceRunner{
		installDir:      installDir,
		expectedVersion: releaseVersion,
		publisherSHA256: releasePublisherSHA256,
		ops:             defaultWindowsMaintenanceOps(),
	}
}

func (a *trayApplication) isMaintenanceIdentityRejected() bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.maintenanceIdentityRejected
}

func (a *trayApplication) setMaintenanceIdentityRejected(value bool) {
	a.mu.Lock()
	a.maintenanceIdentityRejected = value
	a.mu.Unlock()
}

func statusHasLANEnabled(status agentStatus) bool {
	return (status.ModuleStatus != nil && status.ModuleStatus.LANEnabled) ||
		(status.NetworkStatus != nil && status.NetworkStatus.AllowLAN)
}

func canRunLanMaintenance(status agentStatus, statusErr error, preflightPending bool, brokerMissing bool, identityRejected bool) bool {
	if brokerMissing || identityRejected || needsFirstSetup(status, statusErr, preflightPending) {
		return false
	}
	return status.Version != ""
}

func lanMaintenanceMenuLabel(status agentStatus) string {
	if status.NetworkStatus != nil && status.NetworkStatus.PolicyChecked && !status.NetworkStatus.PolicyOK {
		return "修复专用局域网防火墙…"
	}
	if statusHasLANEnabled(status) && isAffirmativeLANPolicyOK(status) {
		return "管理专用局域网防火墙…"
	}
	return "开启专用局域网访问…"
}

func (a *trayApplication) runFirstSetupMaintenance() {
	if a.controller == nil {
		a.promptMissingBrokerRecovery(showMessage, shellOpenPath)
		return
	}
	if a.isMaintenanceIdentityRejected() {
		a.openOfficialDownloadRecovery()
		return
	}
	if !a.firstSetupRequired() {
		return
	}
	if !a.beginBusy() {
		return
	}
	go func() {
		defer a.endBusy()
		a.executeFirstSetupMaintenance(showMessage, shellOpenPath)
	}()
}

func (a *trayApplication) runLanFirewallMaintenance() {
	if a.controller == nil {
		a.promptMissingBrokerRecovery(showMessage, shellOpenPath)
		return
	}
	if a.isMaintenanceIdentityRejected() {
		a.openOfficialDownloadRecovery()
		return
	}
	if a.firstSetupRequired() {
		return
	}
	if !a.beginBusy() {
		return
	}
	go func() {
		defer a.endBusy()
		a.executeLanFirewallMaintenance(showMessage, shellOpenPath)
	}()
}

func (a *trayApplication) openOfficialDownloadRecovery() {
	a.executeOfficialDownloadRecovery(showMessage, shellOpenPath)
}

func (a *trayApplication) executeOfficialDownloadRecovery(
	show func(uintptr, string, string, uint32) int,
	openURL func(string) error,
) {
	if openURL != nil {
		if err := openURL(maintenanceOfficialDownloadURL); err == nil {
			return
		}
	}
	if show != nil {
		show(a.window, "下载正式安装包", "请前往桌面端正式下载页获取已签名的安装包："+maintenanceOfficialDownloadURL, mbOK|mbIconInfo)
	}
}

func (a *trayApplication) promptMissingBrokerRecovery(
	show func(uintptr, string, string, uint32) int,
	openURL func(string) error,
) {
	if show == nil {
		return
	}
	maintErr := newMaintenanceError(maintenanceFailureImageMissing)
	body := maintErr.Message + "\r\n\r\n是否立即打开官方下载页面？"
	if show(a.window, "Mimi Remote 恢复", body, mbYesNo|mbIconWarning) == idYes && openURL != nil {
		_ = openURL(maintenanceOfficialDownloadURL)
	}
}

func (a *trayApplication) applyMaintenanceOutcome(outcome maintenanceRunOutcome, err error) {
	// Never execute an unverified refresh after identity rejection. Only accept
	// post-run state returned by the verified pinned broker.
	if outcome.BrokerVerified {
		a.setMaintenanceIdentityRejected(false)
		if a.controller != nil {
			a.controller.applyVerifiedMaintenanceStatus(outcome.Status)
		}
		if outcome.Status.Version != "" {
			request := a.beginStatusRequest()
			a.completeStatusRequestWithSetup(request, outcome.Status, nil, !outcome.WorkspaceConfirmed)
			if a.window != 0 {
				procPostMessageW.Call(a.window, wmTrayRefresh, 0, 0)
			}
		}
		return
	}
	var maintErr *maintenanceError
	if err != nil && errors.As(err, &maintErr) &&
		isMaintenanceIdentityRejection(maintErr.Kind) &&
		maintErr.Kind != maintenanceFailureElevatedSession {
		a.setMaintenanceIdentityRejected(true)
		if a.window != 0 {
			procPostMessageW.Call(a.window, wmTrayRefresh, 0, 0)
		}
	}
}

func (a *trayApplication) executeFirstSetupMaintenance(
	show func(uintptr, string, string, uint32) int,
	openURL func(string) error,
) {
	if !a.firstSetupRequired() {
		return
	}

	runner := a.newMaintenanceRunner()
	outcome, err := runner.RunModifyForPurpose(context.Background(), maintenancePurposeConfirmWorkspace)
	a.applyMaintenanceOutcome(outcome, err)

	if err != nil {
		var maintErr *maintenanceError
		if errors.As(err, &maintErr) && maintErr.FallbackToDownload {
			body := maintErr.Message + "\r\n\r\n是否立即打开官方下载页面？"
			if show(a.window, "完成首次设置", body, mbYesNo|mbIconWarning) == idYes && openURL != nil {
				_ = openURL(maintenanceOfficialDownloadURL)
			}
			return
		}
		show(a.window, "完成首次设置", formatTrayUserError(err), mbOK|mbIconWarning)
		return
	}

	if a.firstSetupRequired() {
		show(a.window, "完成首次设置", newMaintenanceError(maintenanceFailureStatusStillUnconfirmed).Message, mbOK|mbIconInfo)
		return
	}
	if a.window != 0 {
		a.showBalloon("Mimi Remote", "首次设置已完成，服务状态已刷新。", niifInfo)
	}
}

func (a *trayApplication) executeLanFirewallMaintenance(
	show func(uintptr, string, string, uint32) int,
	openURL func(string) error,
) {
	if a.firstSetupRequired() {
		return
	}

	runner := a.newMaintenanceRunner()
	outcome, err := runner.RunModifyForPurpose(context.Background(), maintenancePurposeLANFirewall)
	a.applyMaintenanceOutcome(outcome, err)

	if err != nil {
		var maintErr *maintenanceError
		if errors.As(err, &maintErr) && maintErr.FallbackToDownload {
			body := maintErr.Message + "\r\n\r\n是否立即打开官方下载页面？"
			if show(a.window, "专用局域网防火墙", body, mbYesNo|mbIconWarning) == idYes && openURL != nil {
				_ = openURL(maintenanceOfficialDownloadURL)
			}
			return
		}
		show(a.window, "专用局域网防火墙", formatTrayUserError(err), mbOK|mbIconWarning)
		return
	}

	if a.window != 0 {
		a.showBalloon("Mimi Remote", "专用网络防火墙与局域网访问已生效。", niifInfo)
	}
}
