package config

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

const legacyAppName = "codex-ipad-agent"

type stagedLegacyConfig struct {
	path string
	info os.FileInfo
}

type legacyMigrationFileOps struct {
	lstat       func(string) (os.FileInfo, error)
	readRegular func(string, os.FileInfo) ([]byte, error)
	stage       func(string, string, []byte) (stagedLegacyConfig, error)
	link        func(string, string) error
	remove      func(string) error
	syncDir     func(string) error
}

func defaultLegacyMigrationFileOps() legacyMigrationFileOps {
	return legacyMigrationFileOps{
		lstat:       os.Lstat,
		readRegular: readUnchangedRegularFile,
		stage:       stageLegacyConfig,
		link:        os.Link,
		remove:      os.Remove,
		syncDir:     syncLegacyMigrationDirectory,
	}
}

// LegacyDefaultPath 返回历史版本使用的默认配置路径，仅用于一次性兼容迁移。
func LegacyDefaultPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return filepath.Join(legacyAppName, "config.json")
	}
	return filepath.Join(dir, legacyAppName, "config.json")
}

// MigrateLegacyDefaultConfig 在 CLI 没有显式选择配置时，把历史默认 config.json 原样复制到新版默认目录。
// 迁移只复制配置本身并保留旧文件；配置中的 token、未知字段及绝对路径不会被解析或改写。
func MigrateLegacyDefaultConfig(requestedPath string, explicitlyConfigured bool) (bool, error) {
	if explicitlyConfigured || strings.TrimSpace(os.Getenv("AGENTD_CONFIG")) != "" {
		return false, nil
	}
	requested, err := absoluteExpandedPath(requestedPath)
	if err != nil {
		return false, fmt.Errorf("解析请求配置路径失败：%w", err)
	}
	platformDefault, err := absoluteExpandedPath(PlatformDefaultPath())
	if err != nil {
		return false, fmt.Errorf("解析平台默认配置路径失败：%w", err)
	}
	if requested != platformDefault {
		return false, nil
	}
	legacyPath, err := absoluteExpandedPath(LegacyDefaultPath())
	if err != nil {
		return false, fmt.Errorf("解析旧版配置路径失败：%w", err)
	}
	return migrateLegacyDefaultConfig(requested, legacyPath, defaultLegacyMigrationFileOps())
}

func migrateLegacyDefaultConfig(destination string, source string, ops legacyMigrationFileOps) (bool, error) {
	if _, err := ops.lstat(destination); err == nil {
		// 新路径上的任何现有对象都优先，迁移逻辑不负责修复或覆盖它。
		return false, nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return false, fmt.Errorf("读取新版配置状态失败：%w", err)
	}

	sourceInfo, err := ops.lstat(source)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return false, nil
		}
		return false, fmt.Errorf("读取旧版配置状态失败：%w", err)
	}
	if !sourceInfo.Mode().IsRegular() {
		return false, fmt.Errorf("旧版配置必须是普通文件，不能是目录或符号链接：%s", source)
	}
	raw, err := ops.readRegular(source, sourceInfo)
	if err != nil {
		return false, fmt.Errorf("读取旧版配置失败：%w", err)
	}

	destinationDir := filepath.Dir(destination)
	createdDirs, err := ensureLegacyMigrationDirectory(destinationDir)
	if err != nil {
		return false, fmt.Errorf("创建新版配置目录失败：%w", err)
	}
	committed := false
	defer func() {
		if !committed {
			removeEmptyMigrationDirectories(createdDirs)
		}
	}()

	staged, err := ops.stage(destinationDir, ".config.json.migrate-", raw)
	if staged.path != "" {
		defer ops.remove(staged.path)
	}
	if err != nil {
		return false, fmt.Errorf("暂存旧版配置副本失败：%w", err)
	}
	if staged.path == "" || staged.info == nil {
		return false, fmt.Errorf("暂存旧版配置副本失败：缺少完整暂存文件")
	}

	// hard link 是这里的 no-clobber 提交点：目标并发出现时返回 EEXIST，不会像 rename 一样覆盖新文件。
	if err := ops.link(staged.path, destination); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return false, nil
		}
		return false, fmt.Errorf("提交新版配置失败：%w", err)
	}
	rollback := func(commitErr error) (bool, error) {
		rollbackErr := removeMigrationDestinationIfOwned(destination, staged.info, ops)
		_ = ops.syncDir(destinationDir)
		return false, fmt.Errorf("同步新版配置失败：%w", errors.Join(commitErr, rollbackErr))
	}
	if err := ops.syncDir(destinationDir); err != nil {
		return rollback(err)
	}
	if err := ops.remove(staged.path); err != nil {
		return rollback(fmt.Errorf("清理迁移暂存文件失败：%w", err))
	}
	staged.path = ""
	if err := ops.syncDir(destinationDir); err != nil {
		return rollback(err)
	}
	committed = true
	return true, nil
}

