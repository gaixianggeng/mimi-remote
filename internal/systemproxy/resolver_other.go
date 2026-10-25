//go:build !windows

package systemproxy

// SystemResolver 只在 Windows 上可用：macOS 与 Linux 的受管子进程沿用各自服务管理器的
// 环境，系统代理问题不在本包处理范围内。
func SystemResolver() (Resolver, bool) {
	return nil, false
}
