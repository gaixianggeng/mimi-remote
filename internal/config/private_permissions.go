package config

import (
	"errors"
	"os"
	"runtime"
)

// StagePermissions identifies the original policy and the stricter Windows
// trustee set required for token files.
type StagePermissions struct {
	Source string
	Token  bool
}

// FileIdentity reads metadata from an open handle. Windows path-based Stat
// can defer the file ID lookup until SameFile, after a rename or replacement.
func FileIdentity(path string) (os.FileInfo, error) {
	file, err := openSnapshotFile(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return file.Stat()
}

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
	return repairPrivatePermissions(path, checkPreflightFileAccess)
}

func RepairPrivateTokenPermissions(path string) (bool, error) {
	return repairPrivatePermissions(path, checkTokenFileAccess)
}

func repairPrivatePermissions(path string, check func(*os.File, os.FileInfo) error) (bool, error) {
	file, info, err := openPermissionTarget(path, true)
	if err != nil {
		return false, err
	}
	defer file.Close()
	err = check(file, info)
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
	if err = check(file, info); err != nil {
		return false, err
	}
	return true, nil
}

// CopyPrivatePermissions verifies the creation-time policy on Windows.
// Unix applies the source mode and extended ACL before publication.
func CopyPrivatePermissions(source, stage string) error {
	original, info, err := openPermissionTarget(source, false)
	if err != nil {
		return err
	}
	defer original.Close()
	if err := checkPreflightFileAccess(original, info); err != nil {
		return err
	}
	target, stageInfo, err := openPermissionTarget(stage, runtime.GOOS != "windows")
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
