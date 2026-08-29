package setup

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

type configWriter func(path string, raw []byte) error
type renameFile func(oldPath string, newPath string) error

type privateFileStageOps struct {
	write func(file *os.File, raw []byte) (int, error)
	sync  func(file *os.File) error
}

func writePrivateFileAtomically(path string, raw []byte) error {
	return writePrivateFileAtomicallyWithRename(path, raw, os.Rename)
}

func writePrivateFileAtomicallyCAS(path string, expected []byte, raw []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return withConfigCommitLock(ctx, path, func() error {
		current, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("重新读取配置失败：%w", err)
		}
		if !bytes.Equal(current, expected) {
			return fmt.Errorf("配置已被其他进程修改，请重新执行")
		}
		return writePrivateFileAtomically(path, raw)
	})
}

func writePrivateFileAtomicallyWithRename(path string, raw []byte, rename renameFile) error {
	dir := filepath.Dir(path)
	tempPath, err := stagePrivateFile(dir, ".config.json.tmp-", raw)
	if err != nil {
		return err
	}
	defer os.Remove(tempPath)
	if err := rename(tempPath, path); err != nil {
		return err
	}

	// rename 已经是配置的提交点；目录 fsync 只做尽力而为，避免提交成功后因平台差异反报失败。
	if dirFile, openErr := os.Open(dir); openErr == nil {
		_ = dirFile.Sync()
		_ = dirFile.Close()
	}
	return nil
}

func stagePrivateFile(dir string, pattern string, raw []byte) (string, error) {
	return stagePrivateFileWithOps(dir, pattern, raw, privateFileStageOps{
		write: func(file *os.File, raw []byte) (int, error) {
			return file.Write(raw)
		},
		sync: func(file *os.File) error {
			return file.Sync()
		},
	})
}

func stagePrivateFileWithOps(dir string, pattern string, raw []byte, ops privateFileStageOps) (string, error) {
	file, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return "", err
	}
	path := file.Name()
	complete := false
	defer func() {
		_ = file.Close()
		if !complete {
			_ = os.Remove(path)
		}
	}()

	if err := makePrivateFile(file); err != nil {
		return "", err
	}
	written, err := ops.write(file, raw)
	if err != nil {
		return "", err
	}
	if written != len(raw) {
		return "", io.ErrShortWrite
	}
	if err := ops.sync(file); err != nil {
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	complete = true
	return path, nil
}
