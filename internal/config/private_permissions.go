package config

import (
	"errors"
	"os"
)

func openPermissionTarget(path string, modify bool) (*os.File, os.FileInfo, error) {
	expected, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !expected.Mode().IsRegular() {
		return nil, nil, errors.New("配置或凭据必须是普通文件")
	}
	var file *os.File
	if modify {
		file, err = openPermissionWriter(path)
	} else {
		file, err = openSnapshotFile(path)
	}
	if err != nil {
		return nil, nil, err
	}
	info, err := file.Stat()
	if err == nil && info.Mode().IsRegular() && os.SameFile(info, expected) {
		return file, info, nil
	}
	file.Close()
	if err == nil {
		err = errors.New("文件已被替换")
	}
	return nil, nil, err
}

// RepairPrivatePermissions tightens access in place only after identifying an
// owned regular file. The ownership check and repair use the same open handle.
func RepairPrivatePermissions(path string) (bool, error) {
	file, info, err := openPermissionTarget(path, true)
	if err != nil {
		return false, err
	}
	defer file.Close()
	err = checkPreflightFileAccess(file, info)
	if !errors.Is(err, errPreflightFileNotPrivate) {
		return false, err
	}
	if err = MakeFilePrivate(file); err != nil {
		return false, err
	}
	info, err = file.Stat()
	if err != nil {
		return false, err
	}
	if err = checkPreflightFileAccess(file, info); err != nil {
		return false, err
	}
	return true, nil
}

// CopyPrivatePermissions applies a validated original access policy to a private staging file.
func CopyPrivatePermissions(source, stage string) error {
	original, info, err := openPermissionTarget(source, false)
	if err != nil {
		return err
	}
	defer original.Close()
	if err := checkPreflightFileAccess(original, info); err != nil {
		return err
	}
	target, stageInfo, err := openPermissionTarget(stage, true)
	if err != nil {
		return err
	}
	defer target.Close()
	if err := checkPreflightFileAccess(target, stageInfo); err != nil {
		return err
	}
	if err := copyFileAccess(original, target, info); err != nil {
		return err
	}
	stageInfo, err = target.Stat()
	if err != nil {
		return err
	}
	return checkPreflightFileAccess(target, stageInfo)
}
