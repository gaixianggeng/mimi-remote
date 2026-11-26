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

// Inspect every file before deciding whether doctor needs its access-only
// branch. This includes recovery evidence left before a config was published.
func doctorPermissionProblem(path string) (raw []byte, target string, referenced bool, err error) {
	raw, readErr := config.ReadPrivatePreflightFile(path, 4<<20)
	if target, err = config.CheckCompanionPermissions(path); err != nil {
		return raw, target, false, err
	}
	if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
		return nil, path, false, readErr
	}
	target, err = config.CheckCredentialPermissions(raw)
	return raw, target, true, err
}

// Repair only metadata under the commit lock. Leave replay and runtime checks
// for a subsequent invocation so repaired input cannot immediately run a binary.
func repairDoctorFileAccess(ctx context.Context, path, explicitFile string, asJSON bool, w io.Writer) (bool, error) {
	expected, _, _, err := doctorPermissionProblem(path)
	if err == nil {
		if expected == nil {
			return false, nil
		}
		return false, setup.CheckRepairSource(path)
	}
	if config.PrivateFileDiagnostic(err) != "config_permissions_unsafe" {
		return false, onboardingFailure("config_invalid", "config_store", true, err)
	}
	err = config.WithConfigCommitLock(ctx, path, func() error {
		repaired := map[string]bool{}
		for {
			raw, target, referenced, err := doctorPermissionProblem(path)
			if expected != nil && !bytes.Equal(expected, raw) {
				return onboardingFailure("config_concurrent_change", "config_store", true, errors.New("配置已更改，请重新检查"))
			}
			expected = raw
			if err == nil {
				return nil
			}
			if config.PrivateFileDiagnostic(err) != "config_permissions_unsafe" {
				return err
			}
			if repaired[target] {
				return onboardingFailure("config_concurrent_change", "config_store", true, err)
			}
			namedTarget := false
			if explicitFile != "" {
				id, e := config.ConfigPathIdentity(target)
				explicit, e2 := config.ConfigPathIdentity(explicitFile)
				namedTarget = e == nil && e2 == nil && id == explicit
			}
			if referenced && !namedTarget && !setup.IsManagedCredential(path, raw, target) {
				return onboardingFailure("config_permissions_unsafe", "config_store", true, errors.New("外部凭据需使用 doctor --fix --permission-file 指定其路径"))
			}
			if _, err := config.RepairInstallationPermissions(path, target, namedTarget); err != nil {
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