func readUnchangedRegularFile(path string, expected os.FileInfo) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !opened.Mode().IsRegular() || !os.SameFile(expected, opened) {
		return nil, fmt.Errorf("旧版配置在读取前发生变化，拒绝继续迁移")
	}
	return io.ReadAll(file)
}

func stageLegacyConfig(dir string, pattern string, raw []byte) (result stagedLegacyConfig, resultErr error) {
	file, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return result, err
	}
	result.path = file.Name()
	defer func() {
		if resultErr != nil {
			_ = file.Close()
			_ = os.Remove(result.path)
		}
	}()
	if err := file.Chmod(0o600); err != nil {
		return result, err
	}
	if _, err := io.Copy(file, bytes.NewReader(raw)); err != nil {
		return result, err
	}
	if err := file.Sync(); err != nil {
		return result, err
	}
	info, err := file.Stat()
	if err != nil {
		return result, err
	}
	if err := file.Close(); err != nil {
		return result, err
	}
	result.info = info
	return result, nil
}

func ensureLegacyMigrationDirectory(dir string) ([]string, error) {
	missing := []string{}
	current := filepath.Clean(dir)
	for {
		info, err := os.Stat(current)
		if err == nil {
			if !info.IsDir() {
				return nil, fmt.Errorf("路径不是目录：%s", current)
			}
			break
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
		missing = append(missing, current)
		parent := filepath.Dir(current)
		if parent == current {
			return nil, fmt.Errorf("找不到可用的上级目录：%s", dir)
		}
		current = parent
	}

	created := make([]string, 0, len(missing))
	for index := len(missing) - 1; index >= 0; index-- {
		path := missing[index]
		if err := os.Mkdir(path, 0o700); err != nil {
			if errors.Is(err, fs.ErrExist) {
				info, statErr := os.Stat(path)
				if statErr == nil && info.IsDir() {
					continue
				}
			}
			removeEmptyMigrationDirectories(created)
			return nil, err
		}
		created = append(created, path)
	}
	return created, nil
}

func removeEmptyMigrationDirectories(created []string) {
	for index := len(created) - 1; index >= 0; index-- {
		// Remove 只会删除空目录；并发进程写入内容后会安全失败。
		_ = os.Remove(created[index])
	}
}

func removeMigrationDestinationIfOwned(path string, staged os.FileInfo, ops legacyMigrationFileOps) error {
	current, err := ops.lstat(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	if staged == nil || !os.SameFile(staged, current) {
		return nil
	}
	if err := ops.remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

func syncLegacyMigrationDirectory(dir string) error {
	file, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}

func absoluteExpandedPath(path string) (string, error) {
	value := strings.TrimSpace(expandPath(path))
	if value == "" {
		return "", fmt.Errorf("配置路径不能为空")
	}
	abs, err := filepath.Abs(value)
	if err != nil {
		return "", err
	}
	return filepath.Clean(abs), nil
}
