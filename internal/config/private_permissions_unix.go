//go:build !windows

package config

import "os"

func openPermissionWriter(path string) (*os.File, error) { return openSnapshotFile(path) }

func MakeFilePrivate(file *os.File) error {
	if err := repairExtendedACL(file); err != nil {
		return err
	}
	return file.Chmod(0600)
}

func CreatePrivateTemp(dir, prefix string) (*os.File, error) {
	file, err := os.CreateTemp(dir, prefix)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err == nil {
		err = checkPreflightFileAccess(file, info)
	}
	if err != nil {
		file.Close()
		os.Remove(file.Name())
		return nil, err
	}
	return file, nil
}

func CreatePrivateStage(dir, prefix string, _ StagePermissions) (*os.File, error) {
	file, err := CreatePrivateTemp(dir, prefix)
	if err != nil {
		return nil, err
	}
	if err := MakeFilePrivate(file); err != nil {
		file.Close()
		os.Remove(file.Name())
		return nil, err
	}
	return file, nil
}

func copyFileAccess(original, target *os.File, info os.FileInfo) error {
	if err := target.Chmod(info.Mode().Perm()); err != nil {
		return err
	}
	return copyExtendedACL(original, target)
}
