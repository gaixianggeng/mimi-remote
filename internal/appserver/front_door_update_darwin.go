//go:build darwin

package appserver

import (
	"context"
	"errors"
	"strings"
	"time"
)

// CodexRuntimeVersions 区分磁盘安装与实际握手的版本；版本差异本身不代表服务不可用。
type CodexRuntimeVersions struct {
	InstalledVersion string `json:"installed_version"`
	RunningVersion   string `json:"running_version"`
	UpdateAvailable  bool   `json:"update_available"`
	FeatureMismatch  bool   `json:"feature_mismatch"`
}

func (v CodexRuntimeVersions) needsRecovery() bool { return v.UpdateAvailable || v.FeatureMismatch }

func (f *FrontDoor) RuntimeVersions(ctx context.Context) (CodexRuntimeVersions, error) {
	bin := FrontDoorCodexBin(f.options.CodexBin, f.options.Env)
	installed, err := CheckLocalCodex(ctx, bin)
	if err != nil {
		return CodexRuntimeVersions{}, errors.New("无法检查已安装的 Codex，请运行诊断后重试。")
	}
	env := cloneStringMap(f.options.Env)
	if f.options.BackendCodexHome != "" {
		env["CODEX_HOME"] = f.backendHome
	}
	desired, err := configuredModelDiscovery(ctx, bin, env)
	if err != nil {
		return CodexRuntimeVersions{}, err
	}
	// 状态读取只访问私有 socket，不能因打开菜单而启动或替换用户后台。
	running, enabled, err := frontDoorRuntimeState(ctx, f.backend, f.backendHome, f.options.BackendCodexHome != "", desired != nil)
	if err != nil {
		return CodexRuntimeVersions{}, errors.New("暂时无法读取正在使用的 Codex 版本或功能设置，请刷新或运行诊断。")
	}
	return CodexRuntimeVersions{
		InstalledVersion: installed, RunningVersion: running,
		UpdateAvailable: CompareCodexVersions(installed, running) > 0,
		FeatureMismatch: desired != nil && *desired != enabled,
	}, nil
}

func frontDoorRuntimeVersion(ctx context.Context, socket, expectedHome string, requireHome bool) (string, error) {
	version, _, err := frontDoorRuntimeState(ctx, socket, expectedHome, requireHome, false)
	return version, err
}

