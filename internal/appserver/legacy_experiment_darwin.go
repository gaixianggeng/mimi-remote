//go:build darwin

package appserver

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	legacyCodexSharedDaemonLabel = "com.gaixianggeng.mimi.codex-shared-daemon"
	legacyCodexOwnershipEnvKey   = "MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH"
)

type legacyExperimentInspectionOps struct {
	homeDir   func() (string, error)
	lstat     func(string) (os.FileInfo, error)
	launchctl func(...string) (string, bool, error)
}

// LegacyCodexExperimentResidue 只检测旧实验 owner，不停止进程或改写用户环境。
// 新版必须在任何配置修复或 App Server 启动前失败关闭，避免两套 owner 混跑。
func LegacyCodexExperimentResidue() (string, error) {
	return inspectLegacyCodexExperiment(legacyExperimentInspectionOps{
		homeDir: os.UserHomeDir,
		lstat:   os.Lstat,
		launchctl: func(args ...string) (string, bool, error) {
			output, err := exec.Command("/bin/launchctl", args...).CombinedOutput()
			if err == nil {
				return strings.TrimSpace(string(output)), true, nil
			}
			if _, ok := err.(*exec.ExitError); ok {
				return strings.TrimSpace(string(output)), false, nil
			}
			return "", false, err
		},
	})
}

func inspectLegacyCodexExperiment(ops legacyExperimentInspectionOps) (string, error) {
	home, err := ops.homeDir()
	if err != nil {
		return "", fmt.Errorf("检查旧 Codex 实验目录失败：%w", err)
	}
	details := []string{}
	plistPath := filepath.Join(home, "Library", "LaunchAgents", legacyCodexSharedDaemonLabel+".plist")
	if _, err := ops.lstat(plistPath); err == nil {
		details = append(details, "旧 LaunchAgent 配置仍存在")
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("检查旧 Codex 实验 LaunchAgent 失败：%w", err)
	}

	domainTarget := fmt.Sprintf("gui/%d/%s", os.Getuid(), legacyCodexSharedDaemonLabel)
	if _, loaded, err := ops.launchctl("print", domainTarget); err != nil {
		return "", fmt.Errorf("检查旧 Codex 实验 job 失败：%w", err)
	} else if loaded {
		details = append(details, "旧 LaunchAgent job 仍已加载")
	}
	if marker, present, err := ops.launchctl("getenv", legacyCodexOwnershipEnvKey); err != nil {
		return "", fmt.Errorf("检查旧 Codex 实验环境失败：%w", err)
	} else if present && strings.TrimSpace(marker) != "" {
		details = append(details, "旧 Desktop ownership 环境仍存在")
	}
	return strings.Join(details, "；"), nil
}
