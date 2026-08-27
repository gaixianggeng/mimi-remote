//go:build darwin

package setup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

const (
	legacyLaunchAgentLabel = "com.gaixianggeng.mimi.codex-shared-daemon"
	legacyDefaultsDomain   = "com.gaixianggeng.mimi.mac"
	legacyDaemonEnvKey     = "CODEX_APP_SERVER_USE_LOCAL_DAEMON"
	legacyCodexHomeEnvKey  = "CODEX_HOME"
	legacyEpochEnvKey      = "MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH"
)

var runDesktopSyncLegacyCommand = func(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

type legacyDesktopLedger struct {
	previousDaemon string
	writtenDaemon  string
	ownsDaemon     bool
	previousHome   string
	writtenHome    string
	ownsHome       bool
	writtenEpoch   string
	ownsEpoch      bool
}

func desktopSyncLegacyArtifactsPresent() (bool, error) {
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		return false, err
	}
	for _, path := range paths {
		if _, err := os.Lstat(path); err == nil {
			return true, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return false, fmt.Errorf("检查旧共享 daemon 文件失败：%w", err)
		}
	}
	ledger, err := readLegacyDesktopLedger(context.Background())
	if err != nil {
		return false, err
	}
	return ledger.ownsDaemon || ledger.ownsHome || ledger.ownsEpoch, nil
}

func cleanupDesktopSyncLegacyArtifacts(ctx context.Context) error {
	running, err := legacyDesktopRunning(ctx)
	if err != nil {
		return fmt.Errorf("确认 Codex Desktop 已退出失败：%w", err)
	}
	if running {
		return fmt.Errorf("Codex Desktop 仍在运行；请完全退出后再执行遗留清理")
	}
	ledger, err := readLegacyDesktopLedger(ctx)
	if err != nil {
		return err
	}
	ownershipMatches, err := legacyDesktopOwnershipMatches(ctx, ledger)
	if err != nil {
		return err
	}
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		return err
	}
	if err := validateDesktopSyncLegacyFiles(paths, ownershipMatches); err != nil {
		return err
	}
	jobTarget := fmt.Sprintf("gui/%d/%s", os.Getuid(), legacyLaunchAgentLabel)
	if output, err := runDesktopSyncLegacyCommand(ctx, "/bin/launchctl", "bootout", jobTarget); err != nil &&
		!legacyLaunchctlMissing(string(output)) {
		return fmt.Errorf("卸载旧共享 daemon LaunchAgent 失败")
	}
	for _, path := range paths {
		info, statErr := os.Lstat(path)
		if errors.Is(statErr, os.ErrNotExist) {
			continue
		}
		if statErr != nil {
			return fmt.Errorf("检查旧共享 daemon 文件失败：%w", statErr)
		}
		if info.IsDir() {
			return fmt.Errorf("旧共享 daemon 固定文件路径被目录占用，拒绝删除")
		}
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("删除旧共享 daemon 文件失败：%w", err)
		}
	}
	// 最后恢复 launchctl。这样 bootout 或删除文件失败时，ownership epoch
	// 仍然匹配，用户可以安全地重复执行清理。
	if err := restoreOwnedLegacyDesktopEnvironment(ctx, ledger); err != nil {
		return err
	}
	for _, key := range legacyDesktopPreferenceKeys() {
		_, _ = runDesktopSyncLegacyCommand(ctx, "/usr/bin/defaults", "delete", legacyDefaultsDomain, key)
	}
	return nil
}

func legacyDesktopRunning(ctx context.Context) (bool, error) {
	output, err := runDesktopSyncLegacyCommand(ctx, "/usr/bin/lsappinfo", "find", "bundleid=com.openai.codex")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(output)) != "", nil
}

func desktopSyncLegacyPaths() ([]string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("解析用户 Home 失败：%w", err)
	}
	return []string{
		filepath.Join(home, "Library", "LaunchAgents", legacyLaunchAgentLabel+".plist"),
		filepath.Join(home, "Library", "Application Support", "mimi-remote", "codex-shared-daemon-migration-required"),
		filepath.Join(home, "Library", "Application Support", "mimi-remote", "codex-shared-daemon-enable-prepared"),
		filepath.Join(home, "Library", "Logs", "mimi-remote", "codex-shared-daemon.log"),
	}, nil
}

func readLegacyDesktopLedger(ctx context.Context) (legacyDesktopLedger, error) {
	read := func(key string) string {
		output, err := runDesktopSyncLegacyCommand(ctx, "/usr/bin/defaults", "read", legacyDefaultsDomain, key)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(output))
	}
	readBool := func(key string) bool {
		value := strings.ToLower(read(key))
		return value == "1" || value == "true" || value == "yes"
	}
	return legacyDesktopLedger{
		previousDaemon: read("MimiRemoteMac.codexDesktop.previousValue"),
		writtenDaemon:  read("MimiRemoteMac.codexDesktop.writtenValue"),
		ownsDaemon:     readBool("MimiRemoteMac.codexDesktop.ownsEnvironment"),
		previousHome:   read("MimiRemoteMac.codexDesktop.previousCodexHome"),
		writtenHome:    read("MimiRemoteMac.codexDesktop.writtenCodexHome"),
		ownsHome:       readBool("MimiRemoteMac.codexDesktop.ownsCodexHome"),
		writtenEpoch:   read("MimiRemoteMac.codexDesktop.writtenSessionEpoch"),
		ownsEpoch:      readBool("MimiRemoteMac.codexDesktop.ownsSessionEpoch"),
	}, nil
}

