package setup

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type setupFileTransactionOps struct {
	stage   func(dir string, pattern string, raw []byte) (string, error)
	rename  func(oldPath string, newPath string) error
	link    func(oldPath string, newPath string) error
	remove  func(path string) error
	syncDir func(dir string) error
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

func writeSetupFilesAtomically(configPath string, tokenPath string, configRaw []byte, tokenRaw []byte, ops setupFileTransactionOps) error {
	configPath = filepath.Clean(configPath)
	tokenPath = filepath.Clean(tokenPath)
	if configPath == tokenPath {
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

	// 恢复点使用同目录 hard link，既不改动旧 inode，也能完整保留旧内容、mode、owner 与扩展属性。
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

	// 两个新文件都已经 0600 + fsync 后才进入提交阶段。先换 token，再换引用它的 config；
	// config rename 失败时立即把 token 恢复到旧 inode，避免运行中的服务看到单独轮换的新凭证。
	if err := ops.rename(stagedToken, tokenPath); err != nil {
		return fmt.Errorf("提交 app-server token file 失败：%w", err)
	}
	if err := ops.rename(stagedConfig, configPath); err != nil {
		rollbackErr := restoreSetupTarget(tokenPath, tokenBackup, tokenExisted, ops)
		syncErr := ops.syncDir(dir)
		return fmt.Errorf("提交配置文件失败：%w", errors.Join(err, rollbackErr, syncErr))
	}

	if err := ops.syncDir(dir); err != nil {
		// 目录 fsync 也是提交的一部分；失败时按相反语义恢复两份旧文件。首次安装则删除刚提交的文件。
		rollbackErr := errors.Join(
			restoreSetupTarget(tokenPath, tokenBackup, tokenExisted, ops),
			restoreSetupTarget(configPath, configBackup, configExisted, ops),
		)
		rollbackSyncErr := ops.syncDir(dir)
		return fmt.Errorf("同步配置目录失败：%w", errors.Join(err, rollbackErr, rollbackSyncErr))
	}

	return nil
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
	file, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}
