package config

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
)

// WritePrivateFile publishes a complete private companion in its target directory.
// A concurrently created destination wins a first publication.
func WritePrivateFile(path string, raw []byte) (result error) {
	if path == "" {
		return errors.New("文件路径不能为空")
	}
	checkTarget := func() (bool, error) {
		err := CheckPrivatePermissions(path)
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return err == nil, err
	}
	existing, err := checkTarget()
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	file, err := CreatePrivateTemp(dir, ".mimi-private-")
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, file.Close()) }()
	defer func() {
		if checkPrivateFileName(file) == nil {
			_ = os.Remove(file.Name())
		}
	}()
	if _, err := file.Write(raw); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := verifyPrivateFile(file); err != nil {
		return err
	}
	if err := checkPrivateFileName(file); err != nil {
		return err
	}
	if existing {
		present, err := checkTarget()
		if err != nil {
			return err
		}
		if !present {
			return errors.New("目标文件已更改")
		}
		if err := os.Rename(file.Name(), path); err != nil {
			return err
		}
	} else {
		if err := os.Link(file.Name(), path); err != nil {
			return err
		}
		if err := os.Remove(file.Name()); err != nil {
			return err
		}
	}
	return syncPrivateDirectory(dir)
}

func syncPrivateDirectory(dir string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	file, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}
