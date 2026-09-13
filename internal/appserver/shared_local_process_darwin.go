//go:build darwin

package appserver

import (
	"os/exec"
	"syscall"
)

// macOS 没有 systemd。resident 由 agentd 直接启动，必须脱离 agentd 的会话与进程组，
// 否则 launchd 结束或重启 agentd job 时会连同 resident 一起回收。
func configureSharedLocalCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

// launchd 启动的进程 open-file soft limit 通常只有 256，与 SSH 登录相同。App Server
// 会为仍处于加载宽限期的每个 Thread 保留 session 与 MCP 文件描述符，这里和 SSH
// bootstrap 保持同一下限：低于 8192 先提高；提不上去就拒绝启动，不降低已有更高的值。
// `$0` 是 Codex 可执行文件，`$@` 是 app-server 参数；exec 后 pid 不变，调用方仍能
// 观察到启动即退出。
const darwinResidentLaunchScript = `open_file_limit=$(ulimit -Sn); ` +
	`if test "$open_file_limit" != unlimited && test "$open_file_limit" -lt 8192; then ` +
	`ulimit -Sn 8192 || { printf "共享 Codex App Server 的 open-file soft limit 无法提高到 8192\n" >&2; exit 72; }; ` +
	`fi; exec "$0" "$@"`

func residentLaunchCommand(bin string, args []string) (string, []string) {
	return "/bin/sh", append([]string{"-c", darwinResidentLaunchScript, bin}, args...)
}
