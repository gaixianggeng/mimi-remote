//go:build windows

package main

import (
	"context"
	"errors"
	"path/filepath"
)

func (a *trayApplication) newMaintenanceRunner() maintenanceRunner {
	if a.maintenanceOverride != nil {
		return *a.maintenanceOverride
	}
	installDir := ""
	if a.controller != nil && a.controller.agentPath != "" {
		installDir = filepath.Dir(a.controller.agentPath)
	}
	return maintenanceRunner{
		installDir:      installDir,
		expectedVersion: releaseVersion,
		publisherSHA256: releasePublisherSHA256,
		ops:             defaultWindowsMaintenanceOps(a.controller),
	}
}

func (a *trayApplication) runFirstSetupMaintenance() {
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
	if a.controller != nil {
		a.refreshStatusWithRuntimeRefresh(true)
	} else if outcome.Status.Version != "" {
		request := a.beginStatusRequest()
		a.completeStatusRequestWithSetup(request, outcome.Status, nil, !outcome.WorkspaceConfirmed)
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
