//go:build !windows

package config

import (
	"errors"
	"os"
)

func regularReplacementInfo(path string) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err == nil && !info.Mode().IsRegular() {
		err = errors.New("配置或凭据必须是普通文件")
	}
	return info, err
}

// Replace checks the staged mode and takes the last destination sample just
// before rename. Rollback links have no creation snapshot.
func (p ReplacementPermissions) Replace(stage, destination, _ string, move func(string, string) error) error {
	if err := p.CheckStageSource(stage, destination); err != nil {
		return err
	}
	return move(stage, destination)
}

// CheckStageSource also covers a legacy source published to a new name.
func (p ReplacementPermissions) CheckStageSource(stage, source string) error {
	staged, err := regularReplacementInfo(stage)
	if err != nil {
		return err
	}
	before, err := regularReplacementInfo(source)
	if err != nil {
		return &PermissionConflict{Cause: err}
	}
	if p.info != nil && (!os.SameFile(before, p.info) || before.Mode().Perm() != p.info.Mode().Perm()) ||
		staged.Mode().Perm()&^before.Mode().Perm() != 0 {
		return &PermissionConflict{Cause: errPermissionsChanged}
	}
	return nil
}
