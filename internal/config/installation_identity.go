package config

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

const (
	installationIDFileName = "installation-id"
	installationIDFileMode = 0o600
)

// LoadOrCreateInstallationID 读取 agentd 的稳定安装身份。
//
// 身份与可变的 endpoint、Token 和配置文件分离：缺失时只创建一次；已有普通文件
// 内容合法但权限不符时只收紧为 0600，类型或格式异常仍直接失败。任何情况下都不能
// 静默生成新身份并让移动端误认成另一台 Mac。
func LoadOrCreateInstallationID() (string, error) {
	dir, err := UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("获取用户配置目录失败：%w", err)
	}
	return loadOrCreateInstallationID(filepath.Join(dir, installationIDFileName), rand.Reader)
}

func loadOrCreateInstallationID(path string, entropy io.Reader) (string, error) {
	installationID, err := readInstallationID(path)
	if err == nil {
		return installationID, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("创建安装身份目录失败：%w", err)
	}
	dirInfo, err := os.Stat(dir)
	if err != nil {
		return "", fmt.Errorf("读取安装身份目录失败：%w", err)
	}
	if !dirInfo.IsDir() {
		return "", fmt.Errorf("安装身份目录不是目录：%s", dir)
	}

	installationID, err = newInstallationID(entropy)
	if err != nil {
		return "", fmt.Errorf("生成安装身份失败：%w", err)
	}
	if err := publishInstallationID(path, installationID); err != nil {
		if errors.Is(err, fs.ErrExist) {
			// 多个 agentd 同时首次启动时，只有一个进程能发布目标文件；其他进程必须
			// 读取获胜者的身份，不能各自继续使用尚未持久化的随机值。
			return readInstallationID(path)
		}
		return "", err
	}
	return readInstallationID(path)
}

func publishInstallationID(path string, installationID string) error {
	dir := filepath.Dir(path)
	staged, err := CreatePrivateTemp(dir, ".installation-id-")
	if err != nil {
		return fmt.Errorf("创建安装身份暂存文件失败：%w", err)
	}
	stagedPath := staged.Name()
	defer func() {
		_ = staged.Close()
		_ = os.Remove(stagedPath)
	}()

	if err := prepareInstallationIDFile(staged); err != nil {
		return fmt.Errorf("设置安装身份暂存文件权限失败：%w", err)
	}
	if _, err := io.WriteString(staged, installationID+"\n"); err != nil {
		return fmt.Errorf("写入安装身份暂存文件失败：%w", err)
	}
	if err := staged.Sync(); err != nil {
		return fmt.Errorf("同步安装身份暂存文件失败：%w", err)
	}
	if err := staged.Close(); err != nil {
		return fmt.Errorf("关闭安装身份暂存文件失败：%w", err)
	}

	// hard link 是 no-clobber 的原子提交点：目标并发出现时返回 EEXIST，
	// 不会像 rename 一样覆盖另一进程已经发布的稳定身份。
	if err := os.Link(stagedPath, path); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fs.ErrExist
		}
		return fmt.Errorf("提交安装身份失败：%w", err)
	}
	if err := syncInstallationIDDirectory(dir); err != nil {
		return fmt.Errorf("同步安装身份目录失败：%w", err)
	}
	if err := os.Remove(stagedPath); err != nil {
		return fmt.Errorf("清理安装身份暂存文件失败：%w", err)
	}
	stagedPath = ""
	if err := syncInstallationIDDirectory(dir); err != nil {
		return fmt.Errorf("同步安装身份目录失败：%w", err)
	}
	return nil
}

func readInstallationID(path string) (string, error) {
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !pathInfo.Mode().IsRegular() {
		return "", fmt.Errorf("安装身份必须是普通文件，不能是目录或符号链接：%s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("读取安装身份失败：%w", err)
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil {
		return "", fmt.Errorf("读取安装身份文件状态失败：%w", err)
	}
	if !openedInfo.Mode().IsRegular() || !os.SameFile(pathInfo, openedInfo) {
		return "", fmt.Errorf("安装身份文件在读取期间发生变化，拒绝继续启动")
	}
	// 只接受固定 36 字节 UUID 和一个换行，限制读取长度也避免异常文件造成无界分配。
	installationID, err := readCanonicalInstallationID(file, path)
	if err != nil {
		return "", err
	}

	if permissionErr := validateInstallationIDFilePermissions(openedInfo); permissionErr != nil {
		// 只在内容已经验证为现有合法身份后修复权限；直接操作已核验的文件描述符，
		// 避免对路径二次 chmod 时被符号链接或并发替换劫持。
		if err := prepareInstallationIDFile(file); err != nil {
			return "", fmt.Errorf(
				"收紧安装身份文件权限失败（%v）：%s：%w",
				permissionErr,
				path,
				err,
			)
		}
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			return "", fmt.Errorf("重新校验安装身份失败：%w", err)
		}
		recheckedID, err := readCanonicalInstallationID(file, path)
		if err != nil {
			return "", err
		}
		if recheckedID != installationID {
			return "", fmt.Errorf("安装身份文件在权限修复期间发生变化，拒绝继续启动")
		}
	}

	finalOpenedInfo, err := file.Stat()
	if err != nil {
		return "", fmt.Errorf("确认安装身份文件状态失败：%w", err)
	}
	finalPathInfo, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("确认安装身份文件路径失败：%w", err)
	}
	if !finalPathInfo.Mode().IsRegular() ||
		!finalOpenedInfo.Mode().IsRegular() ||
		!os.SameFile(finalPathInfo, finalOpenedInfo) {
		return "", fmt.Errorf("安装身份文件在读取期间发生变化，拒绝继续启动")
	}
	if err := validateInstallationIDFilePermissions(finalOpenedInfo); err != nil {
		return "", fmt.Errorf("安装身份文件在读取期间权限发生变化：%w", err)
	}
	if err := validateInstallationIDFilePermissions(finalPathInfo); err != nil {
		return "", fmt.Errorf("安装身份文件路径权限异常：%w", err)
	}
	return installationID, nil
}

func readCanonicalInstallationID(file io.Reader, path string) (string, error) {
	raw, err := io.ReadAll(io.LimitReader(file, 38))
	if err != nil {
		return "", fmt.Errorf("读取安装身份失败：%w", err)
	}
	if len(raw) != 37 || raw[36] != '\n' {
		return "", fmt.Errorf("安装身份文件格式损坏：%s", path)
	}
	installationID := string(raw[:36])
	if !isCanonicalInstallationID(installationID) {
		return "", fmt.Errorf("安装身份不是规范 UUID：%s", path)
	}
	return installationID, nil
}

func newInstallationID(entropy io.Reader) (string, error) {
	var value [16]byte
	if _, err := io.ReadFull(entropy, value[:]); err != nil {
		return "", err
	}
	// 使用 RFC 4122 UUID v4 表示随机安装身份；不读取硬件序列号、用户名或机器标识。
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"%08x-%04x-%04x-%04x-%012x",
		value[0:4],
		value[4:6],
		value[6:8],
		value[8:10],
		value[10:16],
	), nil
}

func isCanonicalInstallationID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	for index := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		character := value[index]
		if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')) {
			return false
		}
	}
	if value[14] != '4' {
		return false
	}
	switch value[19] {
	case '8', '9', 'a', 'b':
		return true
	default:
		return false
	}
}
