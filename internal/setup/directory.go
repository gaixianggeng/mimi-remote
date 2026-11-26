package setup

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// A directory fsync persists its contents. Each new directory also needs an
// fsync of its parent before a successful receipt can rely on the whole path.
func ensureSetupDirectory(path string, syncDir func(string) error) (os.FileInfo, error) {
	if info, err := os.Stat(path); err == nil {
		if !info.IsDir() {
			return nil, errors.New("路径不是目录")
		}
		return nil, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	parent := filepath.Dir(path)
	if parent == path {
		return nil, os.ErrNotExist
	}
	if _, err := ensureSetupDirectory(parent, syncDir); err != nil {
		return nil, err
	}
	err := os.Mkdir(path, 0700)
	created := err == nil
	if !created && !errors.Is(err, os.ErrExist) {
		return nil, err
	}
	info, err := config.FileIdentity(path)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, errors.New("路径不是目录")
	}
	if err := syncDir(parent); err != nil {
		if created {
			removeCreatedDirectory(path, info)
		}
		return nil, err
	}
	if created {
		return info, nil
	}
	return nil, nil
}

func removeCreatedDirectory(path string, created os.FileInfo) {
	if now, err := os.Lstat(path); err == nil && os.SameFile(created, now) {
		_ = os.Remove(path)
	}
}
