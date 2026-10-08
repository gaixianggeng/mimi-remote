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
}

func (f *FrontDoor) RuntimeVersions(ctx context.Context) (CodexRuntimeVersions, error) {
	installed, err := CheckLocalCodex(ctx, FrontDoorCodexBin(f.options.CodexBin, f.options.Env))
	if err != nil {
		return CodexRuntimeVersions{}, errors.New("无法检查已安装的 Codex，请运行诊断后重试。")
	}
	// 状态读取只访问私有 socket，不能因打开菜单而启动或替换用户后台。
	running, err := frontDoorRuntimeVersion(ctx, f.backend, f.backendHome)
	if err != nil {
		return CodexRuntimeVersions{}, errors.New("暂时无法读取正在使用的 Codex 版本，请刷新或运行诊断。")
	}
	return CodexRuntimeVersions{
		InstalledVersion: installed, RunningVersion: running,
		UpdateAvailable: CompareCodexVersions(installed, running) > 0,
	}, nil
}

func frontDoorRuntimeVersion(ctx context.Context, socket, expectedHome string) (string, error) {
	transport := &SharedLocalTransport{socket: socket}
	dialer, err := transport.rawWebSocketDialer(frontDoorBackendReadyTimeout)
	if err != nil {
		return "", err
	}
	url, err := transport.WebSocketURL()
	if err != nil {
		return "", err
	}
	conn, response, err := dialer.DialContext(ctx, url, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return "", err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	result, err := initializeWebSocketResult(ctx, conn)
	if err != nil {
		return "", err
	}
	if err := validateExpectedBackendCodexHome(expectedHome, result.CodexHome, true); err != nil {
		return "", err
	}
	// userAgent 的首段形如 codex/0.161.0，后面还可能包含 OS 版本。
	fields := strings.Fields(result.UserAgent)
	if len(fields) == 0 {
		return "", errors.New("Codex initialize 未返回版本")
	}
	_, raw, ok := strings.Cut(fields[0], "/")
	if !ok {
		return "", errors.New("Codex userAgent 版本格式无效")
	}
	version, ok := ParseCodexVersion(raw)
	if !ok {
		return "", errors.New("Codex userAgent 版本无法识别")
	}
	return version, nil
}

type frontDoorUpdateOps struct {
	versions func(context.Context) (CodexRuntimeVersions, error)
	lock     func(context.Context) (func(), error)
	stop     func(context.Context) error
	resume   func(context.Context) (string, error)
}

func (f *FrontDoor) UpdateRuntime(ctx context.Context) (CodexRuntimeVersions, error) {
	return updateFrontDoorRuntime(ctx, frontDoorUpdateOps{
		versions: f.RuntimeVersions,
		lock:     f.LockMigration,
		stop: func(ctx context.Context) error {
			if err := f.WaitForOrphans(ctx); err != nil {
				return err
			}
			return f.StopIdleBackend(ctx)
		},
		// 由已登记的 Aqua 前门启动 replacement，管理命令不能自己启动并改变 TCC 授权主体。
		resume: func(ctx context.Context) (string, error) {
			return frontDoorRuntimeVersion(ctx, f.public, f.backendHome)
		},
	})
}

func updateFrontDoorRuntime(ctx context.Context, ops frontDoorUpdateOps) (CodexRuntimeVersions, error) {
	before, err := ops.versions(ctx)
	if err != nil || !before.UpdateAvailable {
		return before, err
	}
	// 连接未释放时快速给出操作指引，不停网关，不让按钮无限等待。
	lockCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	unlock, err := ops.lock(lockCtx)
	cancel()
	if err != nil {
		return before, errors.New("Codex 仍有共享连接。请结束任务，离开手机或平板上的会话，并关闭终端和 Desktop 共享页面后重试。")
	}
	locked := true
	defer func() {
		if locked {
			unlock()
		}
	}()
	// 获锁后重读，避免另一次切换或 CLI 更新使点击时的版本失效。
	before, err = ops.versions(ctx)
	if err != nil || !before.UpdateAvailable {
		return before, err
	}
	if err := ops.stop(ctx); err != nil {
		return before, errors.New("暂时无法安全切换 Codex。请等待任务和排队消息完成，关闭共享会话后重试；仍失败时请运行诊断。")
	}
	unlock()
	locked = false
	if _, err := ops.resume(ctx); err != nil {
		return before, errors.New("旧版 Codex 已退出，新版尚未连接成功。请刷新状态或运行诊断；会话记录已保留。")
	}
	after, err := ops.versions(ctx)
	if err != nil || after.InstalledVersion != after.RunningVersion {
		return before, errors.New("Codex 尚未完成版本切换。请刷新状态后重试；会话记录已保留。")
	}
	return after, nil
}
