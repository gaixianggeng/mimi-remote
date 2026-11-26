package setup

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type configWriter func(path string, raw []byte) error

type privateFileStageOps struct {
	write func(file *os.File, raw []byte) (int, error)
	sync  func(file *os.File) error
}

// Read the owned config and check any existing referenced credentials before
// initiating a write, including a no-op save or a legacy transport migration.
func readPrivateConfig(path string) ([]byte, error) {
	if _, err := config.CheckCompanionPermissions(path); err != nil {
		return nil, saveFailure(config.PrivateFileDiagnostic(err), err)
	}
	raw, err := config.ReadPrivatePreflightFile(path, 4<<20)
	if err == nil {
		_, err = config.CheckCredentialPermissions(raw)
	}
	if err != nil && config.PrivateFileDiagnostic(err) == "config_permissions_unsafe" {
		return nil, saveFailure("config_permissions_unsafe", err)
	}
	return raw, err
}

func writePrivateFileAtomicallyCAS(path string, expected []byte, raw []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return withConfigCommitLock(ctx, path, func() error {
		return writePrivateFileAtomically(path, expected, raw)
	})
}

func writePrivateFileAtomically(path string, expected, raw []byte) error {
	checkOriginal := func() error {
		current, err := readPrivateConfig(path)
		if err != nil {
			return err
		}
		if !bytes.Equal(current, expected) {
			return saveFailure("config_concurrent_change", errors.New("配置已被其他进程修改，请重新执行"))
		}
		return nil
	}
	if err := checkOriginal(); err != nil {
		return err
	}
	dir := filepath.Dir(path)
	tempPath, err := stagePrivateFile(dir, ".config.json.tmp-", raw)
	if err != nil {
		return err
	}
	defer os.Remove(tempPath)
	if err := checkOriginal(); err != nil {
		return err
	}
	if err := renamePrivateFile(tempPath, path, renameSetupFile); err != nil {
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
	file, err := config.CreatePrivateTemp(dir, pattern)
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