func frontDoorRuntimeState(ctx context.Context, socket, expectedHome string, requireHome, inspectFeatures bool) (string, bool, error) {
	transport := &SharedLocalTransport{socket: socket}
	dialer, err := transport.rawWebSocketDialer(frontDoorBackendReadyTimeout)
	if err != nil {
		return "", false, err
	}
	url, err := transport.WebSocketURL()
	if err != nil {
		return "", false, err
	}
	conn, response, err := dialer.DialContext(ctx, url, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return "", false, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	result, err := initializeWebSocketResult(ctx, conn)
	if err != nil {
		return "", false, err
	}
	// 默认目录沿用已有连接的旧版兼容规则；独立目录仍必须由后台明确报告身份。
	if err := validateExpectedBackendCodexHome(expectedHome, result.CodexHome, requireHome); err != nil {
		return "", false, err
	}
	// userAgent 的首段形如 codex/0.161.0，后面还可能包含 OS 版本。
	fields := strings.Fields(result.UserAgent)
	if len(fields) == 0 {
		return "", false, errors.New("Codex initialize 未返回版本")
	}
	_, raw, ok := strings.Cut(fields[0], "/")
	if !ok {
		return "", false, errors.New("Codex userAgent 版本格式无效")
	}
	version, ok := ParseCodexVersion(raw)
	if !ok {
		return "", false, errors.New("Codex userAgent 版本无法识别")
	}
	if inspectFeatures {
		enabled, err := runningModelDiscovery(conn)
		return version, enabled, err
	}
	return version, false, nil
}

type frontDoorUpdateOps struct {
	restart         bool
	versions        func(context.Context) (CodexRuntimeVersions, error)
	lock            func(context.Context) (func(), error)
	stop            func(context.Context) error
	reloadFrontDoor func(context.Context) error
	resume          func(context.Context) (string, error)
}

func (f *FrontDoor) UpdateRuntime(ctx context.Context, reloadFrontDoor func(context.Context) error) (CodexRuntimeVersions, error) {
	return f.updateRuntime(ctx, false, reloadFrontDoor)
}

// RestartRuntime 的调用者必须先取得用户对断连及任务中断的明确确认。
func (f *FrontDoor) RestartRuntime(ctx context.Context, reloadFrontDoor func(context.Context) error) (CodexRuntimeVersions, error) {
	return f.updateRuntime(ctx, true, reloadFrontDoor)
}

func (f *FrontDoor) updateRuntime(ctx context.Context, restart bool, reloadFrontDoor func(context.Context) error) (CodexRuntimeVersions, error) {
	return updateFrontDoorRuntime(ctx, frontDoorUpdateOps{
		restart:         restart,
		versions:        f.RuntimeVersions,
		reloadFrontDoor: reloadFrontDoor,
		lock: func(ctx context.Context) (func(), error) {
			if restart {
				// 允许已有连接由 Codex 主动断开，但阻止重连者抢先启动 replacement。
				// 必须等旧进程真正退出再释放启动锁，避免出现两个 writer。
				return lockFrontDoorFile(ctx, f.lockPath)
			}
			return f.LockMigration(ctx)
		},
		stop: func(ctx context.Context) error {
			if err := f.WaitForOrphans(ctx); err != nil {
				return err
			}
			if restart {
				return f.stopConfirmedBackend(ctx)
			}
			return f.StopIdleBackend(ctx)
		},
		// 由已登记的 Aqua 前门启动 replacement，管理命令不能自己启动并改变 TCC 授权主体。
		resume: func(ctx context.Context) (string, error) {
			return frontDoorRuntimeVersion(ctx, f.public, f.backendHome, f.options.BackendCodexHome != "")
		},
	})
}

func updateFrontDoorRuntime(ctx context.Context, ops frontDoorUpdateOps) (CodexRuntimeVersions, error) {
	before, err := ops.versions(ctx)
	if err != nil || !before.needsRecovery() {
		return before, err
	}
	// 连接未释放时快速给出操作指引，不停网关，不让按钮无限等待。
	lockCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	unlock, err := ops.lock(lockCtx)
	cancel()
	if err != nil {
		if ops.restart {
			return before, errors.New("Codex 后台正在启动或切换，请稍后重试。")
		}
		return before, errors.New("共享连接尚未断开，未执行切换。请按占用提示断开连接后重新检查；仅关闭聊天页面可能仍会保留连接。")
	}
	locked := true
	defer func() {
		if locked {
			unlock()
		}
	}()
	// 获锁后重读，避免另一次切换或 CLI 更新使点击时的版本失效。
	before, err = ops.versions(ctx)
	if err != nil || !before.needsRecovery() {
		return before, err
	}
	if err := ops.stop(ctx); err != nil {
		if ops.restart {
			return before, errors.New("未能确认 Codex 后台已安全退出，暂不启动新的后台。请重新检查或运行诊断。")
		}
		return before, errors.New("暂时无法安全切换 Codex。请等待任务和排队消息完成，关闭共享会话后重试；仍失败时请运行诊断。")
	}
	// 覆盖安装会保留旧前门进程。退出 backend 后、释放启动/迁移锁前换代前门，
	// 确保新后台由当前 App 的 Aqua 责任链启动，并真正应用本次修复的参数。
	// 原请求此时超时也必须完成有界恢复，不能留下旧前门再次启动未保护的后台。
	recoveryCtx, cancelRecovery := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
	defer cancelRecovery()
	if ops.reloadFrontDoor != nil {
		if err := ops.reloadFrontDoor(recoveryCtx); err != nil {
			return before, errors.New("Codex 后台已退出，但连接服务尚未重新加载。请重新检查或运行诊断；会话记录已保留。")
		}
	}
	unlock()
	locked = false
	if _, err := ops.resume(recoveryCtx); err != nil {
		return before, errors.New("Codex 后台已退出，但尚未重新连接成功。请刷新状态或运行诊断；会话记录已保留。")
	}
	after, err := ops.versions(recoveryCtx)
	if err == nil && after.FeatureMismatch {
		return before, errors.New("Codex 连接设置尚未恢复一致。请重新检查或运行诊断；会话记录已保留。")
	}
	if err != nil || after.needsRecovery() || after.InstalledVersion != after.RunningVersion {
		return before, errors.New("Codex 尚未完成版本切换。请刷新状态后重试；会话记录已保留。")
	}
	return after, nil
}
