package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

// An access repair runs independently of runtime checks. During this action
// do not execute an assistant named by a previously accessible config.
func repairDoctorFileAccess(ctx context.Context, path string, asJSON bool, w io.Writer) (bool, error) {
	raw, err := config.ReadPrivatePreflightFile(path, 4<<20)
	target := path
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, onboardingFailure("config_missing", "config_store", false, err)
		}
		if config.PrivateFileDiagnostic(err) != "config_permissions_unsafe" {
			return false, onboardingFailure("config_invalid", "config_store", true, err)
		}
	} else {
		snapshot := config.InspectCommittedDocument(raw)
		if snapshot.Code != "config_permissions_unsafe" {
			return false, setup.CheckRepairSource(path)
		}
		target = config.ExpandPath(snapshot.Config.AppServer.WSTokenFile)
		// Only the companion residing beside this config belongs to the managed
		// installation. Preserve an externally located credential for recovery.
		if !snapshot.Config.AppServer.Managed || filepath.Dir(filepath.Clean(target)) != filepath.Dir(filepath.Clean(path)) {
			return false, onboardingFailure("config_recovery_required", "config_store", true, errors.New("请检查保留的凭据文件"))
		}
	}
	err = config.WithConfigCommitLock(ctx, path, func() error {
		if err := config.CheckSetupWriteAvailable(path); err != nil {
			return err
		}
		if target != path {
			current, err := config.ReadPrivatePreflightFile(path, 4<<20)
			if err != nil || string(current) != string(raw) {
				return onboardingFailure("config_concurrent_change", "config_store", true, errors.New("配置已更改，请重新检查"))
			}
		}
		_, err := config.RepairPrivatePermissions(target)
		return err
	})
	if err != nil {
		return false, onboardingFailure("config_recovery_required", "config_store", true, err)
	}
	const fix = "已收紧凭据文件的访问权限"
	if asJSON {
		return true, printJSONTo(w, map[string]any{"fixes": []string{fix}, "results": doctor.Results{OK: true, Version: version, Checks: []doctor.Check{{Name: "file-access", OK: true, Message: fix}}}, "restart_required": false})
	}
	fmt.Fprintln(w, fix)
	return true, nil
}
