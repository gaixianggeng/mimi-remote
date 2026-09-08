package setup

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type setupFileTransactionOps struct {
	stage   func(dir string, pattern string, raw []byte) (string, error)
	rename  func(oldPath string, newPath string) error
	link    func(oldPath string, newPath string) error
	remove  func(path string) error
	syncDir func(dir string) error
}

func writeSetupFilesAtomically(
	configPath string,
	tokenPath string,
	configRaw []byte,
	tokenRaw []byte,
	ops setupFileTransactionOps,
) error {
	configPath = filepath.Clean(configPath)
	tokenPath = filepath.Clean(tokenPath)
	if configPath == tokenPath || (runtime.GOOS == "windows" && strings.EqualFold(configPath, tokenPath)) {
		return fmt.Errorf("配置文件与 app-server token file 不能使用同一路径")
	}
	configExisted, err := regularFileOrMissing(configPath, "配置文件")
	if err != nil {
		return err
	}
	tokenExisted, err := regularFileOrMissing(tokenPath, "app-server token file")
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

	tokenBackup, err := hardLinkBackup(tokenPath, tokenExisted, ops)
	if err != nil {
		return fmt.Errorf("创建 app-server token file 恢复点失败：%w", err)
	}
	if tokenBackup != "" {
		defer ops.remove(tokenBackup)
	}
	configBackup, err := hardLinkBackup(configPath, configExisted, ops)
	if err != nil {
		return fmt.Errorf("创建配置文件恢复点失败：%w", err)
	}
	if configBackup != "" {
		defer ops.remove(configBackup)
	}

	// 先提交上游 token，再提交引用它的配置。第二步失败时恢复旧 token，
	// 防止运行中的服务看到未配套提交的新凭证。
	if err := ops.rename(stagedToken, tokenPath); err != nil {
		return fmt.Errorf("提交 app-server token file 失败：%w", err)
	}
	if err := ops.rename(stagedConfig, configPath); err != nil {
		rollbackErr := restoreSetupTarget(tokenPath, tokenBackup, tokenExisted, ops)
		syncErr := ops.syncDir(dir)
		return fmt.Errorf("提交配置文件失败：%w", errors.Join(err, rollbackErr, syncErr))
	}
	if err := ops.syncDir(dir); err != nil {
		rollbackErr := errors.Join(
			restoreSetupTarget(tokenPath, tokenBackup, tokenExisted, ops),
			restoreSetupTarget(configPath, configBackup, configExisted, ops),
		)
		rollbackSyncErr := ops.syncDir(dir)
		return fmt.Errorf("同步配置目录失败：%w", errors.Join(err, rollbackErr, rollbackSyncErr))
	}
	return nil
}

// writeConfigAtomically 只提交 SSH 配置文件，不创建、轮换或删除旧 app-server token file。
func writeConfigAtomically(configPath string, configRaw []byte, ops setupFileTransactionOps) error {
	configPath = filepath.Clean(configPath)
	configExisted, err := regularFileOrMissing(configPath, "配置文件")
	if err != nil {
		return err
	}
	dir := filepath.Dir(configPath)
	stagedConfig, err := ops.stage(dir, ".config.json.tmp-", configRaw)
	if err != nil {
		return fmt.Errorf("暂存配置文件失败：%w", err)
	}
	defer ops.remove(stagedConfig)
	configBackup, err := hardLinkBackup(configPath, configExisted, ops)
	if err != nil {
		return fmt.Errorf("创建配置文件恢复点失败：%w", err)
	}
	if configBackup != "" {
		defer ops.remove(configBackup)
	}
	if err := ops.rename(stagedConfig, configPath); err != nil {
		return fmt.Errorf("提交配置文件失败：%w", err)
	}
	if err := ops.syncDir(dir); err != nil {
		rollbackErr := restoreSetupTarget(configPath, configBackup, configExisted, ops)
		rollbackSyncErr := ops.syncDir(dir)
		return fmt.Errorf("同步配置目录失败：%w", errors.Join(err, rollbackErr, rollbackSyncErr))
	}
	return nil
}

func defaultSetupFileTransactionOps() setupFileTransactionOps {
	return setupFileTransactionOps{
		stage:   stagePrivateFile,
		rename:  os.Rename,
		link:    os.Link,
		remove:  os.Remove,
		syncDir: syncDirectory,
	}
}

func regularFileOrMissing(path string, label string) (bool, error) {
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("读取%s状态失败：%w", label, err)
	}
	if !info.Mode().IsRegular() {
		return false, fmt.Errorf("%s必须是 regular file，不能是目录或符号链接：%s", label, path)
	}
	return true, nil
}

func hardLinkBackup(path string, existed bool, ops setupFileTransactionOps) (string, error) {
	if !existed {
		return "", nil
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
		return backup, nil
	}
	return "", fmt.Errorf("无法分配恢复点文件名")
}

func restoreSetupTarget(path string, backup string, existed bool, ops setupFileTransactionOps) error {
	if existed {
		if backup == "" {
			return fmt.Errorf("%s 缺少恢复点", path)
		}
		if err := ops.rename(backup, path); err != nil {
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
