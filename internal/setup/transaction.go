package setup

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type setupFileTransactionOps struct {
	stage     func(dir string, pattern string, raw []byte) (string, error)
	rename    func(oldPath string, newPath string) error
	renameNew func(oldPath, newPath string) error
	link      func(oldPath string, newPath string) error
	remove    func(path string) error
	syncDir   func(dir string) error
}

func writeSetupFilesAtomically(
	beforeConfig configImage,
	tokenPath string,
	configRaw []byte,
	tokenRaw []byte,
	ops setupFileTransactionOps,
) error {
	configPath := filepath.Clean(beforeConfig.path)
	tokenPath = filepath.Clean(tokenPath)
	if configPath == tokenPath || (runtime.GOOS == "windows" && strings.EqualFold(configPath, tokenPath)) {
		return fmt.Errorf("配置文件与 app-server token file 不能使用同一路径")
	}
	if err := beforeConfig.check(); err != nil {
		return err
	}
	beforeToken, err := readImage(tokenPath)
	if err != nil {
		return err
	}
	dir := filepath.Dir(configPath)
	if filepath.Dir(tokenPath) != dir {
		return fmt.Errorf("app-server token file 必须与配置文件位于同一目录")
	}

	stagedToken, err := ops.stage(dir, ".app-server-ws-token.tmp-", tokenRaw)
	if err != nil {
		return fmt.Errorf("暂存 app-server token file 失败：%w", err)
	}
	defer ops.remove(stagedToken)
	stagedConfig, err := ops.stage(dir, ".config.json.tmp-", configRaw)
	if err != nil {
		return fmt.Errorf("暂存配置文件失败：%w", err)
	}
	defer ops.remove(stagedConfig)

	tokenInfo, err := config.FileIdentity(stagedToken)
	if err != nil {
		return err
	}
	configInfo, err := config.FileIdentity(stagedConfig)
	if err != nil {
		return err
	}
	keepBackups := false
	tokenBackup, err := hardLinkBackup(tokenPath, beforeToken.exists, ops)
	if err != nil {
		return fmt.Errorf("创建 app-server token file 恢复点失败：%w", err)
	}
	if tokenBackup != "" {
		defer func() {
			if !keepBackups {
				_ = ops.remove(tokenBackup)
			}
		}()
	}
	configBackup, err := hardLinkBackup(configPath, beforeConfig.exists, ops)
	if err != nil {
		return fmt.Errorf("创建配置文件恢复点失败：%w", err)
	}
	if configBackup != "" {
		defer func() {
			if !keepBackups {
				_ = ops.remove(configBackup)
			}
		}()
	}

	// 先提交上游 token，再提交引用它的配置。第二步失败时恢复旧 token，
	// 防止运行中的服务看到未配套提交的新凭证。
	publish := func(stage string, id os.FileInfo, raw []byte, before configImage) error {
		if !sameSetupFile(stage, id, raw) {
			return saveFailure("config_concurrent_change", errors.New("暂存文件已更改"))
		}
		if err := before.check(); err != nil {
			return err
		}
		if !before.exists {
			return ops.renameNew(stage, before.path)
		}
		return ops.rename(stage, before.path)
	}
	if err := publish(stagedToken, tokenInfo, tokenRaw, beforeToken); err != nil {
		return fmt.Errorf("提交 app-server token file 失败：%w", err)
	}
	if err := publish(stagedConfig, configInfo, configRaw, beforeConfig); err != nil {
		rollbackErr := restoreSetupTarget(beforeToken, tokenBackup, tokenInfo, tokenRaw, ops)
		keepBackups = rollbackErr != nil
		syncErr := ops.syncDir(dir)
		return fmt.Errorf("提交配置文件失败：%w", errors.Join(err, rollbackErr, syncErr))
	}
	if err := ops.syncDir(dir); err != nil {
		rollbackErr := errors.Join(
			restoreSetupTarget(beforeToken, tokenBackup, tokenInfo, tokenRaw, ops),
			restoreSetupTarget(beforeConfig, configBackup, configInfo, configRaw, ops),
		)
		keepBackups = rollbackErr != nil
		rollbackSyncErr := ops.syncDir(dir)
		return fmt.Errorf("同步配置目录失败：%w", errors.Join(err, rollbackErr, rollbackSyncErr))
	}
	return nil
}

func defaultSetupFileTransactionOps() setupFileTransactionOps {
	return setupFileTransactionOps{
		stage:     stagePrivateFile,
		rename:    renameSetupFile,
		renameNew: renameNewSetupFile,
		link:      os.Link,
		remove:    os.Remove,
		syncDir:   syncDirectory,
	}
}

func regularFileOrMissing(path string, label string) (bool, error) {
	err := config.CheckPrivatePermissions(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, saveFailure(config.PrivateFileDiagnostic(err), fmt.Errorf("读取%s权限失败：%w", label, err))
	}
	return true, nil
}

func hardLinkBackup(path string, existed bool, ops setupFileTransactionOps) (string, error) {
	if !existed {
		return "", nil
	}
	if err := config.CheckPrivatePermissions(path); err != nil {
		return "", err
	}
	for attempt := 0; attempt < 10; attempt++ {
		suffix, err := randomHex(8)
		if err != nil {
			return "", err
		}
		backup := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".bak-"+suffix)
		if err := ops.link(path, backup); err != nil {
			if os.IsExist(err) {
				continue
			}
			return "", err
		}
		if err := config.CheckPrivatePermissions(backup); err != nil {
			_ = ops.remove(backup)
			return "", err
		}
		return backup, nil
	}
	return "", fmt.Errorf("无法分配恢复点文件名")
}

func renamePrivateFile(source, target string, rename func(string, string) error) error {
	if err := config.CheckPrivatePermissions(source); err != nil {
		return err
	}
	return rename(source, target)
}

func restoreSetupTarget(before configImage, backup string, published os.FileInfo, raw []byte, ops setupFileTransactionOps) error {
	path := before.path
	if !sameSetupFile(path, published, raw) {
		return errors.New("已发布的文件已被更改，已保留恢复点")
	}
	if before.exists {
		if backup == "" {
			return fmt.Errorf("%s 缺少恢复点", path)
		}
		prior, err := readImage(backup)
		if err != nil || !prior.exists || !bytes.Equal(prior.raw, before.raw) {
			return errors.New("恢复点的内容或权限已更改")
		}
		if err := renamePrivateFile(backup, path, ops.rename); err != nil {
			return fmt.Errorf("恢复 %s 失败：%w", path, err)
		}
		return nil
	}
	if err := ops.remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("清理新文件 %s 失败：%w", path, err)
	}
	return nil
}

func syncDirectory(dir string) error {
	if runtime.GOOS == "windows" {
		// Windows cannot open a directory as a syncable file. Rename remains the
		// atomic commit operation; file contents were already flushed before it.
		return nil
	}
	file, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}
