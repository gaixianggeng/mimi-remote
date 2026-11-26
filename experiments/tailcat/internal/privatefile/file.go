// Package privatefile reads and publishes Tailcat credentials using the same
// on-disk permissions as agentd's internal/config, across the module boundary.
package privatefile

import (
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
)

var errNotPrivate = errors.New("文件权限不符合私有凭据要求")

func verify(file *os.File) error {
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("凭据路径必须是普通文件")
	}
	return checkAccess(file, info)
}

func openVerified(path string) (*os.File, error) {
	expected, err := identity(path)
	if err != nil {
		return nil, err
	}
	if !expected.Mode().IsRegular() {
		return nil, errors.New("凭据路径必须是普通文件")
	}
	file, err := openNoFollow(path)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err == nil && !os.SameFile(expected, info) {
		err = errors.New("凭据文件已被替换")
	}
	if err == nil {
		err = checkAccess(file, info)
	}
	if err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

// Check validates the file without reading credential bytes or changing its permissions.
func Check(path string) error {
	file, err := openVerified(path)
	if err != nil {
		return err
	}
	return file.Close()
}

// Read checks permissions on the handle used to read the credential.
func Read(path string) ([]byte, error) {
	file, err := openVerified(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	const limit = 4 << 20
	raw, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > limit {
		return nil, errors.New("凭据文件过大")
	}
	return raw, nil
}

func checkStageName(file *os.File) error {
	opened, err := file.Stat()
	if err != nil {
		return err
	}
	named, err := identity(file.Name())
	if err != nil {
		return err
	}
	if !opened.Mode().IsRegular() || !os.SameFile(opened, named) {
		return errors.New("暂存文件已被替换")
	}
	return nil
}

// Write stages the complete file alongside its destination. A concurrent creator
// wins first publication. Existing credentials must already be private.
func Write(path string, raw []byte) (result error) {
	if path == "" {
		return errors.New("文件路径不能为空")
	}
	err := Check(path)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	var file *os.File
	for {
		file, err = createPrivateNew(filepath.Join(dir, ".mimi-private-"+rand.Text()))
		if !errors.Is(err, os.ErrExist) {
			break
		}
	}
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, file.Close()) }()
	defer func() {
		if checkStageName(file) == nil {
			_ = os.Remove(file.Name())
		}
	}()
	if err := prepareStage(file); err != nil {
		return err
	}
	if err := verify(file); err != nil {
		return err
	}
	if err := checkStageName(file); err != nil {
		return err
	}
	if _, err := file.Write(raw); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := verify(file); err != nil {
		return err
	}
	if err := checkStageName(file); err != nil {
		return err
	}
	if exists {
		if err := Check(path); err != nil {
			return err
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
	if runtime.GOOS == "windows" {
		return nil
	}
	parent, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer parent.Close()
	return parent.Sync()
}
