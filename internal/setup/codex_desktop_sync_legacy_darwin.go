//go:build darwin

package setup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	legacyLaunchAgentLabel                 = "com.gaixianggeng.mimi.codex-shared-daemon"
	legacyDefaultsDomain                   = "com.gaixianggeng.mimi.mac"
	legacyDaemonEnvKey                     = "CODEX_APP_SERVER_USE_LOCAL_DAEMON"
	legacyCodexHomeEnvKey                  = "CODEX_HOME"
	legacyEpochEnvKey                      = "MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH"
	legacyOperationLockName                = "codex-shared-daemon-operation.lock"
	legacyCleanupPhaseKey                  = "MimiRemoteMac.codexDesktop.cleanupPhase"
	legacyCleanupPhaseEnvironmentRestoring = "environment-restoring"
	legacyCleanupPhaseEnvironmentRestored  = "environment-restored"
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
	cleanupPhase   string
	presentKeys    map[string]bool
	values         map[string]string
}

type legacyDesktopEnvironment struct {
	daemon    string
	daemonSet bool
	home      string
	homeSet   bool
	epoch     string
	epochSet  bool
}

type legacyDesktopFileIdentity struct {
	device uint64
	inode  uint64
}

func desktopSyncLegacyArtifactsPresent() (bool, error) {
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		return false, err
	}
	ledger, err := readLegacyDesktopLedger(context.Background())
	if err != nil {
		return false, err
	}
	if err := validateLegacyDesktopCleanupPhase(ledger.cleanupPhase); err != nil {
		return false, err
	}
	filesPresent, err := legacyDesktopLegacyFilesPresent(paths)
	if err != nil {
		return false, err
	}
	if !filesPresent && len(ledger.presentKeys) == 0 {
		return false, nil
	}
	inert, err := legacyDesktopInertRetiredRemnants(context.Background(), paths, ledger)
	if err != nil {
		return false, err
	}
	if inert {
		return false, nil
	}
	for _, path := range paths {
		if _, err := os.Lstat(path); err == nil {
			return true, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return false, fmt.Errorf("检查旧共享 daemon 文件失败：%w", err)
		}
	}
	return len(ledger.presentKeys) > 0, nil
}

func legacyDesktopInertRetiredRemnants(
	ctx context.Context,
	paths []string,
	ledger legacyDesktopLedger,
) (bool, error) {
	if !legacyDesktopLedgerIsRetired(ledger) {
		return false, nil
	}
	for _, path := range paths {
		info, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return false, fmt.Errorf("检查旧共享 daemon 文件失败：%w", err)
		}
		name := filepath.Base(path)
		if name != legacyOperationLockName && name != "codex-shared-daemon.log" {
			return false, nil
		}
		if err := validateLegacyDesktopInertFile(path, info); err != nil {
			return false, nil
		}
	}
	environment, err := readLegacyDesktopEnvironment(ctx)
	if err != nil {
		return false, err
	}
	if environment.daemonSet || environment.homeSet || environment.epochSet {
		return false, nil
	}
	jobTarget := fmt.Sprintf("gui/%d/%s", os.Getuid(), legacyLaunchAgentLabel)
	loaded, err := validateLegacyDesktopLaunchJob(ctx, jobTarget, "", false)
	if err != nil {
		return false, err
	}
	return !loaded, nil
}

func legacyDesktopLedgerIsRetired(ledger legacyDesktopLedger) bool {
	if legacyDesktopLedgerOwnsEnvironment(ledger) || ledger.cleanupPhase != "" {
		return false
	}
	allowed := map[string]bool{
		"MimiRemoteMac.codexDesktop.enabled":          true,
		"MimiRemoteMac.codexDesktop.codexHome":        true,
		"MimiRemoteMac.codexDesktop.ownsEnvironment":  true,
		"MimiRemoteMac.codexDesktop.ownsCodexHome":    true,
		"MimiRemoteMac.codexDesktop.ownsSessionEpoch": true,
	}
	for key := range ledger.presentKeys {
		if !allowed[key] {
			return false
		}
		if key != "MimiRemoteMac.codexDesktop.codexHome" &&
			!legacyDesktopExplicitFalse(ledger.values[key]) {
			return false
		}
	}
	return true
}

func legacyDesktopExplicitFalse(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "0", "false", "no":
		return true
	default:
		return false
	}
}

