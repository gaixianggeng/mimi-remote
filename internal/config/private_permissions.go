package config

import (
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

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
	expected, err := permissionIdentity(path)
	if err != nil {
		return nil, nil, err
	}
	if !expected.Mode().IsRegular() {
		return nil, nil, errors.New("配置或凭据必须是普通文件")
	}
	file, err := openPermissionFile(path, modify)
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

// RepairPrivatePermissions restores canonical permissions in place on an identified, owned regular file.
func RepairPrivatePermissions(path string) (bool, error) {
	file, _, err := openPermissionTarget(path, true)
	if err != nil {
		return repairInaccessibleFile(path, err)
	}
	defer file.Close()
	return makeFilePrivate(file)
}

// CheckPrivatePermissions validates an existing file without reading its contents.
func CheckPrivatePermissions(path string) error {
	file, info, err := openPermissionTarget(path, false)
	if errors.Is(err, os.ErrPermission) {
		return errPreflightFileNotPrivate
	}
	if err != nil {
		return err
	}
	defer file.Close()
	return checkPreflightFileAccess(file, info)
}

func verifyPrivateFile(file *os.File) error {
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("凭据路径必须是普通文件")
	}
	return checkPreflightFileAccess(file, info)
}

// MakeFilePrivate applies canonical permissions and verifies the result on the same handle.
func MakeFilePrivate(file *os.File) error {
	_, err := makeFilePrivate(file)
	return err
}

func makeFilePrivate(file *os.File) (bool, error) {
	err := verifyPrivateFile(file)
	if err != errPreflightFileNotPrivate {
		return false, err
	}
	if err := setPrivateAccess(file); err != nil {
		return false, err
	}
	if err := verifyPrivateFile(file); err != nil {
		return false, err
	}
	return true, nil
}

// CreatePrivateTemp returns an empty file verified on the handle used for secret writes.
func CreatePrivateTemp(dir, prefix string) (*os.File, error) {
	if filepath.Base(prefix) != prefix && prefix != "" {
		return nil, errors.New("暂存文件前缀无效")
	}
	if dir == "" {
		dir = os.TempDir()
	}
	before, after := prefix, ""
	if pos := strings.LastIndexByte(prefix, '*'); pos >= 0 {
		before, after = prefix[:pos], prefix[pos+1:]
	}
	for {
		path := filepath.Join(dir, before+rand.Text()+after)
		file, err := createPrivateNew(path)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if err := prepareNewPrivateFile(file); err != nil {
			file.Close()
			os.Remove(path)
			return nil, err
		}
		return file, nil
	}
}
