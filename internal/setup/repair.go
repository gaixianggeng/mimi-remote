package setup

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type configWriter func(path string, raw []byte) error
type renameFile func(oldPath string, newPath string) error

type privateFileStageOps struct {
	write func(file *os.File, raw []byte) (int, error)
	sync  func(file *os.File) error
}

func writePrivateFileAtomically(path string, raw []byte) error {
	return writePrivateFileAtomicallyWithRename(path, raw, renameSetupFile)
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
			return saveFailure("config_concurrent_change", fmt.Errorf("配置已被其他进程修改，请重新执行"))
		}
		return writePrivateFileAtomically(path, raw)
	})
}

func writePrivateFileAtomicallyWithRename(path string, raw []byte, rename renameFile) error {
	dir := filepath.Dir(path)
	source := ""
	if _, err := os.Lstat(path); err == nil {
		source = path
	} else if !os.IsNotExist(err) {
		return err
	}
	var permissions config.ReplacementPermissions
	tempPath, err := stagePrivateFile(dir, ".config.json.tmp-", raw, config.StagePermissions{Source: source, Snapshot: &permissions})
	if err != nil {
		return err
	}
	if source == "" {
		err = renameNewSetupFile(tempPath, path)
	} else {
		if runtime.GOOS != "windows" {
			err = copyAndSyncPermissions(source, tempPath)
		}
		if err == nil {
			err = permissions.Replace(tempPath, path, "", rename)
		}
	}
	var conflict *config.PermissionConflict
	if errors.As(err, &conflict) {
		return replaceConflict(err, tempPath, path)
	}
	if err != nil {
		_ = os.Remove(tempPath)
		return err
	}

	// rename 已经是配置的提交点；目录 fsync 只做尽力而为，避免提交成功后因平台差异反报失败。
	if dirFile, openErr := os.Open(dir); openErr == nil {
		_ = dirFile.Sync()
		_ = dirFile.Close()
	}
	return nil
}

func stagePrivateFile(dir string, pattern string, raw []byte, permissions config.StagePermissions) (string, error) {
	return stagePrivateFileWithOps(dir, pattern, raw, permissions, privateFileStageOps{
		write: func(file *os.File, raw []byte) (int, error) {
			return file.Write(raw)
		},
		sync: func(file *os.File) error {
			return file.Sync()
		},
	})
}

func stagePrivateFileWithOps(dir string, pattern string, raw []byte, permissions config.StagePermissions, ops privateFileStageOps) (string, error) {
	file, err := config.CreatePrivateStage(dir, pattern, permissions)
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

// Non-journaled writers retain the private stage on a pre-rename conflict
// and identify the published file when the caller must reread or recover.
func replaceConflict(err error, stage, path string) error {
	var conflict *config.PermissionConflict
	if !errors.As(err, &conflict) {
		return err
	}
	if conflict.Published {
		stage = path
	}
	if conflict.Recovery {
		return recoveryError(stage, err)
	}
	return &SaveError{Code: "config_concurrent_change", Step: "config_store", Cause: err,
		RecoveryPath: "<配置目录>/" + filepath.Base(stage)}
}