func validateLegacyDesktopInertFile(path string, lstatInfo os.FileInfo) error {
	if !lstatInfo.Mode().IsRegular() || lstatInfo.Mode().Perm()&0o077 != 0 || lstatInfo.Size() != 0 {
		return fmt.Errorf("旧共享 daemon 无害残留文件身份无法确认：%s", filepath.Base(path))
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("安全打开旧共享 daemon 无害残留文件失败：%w", err)
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil {
		return fmt.Errorf("检查旧共享 daemon 无害残留文件失败：%w", err)
	}
	openedStat, openedOK := openedInfo.Sys().(*syscall.Stat_t)
	lstatStat, lstatOK := lstatInfo.Sys().(*syscall.Stat_t)
	if !openedOK || !lstatOK || openedStat.Uid != uint32(os.Getuid()) ||
		!openedInfo.Mode().IsRegular() || openedInfo.Mode().Perm()&0o077 != 0 || openedInfo.Size() != 0 ||
		(legacyDesktopFileIdentity{device: uint64(openedStat.Dev), inode: uint64(openedStat.Ino)}) !=
			(legacyDesktopFileIdentity{device: uint64(lstatStat.Dev), inode: uint64(lstatStat.Ino)}) {
		return fmt.Errorf("旧共享 daemon 无害残留文件身份无法确认：%s", filepath.Base(path))
	}
	return nil
}

func cleanupDesktopSyncLegacyArtifacts(ctx context.Context) error {
	running, err := legacyDesktopRunning(ctx)
	if err != nil {
		return fmt.Errorf("确认 Codex Desktop 已退出失败：%w", err)
	}
	if running {
		return fmt.Errorf("Codex Desktop 仍在运行；请完全退出后再执行遗留清理")
	}
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		return err
	}
	ledger, err := readLegacyDesktopLedger(ctx)
	if err != nil {
		return err
	}
	if err := validateLegacyDesktopCleanupPhase(ledger.cleanupPhase); err != nil {
		return err
	}
	legacyFilesPresent, err := legacyDesktopLegacyFilesPresent(paths)
	if err != nil {
		return err
	}
	if !legacyDesktopLedgerOwnsEnvironment(ledger) && ledger.cleanupPhase == "" && !legacyFilesPresent && len(ledger.presentKeys) == 0 {
		return nil
	}
	legacyStateFilesPresent, err := legacyDesktopLegacyStateFilesPresent(paths)
	if err != nil {
		return err
	}
	_, ownershipMatches, err := prepareLegacyDesktopCleanup(ctx, ledger, legacyStateFilesPresent)
	if err != nil {
		return err
	}
	var operationLock *os.File
	operationLockPath, _, err := legacyDesktopLegacyFilePath(paths, legacyOperationLockName)
	if err != nil {
		return err
	}
	if ownershipMatches {
		operationLock, err = acquireLegacyDesktopOperationLock(ctx, operationLockPath)
		if err != nil {
			return err
		}
		defer releaseLegacyDesktopOperationLock(operationLock)
		// 旧进程可能在首次只读校验和拿锁之间完成一次操作。持锁后重新读取
		// ownership 账本与环境，避免按过期快照执行清理。
		ledger, err = readLegacyDesktopLedger(ctx)
		if err != nil {
			return err
		}
		if err := validateLegacyDesktopCleanupPhase(ledger.cleanupPhase); err != nil {
			return err
		}
		legacyStateFilesPresent, err = legacyDesktopLegacyStateFilesPresent(paths)
		if err != nil {
			return err
		}
		_, ownershipMatches, err = prepareLegacyDesktopCleanup(ctx, ledger, legacyStateFilesPresent)
		if err != nil {
			return err
		}
		if !ownershipMatches {
			return legacyDesktopOwnershipError()
		}
	}
	fileIdentities, err := validateDesktopSyncLegacyFiles(paths, ownershipMatches)
	if err != nil {
		return err
	}
	if ownershipMatches && ledger.cleanupPhase == "" {
		// 先写入可重入阶段，再开始 bootout、删文件或恢复环境。
		// 进程在任一副作用后退出时，下一次清理都能判断哪些值已经恢复。
		if err := writeLegacyDesktopCleanupPhase(ctx, legacyCleanupPhaseEnvironmentRestoring); err != nil {
			return err
		}
		ledger.cleanupPhase = legacyCleanupPhaseEnvironmentRestoring
	}
	if ownershipMatches {
		if err := requireLegacyDesktopStopped(ctx); err != nil {
			return err
		}
	}
	jobTarget := fmt.Sprintf("gui/%d/%s", os.Getuid(), legacyLaunchAgentLabel)
	plistPath, plistPresent, err := legacyDesktopLegacyFilePath(paths, legacyLaunchAgentLabel+".plist")
	if err != nil {
		return err
	}
	if ownershipMatches && ledger.cleanupPhase != legacyCleanupPhaseEnvironmentRestored {
		loaded, err := validateLegacyDesktopLaunchJob(ctx, jobTarget, plistPath, plistPresent)
		if err != nil {
			return err
		}
		if loaded {
			if err := requireLegacyDesktopStopped(ctx); err != nil {
				return err
			}
			identity, present, err := validateDesktopSyncLegacyFile(plistPath, ownershipMatches)
			if err != nil {
				return err
			}
			if expected, ok := fileIdentities[plistPath]; !present || !ok || identity != expected {
				return fmt.Errorf("旧共享 daemon plist 在验证后发生变化，拒绝 bootout")
			}
			stillLoaded, err := validateLegacyDesktopLaunchJob(ctx, jobTarget, plistPath, true)
			if err != nil {
				return err
			}
			if stillLoaded {
				if output, err := runDesktopSyncLegacyCommand(ctx, "/bin/launchctl", "bootout", jobTarget); err != nil &&
					!legacyLaunchctlMissing(string(output)+" "+err.Error()) {
					return fmt.Errorf("卸载旧共享 daemon LaunchAgent 失败：%w", err)
				}
			}
		}
	}
	for _, path := range paths {
		if path == operationLockPath || ledger.cleanupPhase == legacyCleanupPhaseEnvironmentRestored {
			continue
		}
		if err := removeValidatedDesktopSyncLegacyFile(path, fileIdentities[path], ownershipMatches); err != nil {
			return err
		}
	}
	if ownershipMatches {
		if err := requireLegacyDesktopStopped(ctx); err != nil {
			return err
		}
	}
	if err := restoreOwnedLegacyDesktopEnvironment(ctx, &ledger); err != nil {
		return err
	}
	// 环境恢复标记必须最后删除；epoch 清除后若偏好删除中断，重试仍可证明恢复已完成。
	for _, key := range legacyDesktopPreferenceKeys() {
		if !legacyDesktopPreferencePresent(ledger, key) {
			continue
		}
		if _, err := runDesktopSyncLegacyCommand(ctx, "/usr/bin/defaults", "delete", legacyDefaultsDomain, key); err != nil {
			return fmt.Errorf("删除旧 Desktop 偏好失败（%s）：%w", key, err)
		}
	}
	if ownershipMatches {
		if err := removeValidatedDesktopSyncLegacyFile(
			operationLockPath, fileIdentities[operationLockPath], true,
		); err != nil {
			return err
		}
	}
	return nil
}

