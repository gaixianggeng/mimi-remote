package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

// An access repair runs independently of runtime checks. During this action
// do not execute an assistant named by a previously accessible config.
func repairDoctorFileAccess(ctx context.Context, path string, asJSON bool, w io.Writer) (bool, error) {
	raw, err := config.ReadPrivatePreflightFile(path, 4<<20)
	if errors.Is(err, os.ErrNotExist) {
		return false, onboardingFailure("config_missing", "config_store", false, err)
	}
	if err == nil {
		_, err = config.CheckCredentialPermissions(raw)
		if err == nil {
			return false, setup.CheckRepairSource(path)
		}
	}
	if config.PrivateFileDiagnostic(err) != "config_permissions_unsafe" {
		return false, onboardingFailure("config_invalid", "config_store", true, err)
	}
	err = config.WithConfigCommitLock(ctx, path, func() error {
		if err := config.CheckSetupWriteAvailable(path); err != nil {
			return err
		}
		if raw == nil {
			if _, err := config.RepairPrivatePermissions(path); err != nil {
				return err
			}
		}
		repaired := map[string]bool{}
		for {
			current, err := config.ReadPrivatePreflightFile(path, 4<<20)
			if err != nil {
				return err
			}
			if raw != nil && !bytes.Equal(current, raw) {
				return onboardingFailure("config_concurrent_change", "config_store", true, errors.New("配置已更改，请重新检查"))
			}
			raw = current
			target, err := config.CheckCredentialPermissions(raw)
			if err == nil {
				return nil
			}
			if repaired[target] {
				return onboardingFailure("config_concurrent_change", "config_store", true, err)
			}
			if config.PrivateFileDiagnostic(err) != "config_permissions_unsafe" || !setup.IsManagedCredential(path, raw, target) {
				return errors.New("请检查保留的凭据文件")
			}
			if _, err := config.RepairPrivatePermissions(target); err != nil {
				return err
			}
			repaired[target] = true
		}
	})
	if err != nil {
		return false, onboardingFailure("config_recovery_required", "config_store", true, err)
	}
	const fix = "已修复凭据文件的访问权限"
	if asJSON {
		return true, printJSONTo(w, map[string]any{"fixes": []string{fix}, "results": doctor.Results{OK: true, Version: version, Checks: []doctor.Check{{Name: "file-access", OK: true, Message: fix}}}, "restart_required": false})
	}
	fmt.Fprintln(w, fix)
	return true, nil
}
