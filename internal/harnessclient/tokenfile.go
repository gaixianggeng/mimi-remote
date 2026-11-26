package harnessclient

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
)

// maxTokenFileBytes 限制凭据文件体积。正常的启动 token 只有几十字节，
// 远大于这个上限说明路径指向了别的文件。
const maxTokenFileBytes = 4 << 10

// ReadTokenFile 读取 Harness 启动 token 文件。
//
// 凭据单独放在一个只对当前用户可读的文件里，而不是写进主配置：主配置会随安装包、
// 备份和诊断导出扩散，不适合承载访问凭据。因此这里对权限做硬校验——非 0600
// 直接拒绝加载，而不是静默接受一个全局可读的 token。
//
// Windows 没有 POSIX 权限位，跳过权限校验，依赖文件所在目录的 ACL。
func ReadTokenFile(path string) (string, error) {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return "", errors.New("harnessclient: token 文件路径为空")
	}
	info, err := os.Stat(trimmed)
	if err != nil {
		return "", fmt.Errorf("harnessclient: 读取 Harness token 文件失败：%w", err)
	}
	if info.IsDir() {
		return "", errors.New("harnessclient: token 文件路径指向目录")
	}
	if info.Size() > maxTokenFileBytes {
		return "", fmt.Errorf("harnessclient: token 文件超过 %d 字节", maxTokenFileBytes)
	}
	if runtime.GOOS != "windows" {
		if mode := info.Mode().Perm(); mode&0o077 != 0 {
			return "", fmt.Errorf("harnessclient: token 文件权限过于宽松（%#o），需要 0600", mode)
		}
	}
	raw, err := os.ReadFile(trimmed)
	if err != nil {
		return "", fmt.Errorf("harnessclient: 读取 Harness token 文件失败：%w", err)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", errors.New("harnessclient: token 文件为空")
	}
	// 去掉首尾空白后仍有换行，说明文件里有不止一行内容，
	// 大概率被写成了配置或日志；这种内容当成 token 会静默认证失败。
	if strings.ContainsAny(token, "\r\n") {
		return "", errors.New("harnessclient: token 文件应只有一行")
	}
	return token, nil
}