func legacyDesktopLedgerOwnsEnvironment(ledger legacyDesktopLedger) bool {
	return ledger.ownsDaemon || ledger.ownsHome || ledger.ownsEpoch
}

func legacyDesktopPreferencePresent(ledger legacyDesktopLedger, key string) bool {
	if key == legacyCleanupPhaseKey && ledger.cleanupPhase != "" {
		return true
	}
	return ledger.presentKeys[key]
}

func legacyDesktopLegacyFilesPresent(paths []string) (bool, error) {
	for _, path := range paths {
		if _, err := os.Lstat(path); err == nil {
			return true, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return false, fmt.Errorf("检查旧共享 daemon 文件失败：%w", err)
		}
	}
	return false, nil
}

func legacyDesktopLegacyStateFilesPresent(paths []string) (bool, error) {
	for _, path := range paths {
		if filepath.Base(path) == legacyOperationLockName {
			continue
		}
		if _, err := os.Lstat(path); err == nil {
			return true, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return false, fmt.Errorf("检查旧共享 daemon 文件失败：%w", err)
		}
	}
	return false, nil
}

func acquireLegacyDesktopOperationLock(ctx context.Context, path string) (*os.File, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("旧共享 daemon 操作锁路径不可用")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("创建旧共享 daemon 操作锁目录失败：%w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, fmt.Errorf("打开旧共享 daemon 操作锁失败：%w", err)
	}
	closeWithError := func(message string, cause error) (*os.File, error) {
		_ = file.Close()
		return nil, fmt.Errorf("%s：%w", message, cause)
	}
	info, err := file.Stat()
	if err != nil {
		return closeWithError("检查旧共享 daemon 操作锁失败", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 ||
		stat.Uid != uint32(os.Getuid()) || info.Size() != 0 {
		_ = file.Close()
		return nil, fmt.Errorf("旧共享 daemon 操作锁 ownership 无法确认")
	}
	identity := legacyDesktopFileIdentity{device: uint64(stat.Dev), inode: uint64(stat.Ino)}
	for {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN {
			return closeWithError("获取旧共享 daemon 操作锁失败", err)
		}
		timer := time.NewTimer(25 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			_ = file.Close()
			return nil, fmt.Errorf("等待旧共享 daemon 操作完成失败：%w", ctx.Err())
		case <-timer.C:
		}
	}
	pathInfo, err := os.Lstat(path)
	if err != nil {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		return closeWithError("复核旧共享 daemon 操作锁失败", err)
	}
	pathStat, ok := pathInfo.Sys().(*syscall.Stat_t)
	if !ok || identity != (legacyDesktopFileIdentity{device: uint64(pathStat.Dev), inode: uint64(pathStat.Ino)}) {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		_ = file.Close()
		return nil, fmt.Errorf("旧共享 daemon 操作锁在获取期间被替换")
	}
	return file, nil
}

func releaseLegacyDesktopOperationLock(file *os.File) {
	if file == nil {
		return
	}
	_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	_ = file.Close()
}

func legacyDesktopLegacyFilePath(paths []string, name string) (string, bool, error) {
	for _, path := range paths {
		if filepath.Base(path) != name {
			continue
		}
		_, err := os.Lstat(path)
		if err == nil {
			return path, true, nil
		}
		if errors.Is(err, os.ErrNotExist) {
			return path, false, nil
		}
		return "", false, fmt.Errorf("检查旧共享 daemon 文件失败：%w", err)
	}
	return "", false, nil
}

func legacyDesktopRunning(ctx context.Context) (bool, error) {
	output, err := runDesktopSyncLegacyCommand(ctx, "/usr/bin/lsappinfo", "find", "bundleid=com.openai.codex")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(output)) != "", nil
}

func requireLegacyDesktopStopped(ctx context.Context) error {
	running, err := legacyDesktopRunning(ctx)
	if err != nil {
		return fmt.Errorf("再次确认 Codex Desktop 已退出失败：%w", err)
	}
	if running {
		return fmt.Errorf("Codex Desktop 在清理期间重新启动；已停止清理，请完全退出后重试")
	}
	return nil
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
		filepath.Join(home, "Library", "Application Support", "mimi-remote", legacyOperationLockName),
		filepath.Join(home, "Library", "Logs", "mimi-remote", "codex-shared-daemon.log"),
	}, nil
}

