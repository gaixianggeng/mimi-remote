//go:build !windows && !linux && !darwin

package config

import (
	"errors"
	"os"
)

var errACLUnsupported = errors.New("此平台无法验证文件 ACL")

func checkExtendedACL(*os.File) error                          { return errACLUnsupported }
func repairExtendedACL(*os.File) error                         { return errACLUnsupported }
func openPermissionFile(path string, _ bool) (*os.File, error) { return openSnapshotFile(path) }
func setPrivateMode(file *os.File) error                       { return file.Chmod(0600) }

func createPrivateNew(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
}

func prepareNewPrivateFile(file *os.File) error { return MakeFilePrivate(file) }
