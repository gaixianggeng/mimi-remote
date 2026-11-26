//go:build !windows

package config

import "os"

func setPrivateAccess(file *os.File) error {
	if err := setPrivateMode(file); err != nil {
		return err
	}
	return repairExtendedACL(file)
}

func permissionIdentity(path string) (os.FileInfo, error) { return os.Lstat(path) }