func readLegacyDesktopLedger(ctx context.Context) (legacyDesktopLedger, error) {
	presentKeys := map[string]bool{}
	values := map[string]string{}
	for _, key := range legacyDesktopPreferenceKeys() {
		value, present, err := legacyDefaultsRead(ctx, key)
		if err != nil {
			return legacyDesktopLedger{}, err
		}
		if present {
			presentKeys[key] = true
			values[key] = value
		}
	}
	readBool := func(key string) bool {
		value := strings.ToLower(values[key])
		return value == "1" || value == "true" || value == "yes"
	}
	previousDaemon := values["MimiRemoteMac.codexDesktop.previousValue"]
	writtenDaemon := values["MimiRemoteMac.codexDesktop.writtenValue"]
	ownsDaemon := readBool("MimiRemoteMac.codexDesktop.ownsEnvironment")
	previousHome := values["MimiRemoteMac.codexDesktop.previousCodexHome"]
	writtenHome := values["MimiRemoteMac.codexDesktop.writtenCodexHome"]
	ownsHome := readBool("MimiRemoteMac.codexDesktop.ownsCodexHome")
	writtenEpoch := values["MimiRemoteMac.codexDesktop.writtenSessionEpoch"]
	ownsEpoch := readBool("MimiRemoteMac.codexDesktop.ownsSessionEpoch")
	cleanupPhase := values[legacyCleanupPhaseKey]
	return legacyDesktopLedger{
		previousDaemon: previousDaemon,
		writtenDaemon:  writtenDaemon,
		ownsDaemon:     ownsDaemon,
		previousHome:   previousHome,
		writtenHome:    writtenHome,
		ownsHome:       ownsHome,
		writtenEpoch:   writtenEpoch,
		ownsEpoch:      ownsEpoch,
		cleanupPhase:   cleanupPhase,
		presentKeys:    presentKeys,
		values:         values,
	}, nil
}

func legacyDefaultsRead(ctx context.Context, key string) (string, bool, error) {
	output, err := runDesktopSyncLegacyCommand(ctx, "/usr/bin/defaults", "read", legacyDefaultsDomain, key)
	if err != nil {
		if legacyDefaultsMissing(key, string(output)+" "+err.Error()) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("读取旧 Desktop 偏好失败（%s）：%w", key, err)
	}
	return strings.TrimSpace(string(output)), true, nil
}

func legacyDefaultsMissing(key string, output string) bool {
	value := strings.ToLower(strings.TrimSpace(output))
	if value == "missing" {
		return true
	}
	key = strings.ToLower(strings.TrimSpace(key))
	if key == "" || !strings.Contains(value, key) {
		return false
	}
	if strings.Contains(value, "could not find key") || strings.Contains(value, "no such key") {
		return true
	}
	return strings.Contains(value, "domain/default pair") &&
		(strings.Contains(value, "does not exist") || strings.Contains(value, "not found"))
}

func validateLegacyDesktopCleanupPhase(phase string) error {
	if phase != "" && phase != legacyCleanupPhaseEnvironmentRestoring && phase != legacyCleanupPhaseEnvironmentRestored {
		return fmt.Errorf("旧共享 daemon 清理账本包含未知阶段；已保留 ownership 账本和遗留文件")
	}
	return nil
}

