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

func (a *trayApplication) runFirstSetupMaintenance() {
	if a.controller == nil {
		a.promptMissingBrokerRecovery(showMessage, shellOpenPath)
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

func (a *trayApplication) executeFirstSetupMaintenance(
	show func(uintptr, string, string, uint32) int,
	openURL func(string) error,
) {
	if !a.firstSetupRequired() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), maintenanceDefaultTimeout)
	defer cancel()

	runner := a.newMaintenanceRunner()
	outcome, err := runner.RunModify(ctx, true)
	// Never execute an unverified refresh after identity rejection. Only accept
	// post-run state returned by the verified pinned broker.
	if outcome.BrokerVerified {
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
	}

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
