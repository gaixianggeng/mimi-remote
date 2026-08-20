//go:build darwin

package appserver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// sharedDaemonResponsibleSupervisorFlag 是 Mimi App 主可执行文件进入无 UI
// supervisor 模式的唯一开关。Swift 侧 CodexDaemonSupervisorInvocation.flag 必须
// 使用同一个字面量，TestSharedDaemonResponsibleSupervisorContractMatchesSwift
// 会直接读取 Swift 源码比对，避免两侧各自漂移。
const sharedDaemonResponsibleSupervisorFlag = "--codex-daemon-supervisor"

// 与 sharedDaemonResolveSupervisorNode 同样的替换点：测试可以在不安装真实
// Mimi App 的前提下覆盖两种 ProgramArguments 形态。
var sharedDaemonResolveResponsibleSupervisor = resolveSharedDaemonResponsibleSupervisor

// resolveSharedDaemonResponsibleSupervisor 返回当前 agentd 所在 Mimi App bundle
// 的主可执行文件。
//
// 存在这一层的原因只有一个：macOS 的 TCC 授权按“责任进程”记账。launchd 直接拉起
// 裸二进制时，责任进程就是它自己——node/codex 没有 Info.plist，永远弹不出授权框，
// 也就永远拿不到照片图库这类需要显式授权的域（MIM-170 实测：桌面/文稿/下载可读，
// 照片图库 EPERM）。把 App bundle 主可执行文件放在链条最上层后，责任进程变成
// com.gaixianggeng.mimi.mac，它有 Info.plist 能弹窗、按 bundle ID 记账（App 升级
// 或移动都不会失效），授权再沿进程链继承给 node 与 codex。
//
// 这确实让 Mimi 重新进入了 MIM-157 刻意断开的责任链，代价是实验模式下 Codex
// Desktop 的文件访问会归因到 Mimi。但 MIM-157 真正踩的坑是 agentd 这个裸二进制按
// 路径记账、App 一升级授权就失效；换成 bundle 记账后该问题不复存在。
//
// agentd 以 Homebrew 或开发构建等非 App 形态运行时返回 false，调用方继续沿用
// 只有 OpenAI node 的旧 ProgramArguments，不影响既有安装。
func resolveSharedDaemonResponsibleSupervisor() (string, bool) {
	executable, err := os.Executable()
	if err != nil {
		return "", false
	}
	canonical, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return "", false
	}
	bundle, ok := sharedDaemonAppBundleForResource(canonical)
	if !ok {
		return "", false
	}
	supervisor, err := sharedDaemonBundleMainExecutable(bundle)
	if err != nil {
		return "", false
	}
	return supervisor, true
}

// sharedDaemonAppBundleForResource 只认 <X>.app/Contents/Resources/<binary> 这一种
// 布局。agentd 在 App 内的位置由 embed-agentd.sh 固定，用严格前缀匹配而不是逐级
// 向上搜索 .app，可以避免把仓库或临时目录里同名路径误判成安装态 App。
func sharedDaemonAppBundleForResource(binary string) (string, bool) {
	resources := filepath.Dir(binary)
	if filepath.Base(resources) != "Resources" {
		return "", false
	}
	contents := filepath.Dir(resources)
	if filepath.Base(contents) != "Contents" {
		return "", false
	}
	bundle := filepath.Dir(contents)
	if filepath.Ext(bundle) != ".app" {
		return "", false
	}
	return bundle, true
}

// sharedDaemonBundleMainExecutable 从 Contents/MacOS 取主可执行文件。这里不解析
// Info.plist 的 CFBundleExecutable：Contents/MacOS 恰好只有一个可执行文件是 App
// bundle 的常态，"恰好一个"本身就是最强的判据；出现第二个文件说明 bundle 结构与
// 预期不符，此时宁可退回旧链条也不猜。
func sharedDaemonBundleMainExecutable(bundle string) (string, error) {
	directory := filepath.Join(bundle, "Contents", "MacOS")
	entries, err := os.ReadDir(directory)
	if err != nil {
		return "", fmt.Errorf("读取 App 主可执行目录失败：%w", err)
	}
	candidate := ""
	for _, entry := range entries {
		if entry.IsDir() {
			return "", fmt.Errorf("App 主可执行目录包含子目录，结构不符合预期")
		}
		info, err := entry.Info()
		if err != nil {
			return "", fmt.Errorf("读取 App 主可执行文件属性失败：%w", err)
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
			return "", fmt.Errorf("App 主可执行目录包含非可执行文件，结构不符合预期")
		}
		if candidate != "" {
			return "", fmt.Errorf("App 主可执行目录存在多个可执行文件，结构不符合预期")
		}
		candidate = filepath.Join(directory, entry.Name())
	}
	if candidate == "" {
		return "", fmt.Errorf("App 主可执行目录为空")
	}
	// 规范化后再写进 plist，避免 launchd 执行的目标与这里校验过的文件不是同一个。
	canonical, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", fmt.Errorf("解析 App 主可执行文件失败：%w", err)
	}
	return canonical, nil
}

// sharedDaemonLaunchAgentProgramArguments 组装 plist 真正执行的命令。
//
// 有 Mimi supervisor 时只向它传 node 与 codex 两个绝对路径，不传 -e 脚本：脚本正文
// 一旦可以从命令行注入，任何同用户进程都能借 Mimi 的 TCC 授权执行任意 JS，等于把
// 责任进程做成了权限旁路 gadget。Swift 侧持有自己的脚本副本并逐字段比对参数，
// 只肯拉起 OpenAI 签名的 node 与 codex。
//
// 没有 Mimi supervisor 时（Homebrew / 开发构建）保持原样，由 launchd 直接执行
// OpenAI 签名的 node supervisor。
func sharedDaemonLaunchAgentProgramArguments(responsibleBin string, nodePath string, codexPath string) []string {
	if strings.TrimSpace(responsibleBin) == "" {
		return sharedDaemonSupervisorProgramArguments(nodePath, codexPath)
	}
	return []string{
		responsibleBin,
		sharedDaemonResponsibleSupervisorFlag,
		nodePath,
		codexPath,
	}
}