func readLegacyDesktopEnvironment(ctx context.Context) (legacyDesktopEnvironment, error) {
	daemon, daemonSet, err := launchctlGetenv(ctx, legacyDaemonEnvKey)
	if err != nil {
		return legacyDesktopEnvironment{}, err
	}
	home, homeSet, err := launchctlGetenv(ctx, legacyCodexHomeEnvKey)
	if err != nil {
		return legacyDesktopEnvironment{}, err
	}
	epoch, epochSet, err := launchctlGetenv(ctx, legacyEpochEnvKey)
	if err != nil {
		return legacyDesktopEnvironment{}, err
	}
	return legacyDesktopEnvironment{
		daemon: daemon, daemonSet: daemonSet,
		home: home, homeSet: homeSet,
		epoch: epoch, epochSet: epochSet,
	}, nil
}

func prepareLegacyDesktopCleanup(
	ctx context.Context,
	ledger legacyDesktopLedger,
	legacyFilesPresent bool,
) (legacyDesktopEnvironment, bool, error) {
	if ledger.cleanupPhase == legacyCleanupPhaseEnvironmentRestored {
		if legacyFilesPresent {
			return legacyDesktopEnvironment{}, false, fmt.Errorf("旧共享 daemon 清理状态不完整；已保留 ownership 账本和遗留文件")
		}
		epoch, epochSet, err := launchctlGetenv(ctx, legacyEpochEnvKey)
		if err != nil {
			return legacyDesktopEnvironment{}, false, err
		}
		if epochSet && (ledger.writtenEpoch == "" || epoch != ledger.writtenEpoch) {
			return legacyDesktopEnvironment{}, false, legacyDesktopOwnershipError()
		}
		return legacyDesktopEnvironment{epoch: epoch, epochSet: epochSet}, true, nil
	}
	if !legacyDesktopLedgerOwnsEnvironment(ledger) {
		if legacyFilesPresent {
			return legacyDesktopEnvironment{}, false, fmt.Errorf("缺少匹配的 ownership 账本，拒绝删除旧共享 daemon 文件")
		}
		return legacyDesktopEnvironment{}, false, nil
	}
	environment, err := readLegacyDesktopEnvironment(ctx)
	if err != nil {
		return legacyDesktopEnvironment{}, false, err
	}
	if !ledger.ownsEpoch || ledger.writtenEpoch == "" || !environment.epochSet || environment.epoch != ledger.writtenEpoch {
		return legacyDesktopEnvironment{}, false, legacyDesktopOwnershipError()
	}
	allowRestored := ledger.cleanupPhase == legacyCleanupPhaseEnvironmentRestoring
	if err := validateOwnedLegacyEnvironmentValue(
		legacyDaemonEnvKey, ledger.writtenDaemon, ledger.previousDaemon,
		environment.daemon, environment.daemonSet, ledger.ownsDaemon, allowRestored,
	); err != nil {
		return legacyDesktopEnvironment{}, false, err
	}
	if err := validateOwnedLegacyEnvironmentValue(
		legacyCodexHomeEnvKey, ledger.writtenHome, ledger.previousHome,
		environment.home, environment.homeSet, ledger.ownsHome, allowRestored,
	); err != nil {
		return legacyDesktopEnvironment{}, false, err
	}
	return environment, true, nil
}

func restoreOwnedLegacyDesktopEnvironment(ctx context.Context, ledger *legacyDesktopLedger) error {
	if ledger.cleanupPhase == "" {
		return nil
	}
	if ledger.cleanupPhase == legacyCleanupPhaseEnvironmentRestoring {
		if err := restoreOwnedLegacyDesktopValue(
			ctx, *ledger, legacyDaemonEnvKey, ledger.writtenDaemon, ledger.previousDaemon, ledger.ownsDaemon,
		); err != nil {
			return err
		}
		if err := restoreOwnedLegacyDesktopValue(
			ctx, *ledger, legacyCodexHomeEnvKey, ledger.writtenHome, ledger.previousHome, ledger.ownsHome,
		); err != nil {
			return err
		}
		current, err := readLegacyDesktopEnvironment(ctx)
		if err != nil {
			return err
		}
		if ledger.ownsDaemon && !legacyEnvironmentValueMatches(current.daemon, current.daemonSet, ledger.previousDaemon) {
			return legacyDesktopRestoreStateError()
		}
		if ledger.ownsHome && !legacyEnvironmentValueMatches(current.home, current.homeSet, ledger.previousHome) {
			return legacyDesktopRestoreStateError()
		}
		if !current.epochSet || current.epoch != ledger.writtenEpoch {
			return legacyDesktopOwnershipError()
		}
		if err := writeLegacyDesktopCleanupPhase(ctx, legacyCleanupPhaseEnvironmentRestored); err != nil {
			return err
		}
		ledger.cleanupPhase = legacyCleanupPhaseEnvironmentRestored
	}
	epoch, epochSet, err := launchctlGetenv(ctx, legacyEpochEnvKey)
	if err != nil {
		return err
	}
	if !epochSet {
		return nil
	}
	if ledger.writtenEpoch == "" || epoch != ledger.writtenEpoch {
		return legacyDesktopOwnershipError()
	}
	if err := verifyRestoredLegacyDesktopValues(ctx, *ledger); err != nil {
		return err
	}
	epoch, epochSet, err = launchctlGetenv(ctx, legacyEpochEnvKey)
	if err != nil {
		return err
	}
	if !epochSet || epoch != ledger.writtenEpoch {
		return legacyDesktopOwnershipError()
	}
	if err := requireLegacyDesktopStopped(ctx); err != nil {
		return err
	}
	if err := restoreLaunchctlValue(ctx, legacyEpochEnvKey, ""); err != nil {
		return err
	}
	return nil
}

