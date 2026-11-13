//go:build !windows

package main

// macOS 与 Linux 的受管子进程沿用 launchd / systemd 的环境，不使用系统代理中转。
func startSystemProxyRelay() (func(), error) {
	return func() {}, nil
}