func restoreOwnedLegacyDesktopEnvironment(ctx context.Context, ledger legacyDesktopLedger) error {
	ownershipMatches, err := legacyDesktopOwnershipMatches(ctx, ledger)
	if err != nil {
		return err
	}
	if !ownershipMatches {
		return nil
	}
	currentDaemon := launchctlGetenv(ctx, legacyDaemonEnvKey)
	currentHome := launchctlGetenv(ctx, legacyCodexHomeEnvKey)
	currentEpoch := launchctlGetenv(ctx, legacyEpochEnvKey)
	if ledger.ownsDaemon && ledger.writtenDaemon != "" && currentDaemon == ledger.writtenDaemon {
		if err := restoreLaunchctlValue(ctx, legacyDaemonEnvKey, ledger.previousDaemon); err != nil {
			return err
		}
	}
	if ledger.ownsHome && ledger.writtenHome != "" && currentHome == ledger.writtenHome {
		if err := restoreLaunchctlValue(ctx, legacyCodexHomeEnvKey, ledger.previousHome); err != nil {
			return err
		}
	}
	if currentEpoch == ledger.writtenEpoch {
		if err := restoreLaunchctlValue(ctx, legacyEpochEnvKey, ""); err != nil {
			return err
		}
	}
	return nil
}

func legacyDesktopOwnershipMatches(ctx context.Context, ledger legacyDesktopLedger) (bool, error) {
	owned := ledger.ownsDaemon || ledger.ownsHome || ledger.ownsEpoch
	if !owned {
		return false, nil
	}
	currentEpoch := launchctlGetenv(ctx, legacyEpochEnvKey)
	if !ledger.ownsEpoch || ledger.writtenEpoch == "" || currentEpoch != ledger.writtenEpoch {
		return false, fmt.Errorf("无法确认旧共享 daemon 环境变量仍由 Mimi 持有；已保留 ownership 账本和遗留文件")
	}
	return true, nil
}

func validateDesktopSyncLegacyFiles(paths []string, ownershipMatches bool) error {
	for _, path := range paths {
		info, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
			return fmt.Errorf("旧共享 daemon 文件 ownership 无法确认：%s", filepath.Base(path))
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != uint32(os.Getuid()) {
			return fmt.Errorf("旧共享 daemon 文件不属于当前用户：%s", filepath.Base(path))
		}
		payload, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("读取旧共享 daemon 文件失败：%w", err)
		}
		switch filepath.Base(path) {
		case legacyLaunchAgentLabel + ".plist":
			text := string(payload)
			if !strings.Contains(text, "<string>"+legacyLaunchAgentLabel+"</string>") ||
				!strings.Contains(text, "<string>--codex-daemon-supervisor</string>") {
				return fmt.Errorf("旧共享 daemon plist 已被替换，拒绝删除")
			}
		case "codex-shared-daemon-migration-required":
			if string(payload) != "restart-required\n" {
				return fmt.Errorf("旧共享 daemon 迁移标记已被替换，拒绝删除")
			}
		case "codex-shared-daemon-enable-prepared":
			if string(payload) != "enable-prepared\n" {
				return fmt.Errorf("旧共享 daemon 启用标记已被替换，拒绝删除")
			}
		case "codex-shared-daemon.log":
			if !ownershipMatches {
				return fmt.Errorf("缺少匹配的 ownership 账本，拒绝删除旧共享 daemon 日志")
			}
		}
	}
	return nil
}

func launchctlGetenv(ctx context.Context, key string) string {
	output, err := runDesktopSyncLegacyCommand(ctx, "/bin/launchctl", "getenv", key)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func restoreLaunchctlValue(ctx context.Context, key string, previous string) error {
	args := []string{"unsetenv", key}
	if previous != "" {
		args = []string{"setenv", key, previous}
	}
	if _, err := runDesktopSyncLegacyCommand(ctx, "/bin/launchctl", args...); err != nil {
		return fmt.Errorf("恢复旧 Desktop 环境变量失败")
	}
	return nil
}

func legacyLaunchctlMissing(output string) bool {
	value := strings.ToLower(output)
	return strings.Contains(value, "could not find service") ||
		strings.Contains(value, "no such process") ||
		strings.Contains(value, strconv.Itoa(os.Getuid())+" not found")
}

func legacyDesktopPreferenceKeys() []string {
	return []string{
		"MimiRemoteMac.codexDesktop.enabled",
		"MimiRemoteMac.codexDesktop.previousValue",
		"MimiRemoteMac.codexDesktop.writtenValue",
		"MimiRemoteMac.codexDesktop.ownsEnvironment",
		"MimiRemoteMac.codexDesktop.previousCodexHome",
		"MimiRemoteMac.codexDesktop.writtenCodexHome",
		"MimiRemoteMac.codexDesktop.ownsCodexHome",
		"MimiRemoteMac.codexDesktop.writtenSessionEpoch",
		"MimiRemoteMac.codexDesktop.ownsSessionEpoch",
		"MimiRemoteMac.codexDesktop.codexHome",
		"MimiRemoteMac.codexDesktop.restartRequiredAt",
		"MimiRemoteMac.codexDesktop.pendingEnabled",
		"MimiRemoteMac.codexDesktop.pendingReopen",
	}
}