func restoreOwnedLegacyDesktopValue(
	ctx context.Context,
	ledger legacyDesktopLedger,
	key string,
	written string,
	previous string,
	owned bool,
) error {
	if !owned {
		return nil
	}
	if err := verifyLegacyDesktopEpoch(ctx, ledger); err != nil {
		return err
	}
	current, present, err := launchctlGetenv(ctx, key)
	if err != nil {
		return err
	}
	if err := verifyLegacyDesktopEpoch(ctx, ledger); err != nil {
		return err
	}
	if legacyEnvironmentValueMatches(current, present, previous) {
		return nil
	}
	if !legacyEnvironmentValueMatches(current, present, written) {
		return fmt.Errorf("无法确认旧共享 daemon 环境变量 %s 仍由 Mimi 持有；已保留 ownership 账本和遗留文件", key)
	}
	if err := requireLegacyDesktopStopped(ctx); err != nil {
		return err
	}
	if err := restoreLaunchctlValue(ctx, key, previous); err != nil {
		return err
	}
	current, present, err = launchctlGetenv(ctx, key)
	if err != nil {
		return err
	}
	if !legacyEnvironmentValueMatches(current, present, previous) {
		return legacyDesktopRestoreStateError()
	}
	return verifyLegacyDesktopEpoch(ctx, ledger)
}

func verifyLegacyDesktopEpoch(ctx context.Context, ledger legacyDesktopLedger) error {
	epoch, present, err := launchctlGetenv(ctx, legacyEpochEnvKey)
	if err != nil {
		return err
	}
	if !ledger.ownsEpoch || ledger.writtenEpoch == "" || !present || epoch != ledger.writtenEpoch {
		return legacyDesktopOwnershipError()
	}
	return nil
}

func verifyRestoredLegacyDesktopValues(ctx context.Context, ledger legacyDesktopLedger) error {
	for _, value := range []struct {
		key      string
		previous string
		owned    bool
	}{
		{legacyDaemonEnvKey, ledger.previousDaemon, ledger.ownsDaemon},
		{legacyCodexHomeEnvKey, ledger.previousHome, ledger.ownsHome},
	} {
		if !value.owned {
			continue
		}
		current, present, err := launchctlGetenv(ctx, value.key)
		if err != nil {
			return err
		}
		if !legacyEnvironmentValueMatches(current, present, value.previous) {
			return legacyDesktopRestoreStateError()
		}
	}
	return nil
}

func validateOwnedLegacyEnvironmentValue(
	key, written, previous, current string,
	present, owned, allowRestored bool,
) error {
	if !owned {
		return nil
	}
	if strings.TrimSpace(written) == "" {
		return legacyDesktopOwnershipError()
	}
	if legacyEnvironmentValueMatches(current, present, written) {
		return nil
	}
	if allowRestored && legacyEnvironmentValueMatches(current, present, previous) {
		return nil
	}
	return fmt.Errorf("无法确认旧共享 daemon 环境变量 %s 仍由 Mimi 持有；已保留 ownership 账本和遗留文件", key)
}

func legacyEnvironmentValueMatches(current string, present bool, expected string) bool {
	if expected == "" {
		return !present
	}
	return present && current == expected
}

func legacyDesktopOwnershipError() error {
	return fmt.Errorf("无法确认旧共享 daemon 环境变量仍由 Mimi 持有；已保留 ownership 账本和遗留文件")
}

func legacyDesktopRestoreStateError() error {
	return fmt.Errorf("旧共享 daemon 环境变量恢复状态无法确认；已保留 ownership 账本和遗留文件")
}

func writeLegacyDesktopCleanupPhase(ctx context.Context, phase string) error {
	if _, err := runDesktopSyncLegacyCommand(ctx, "/usr/bin/defaults", "write", legacyDefaultsDomain, legacyCleanupPhaseKey, "-string", phase); err != nil {
		return fmt.Errorf("记录旧共享 daemon 清理进度失败：%w", err)
	}
	return nil
}

func validateDesktopSyncLegacyFiles(paths []string, ownershipMatches bool) (map[string]legacyDesktopFileIdentity, error) {
	identities := make(map[string]legacyDesktopFileIdentity)
	for _, path := range paths {
		identity, present, err := validateDesktopSyncLegacyFile(path, ownershipMatches)
		if err != nil {
			return nil, err
		}
		if !present {
			continue
		}
		identities[path] = identity
	}
	return identities, nil
}

func validateDesktopSyncLegacyFile(path string, ownershipMatches bool) (legacyDesktopFileIdentity, bool, error) {
	return validateDesktopSyncLegacyFileAs(path, filepath.Base(path), ownershipMatches)
}

func validateDesktopSyncLegacyFileAs(
	path string,
	expectedName string,
	ownershipMatches bool,
) (legacyDesktopFileIdentity, bool, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return legacyDesktopFileIdentity{}, false, nil
	}
	if err != nil {
		return legacyDesktopFileIdentity{}, false, fmt.Errorf("检查旧共享 daemon 文件失败：%w", err)
	}
	if !ownershipMatches {
		return legacyDesktopFileIdentity{}, false, fmt.Errorf("缺少匹配的 ownership 账本，拒绝删除旧共享 daemon 文件：%s", filepath.Base(path))
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
		return legacyDesktopFileIdentity{}, false, fmt.Errorf("旧共享 daemon 文件 ownership 无法确认：%s", filepath.Base(path))
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return legacyDesktopFileIdentity{}, false, fmt.Errorf("安全打开旧共享 daemon 文件失败：%w", err)
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil {
		return legacyDesktopFileIdentity{}, false, fmt.Errorf("检查旧共享 daemon 文件身份失败：%w", err)
	}
	stat, ok := openedInfo.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return legacyDesktopFileIdentity{}, false, fmt.Errorf("旧共享 daemon 文件不属于当前用户：%s", filepath.Base(path))
	}
	identity := legacyDesktopFileIdentity{device: uint64(stat.Dev), inode: uint64(stat.Ino)}
	lstat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || identity != (legacyDesktopFileIdentity{device: uint64(lstat.Dev), inode: uint64(lstat.Ino)}) {
		return legacyDesktopFileIdentity{}, false, fmt.Errorf("旧共享 daemon 文件在打开前被替换：%s", filepath.Base(path))
	}
	payload, err := io.ReadAll(file)
	if err != nil {
		return legacyDesktopFileIdentity{}, false, fmt.Errorf("读取旧共享 daemon 文件失败：%w", err)
	}
	switch expectedName {
	case legacyLaunchAgentLabel + ".plist":
		text := string(payload)
		if !strings.Contains(text, "<string>"+legacyLaunchAgentLabel+"</string>") ||
			!strings.Contains(text, "<string>--codex-daemon-supervisor</string>") {
			return legacyDesktopFileIdentity{}, false, fmt.Errorf("旧共享 daemon plist 已被替换，拒绝删除")
		}
	case "codex-shared-daemon-migration-required":
		if string(payload) != "restart-required\n" {
			return legacyDesktopFileIdentity{}, false, fmt.Errorf("旧共享 daemon 迁移标记已被替换，拒绝删除")
		}
	case "codex-shared-daemon-enable-prepared":
		if string(payload) != "enable-prepared\n" {
			return legacyDesktopFileIdentity{}, false, fmt.Errorf("旧共享 daemon 启用标记已被替换，拒绝删除")
		}
	case legacyOperationLockName:
		if len(payload) != 0 {
			return legacyDesktopFileIdentity{}, false, fmt.Errorf("旧共享 daemon 操作锁已被替换，拒绝删除")
		}
	}
	return identity, true, nil
}

func removeValidatedDesktopSyncLegacyFile(
	path string,
	expected legacyDesktopFileIdentity,
	ownershipMatches bool,
) error {
	quarantine := path + ".mimi-cleanup"
	if err := finishLegacyDesktopQuarantine(path, quarantine, ownershipMatches); err != nil {
		return err
	}
	identity, present, err := validateDesktopSyncLegacyFile(path, ownershipMatches)
	if err != nil {
		return err
	}
	if !present {
		return nil
	}
	if expected == (legacyDesktopFileIdentity{}) || expected != identity {
		return fmt.Errorf("旧共享 daemon 文件在验证后发生变化，拒绝删除：%s", filepath.Base(path))
	}
	// 先原子移到 Mimi 专用隔离名，再核对 inode。即使原路径在校验后被
	// 外部进程替换，也只会被移走并恢复，不会误删外部文件。
	if err := unix.RenamexNp(path, quarantine, unix.RENAME_EXCL); err != nil {
		return fmt.Errorf("隔离旧共享 daemon 文件失败：%w", err)
	}
	moved, present, err := validateDesktopSyncLegacyFileAs(quarantine, filepath.Base(path), ownershipMatches)
	if err != nil || !present || moved != expected {
		restoreErr := unix.RenamexNp(quarantine, path, unix.RENAME_EXCL)
		if restoreErr != nil {
			return fmt.Errorf("旧共享 daemon 文件在隔离时发生变化；文件保留在 %s：%w", quarantine, restoreErr)
		}
		if err != nil {
			return err
		}
		return fmt.Errorf("旧共享 daemon 文件在隔离时发生变化，已恢复：%s", filepath.Base(path))
	}
	if err := os.Remove(quarantine); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("删除已隔离的旧共享 daemon 文件失败：%w", err)
	}
	return nil
}

func finishLegacyDesktopQuarantine(path, quarantine string, ownershipMatches bool) error {
	if _, err := os.Lstat(quarantine); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return fmt.Errorf("检查旧共享 daemon 隔离文件失败：%w", err)
	}
	if _, err := os.Lstat(path); err == nil {
		return fmt.Errorf("旧共享 daemon 原文件和隔离文件同时存在；已全部保留：%s", filepath.Base(path))
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("检查旧共享 daemon 原文件失败：%w", err)
	}
	if _, present, err := validateDesktopSyncLegacyFileAs(quarantine, filepath.Base(path), ownershipMatches); err != nil {
		return err
	} else if !present {
		return nil
	}
	if err := os.Remove(quarantine); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("删除已隔离的旧共享 daemon 文件失败：%w", err)
	}
	return nil
}

func launchctlGetenv(ctx context.Context, key string) (string, bool, error) {
	output, err := runDesktopSyncLegacyCommand(ctx, "/bin/launchctl", "getenv", key)
	if err != nil {
		if legacyLaunchctlEnvironmentMissing(key, string(output)+" "+err.Error()) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("读取旧 Desktop 环境变量失败（%s）：%w", key, err)
	}
	value := strings.TrimSpace(string(output))
	return value, value != "", nil
}

func legacyLaunchctlEnvironmentMissing(key string, output string) bool {
	value := strings.ToLower(strings.TrimSpace(output))
	if strings.Contains(value, "could not find environment variable") ||
		strings.Contains(value, "no such environment variable") ||
		strings.Contains(value, "environment variable not found") ||
		strings.Contains(value, "environment variable does not exist") {
		return true
	}
	key = strings.ToLower(strings.TrimSpace(key))
	return key != "" && strings.Contains(value, key) && strings.Contains(value, "environment variable") &&
		(strings.Contains(value, "not found") || strings.Contains(value, "does not exist"))
}

func restoreLaunchctlValue(ctx context.Context, key string, previous string) error {
	args := []string{"unsetenv", key}
	if previous != "" {
		args = []string{"setenv", key, previous}
	}
	if _, err := runDesktopSyncLegacyCommand(ctx, "/bin/launchctl", args...); err != nil {
		return fmt.Errorf("恢复旧 Desktop 环境变量失败（%s）：%w", key, err)
	}
	return nil
}

func validateLegacyDesktopLaunchJob(
	ctx context.Context,
	jobTarget string,
	plistPath string,
	plistPresent bool,
) (bool, error) {
	output, err := runDesktopSyncLegacyCommand(ctx, "/bin/launchctl", "print", jobTarget)
	combined := string(output)
	if err != nil {
		if legacyLaunchctlMissing(combined + " " + err.Error()) {
			return false, nil
		}
		return false, fmt.Errorf("检查旧共享 daemon LaunchAgent 失败：%w", err)
	}
	if strings.TrimSpace(combined) == "" {
		return false, nil
	}
	if !plistPresent || strings.TrimSpace(plistPath) == "" {
		return false, fmt.Errorf("旧共享 daemon LaunchAgent 仍已加载，但固定 plist 不存在；拒绝卸载")
	}
	if !strings.Contains(combined, "path = "+plistPath) ||
		!strings.Contains(combined, "--codex-daemon-supervisor") ||
		!strings.Contains(combined, legacyLaunchAgentLabel) {
		return false, fmt.Errorf("已加载的旧共享 daemon LaunchAgent 身份不匹配；拒绝卸载")
	}
	return true, nil
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
		// 保留在最后，作为 epoch 已清除后的可恢复证据。
		legacyCleanupPhaseKey,
	}
}
