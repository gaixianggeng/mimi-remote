//go:build !windows

package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestResolveCodexSharingTargetTreatsEmptyPathAsPlatformDefault(t *testing.T) {
	clearSetupEnv(t)
	resolved, platformDefault, err := resolveCodexSharingTarget("", false)
	if err != nil {
		t.Fatal(err)
	}
	if !platformDefault || !config.SameConfigPath(resolved, config.PlatformDefaultPath()) {
		t.Fatalf("空路径必须解析到平台默认配置并使用默认 owner 事务：path=%q default=%t", resolved, platformDefault)
	}
}

func TestStableSharedDaemonTargetAllowsLegacyCustomDisable(t *testing.T) {
	customPath := filepath.Join(t.TempDir(), "legacy-custom.json")
	if err := validateStableSharedDaemonTarget(customPath, false); err != nil {
		t.Fatalf("升级后必须允许 custom/非 macOS 旧 shared 配置回退：%v", err)
	}
	if err := validateStableSharedDaemonTarget(customPath, true); err == nil {
		t.Fatal("完整 stable-owner 共享不能继续从 custom profile 启用")
	}
}

func TestConfigureCodexSharingRoundTripsLegacyFallback(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, original := writeCodexSharingTestConfig(t)
	ensureCalls := 0
	ensure := func(_ context.Context, options appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
		ensureCalls++
		if options.CodexBin != "/test/codex" || options.Env["CODEX_HOME"] != codexHome {
			t.Fatalf("daemon options 未沿用 Codex 配置：%+v", options)
		}
		if !options.StableOwner || !options.PrepareOwnerForConfigCommit || options.RollbackOwnerOnFailure || options.AttachOnly {
			t.Fatalf("Mimi 从 WS 切换时必须使用 manual owner 两阶段事务：%+v", options)
		}
		return appserver.LocalDaemonStatus{
			SocketPath:             filepath.Join(codexHome, "app-server-control", "app-server-control.sock"),
			Version:                "0.147.0",
			OwnerInstalled:         true,
			OwnerCreated:           true,
			OwnerMigrationRequired: true,
		}, nil
	}

	lifecycle := recoverableLifecycleInspector(t, codexHome)
	enabled, err := configureCodexSharing(context.Background(), configPath, true, ensure, lifecycle, noopRemoveSharedDaemonOwner)
	if err != nil {
		t.Fatal(err)
	}
	if ensureCalls != 1 || !enabled.Enabled || !enabled.Changed || !enabled.RestartRequired ||
		!enabled.DaemonRestartRequired || enabled.Transport != "unix" || enabled.CodexHome != codexHome {
		t.Fatalf("启用结果错误：calls=%d result=%+v", ensureCalls, enabled)
	}
	document := readCodexSharingTestDocument(t, configPath)
	appServer := document["app_server"].(map[string]any)
	if appServer["transport"] != "unix" || appServer["listen"] != "unix://" || appServer["future_option"] != "keep" {
		t.Fatalf("共享配置或未知字段丢失：%+v", appServer)
	}
	fallback, ok := appServer["shared_fallback"].(map[string]any)
	if !ok || fallback["transport"] != "ws" || fallback["listen"] != "ws://127.0.0.1:4555" || fallback["ws_token_file"] != "/tmp/upstream-token" {
		t.Fatalf("legacy fallback 未完整保存：%+v", appServer["shared_fallback"])
	}

	removeCalls := 0
	disabled, err := configureCodexSharing(
		context.Background(),
		configPath,
		false,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			t.Fatal("关闭共享不能启动或停止 daemon")
			return appserver.LocalDaemonStatus{}, nil
		},
		unexpectedLifecycleInspector(t),
		func(context.Context) error {
			removeCalls++
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if disabled.Enabled || !disabled.Changed || !disabled.RestartRequired || disabled.Transport != "ws" || removeCalls != 1 {
		t.Fatalf("关闭结果错误：%+v", disabled)
	}
	restored := readCodexSharingTestDocument(t, configPath)
	restoredAppServer := restored["app_server"].(map[string]any)
	if restoredAppServer["transport"] != "ws" || restoredAppServer["listen"] != "ws://127.0.0.1:4555" || restoredAppServer["future_option"] != "keep" {
		t.Fatalf("关闭后未恢复 legacy 配置：%+v", restoredAppServer)
	}
	if _, exists := restoredAppServer["shared_fallback"]; exists {
		t.Fatalf("关闭后必须清除 shared_fallback：%+v", restoredAppServer)
	}
	if restored["future_root"] != original["future_root"] {
		t.Fatalf("顶层未知字段被改写：want=%v got=%v", original["future_root"], restored["future_root"])
	}
}

func TestConfigureCodexSharingUsesProductionValidatedLifecycleStatus(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	socketPath := filepath.Join(codexHome, "app-server-control", "app-server-control.sock")

	result, err := configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{
				SocketPath:             socketPath,
				Version:                "0.147.0",
				OwnerInstalled:         true,
				OwnerChanged:           true,
				OwnerMigrationRequired: true,
				LifecycleValidated:     true,
			}, nil
		},
		unexpectedLifecycleInspector(t),
		noopRemoveSharedDaemonOwner,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Changed || !result.DaemonRestartRequired || result.CodexHome != codexHome {
		t.Fatalf("生产校验状态必须跳过重复 CLI 检查并保留 owner 结果：%+v", result)
	}
}

func TestConfigureCodexSharingOwnerRemovalFailureRestoresSharedConfig(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	ensure := func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
		return appserver.LocalDaemonStatus{
			SocketPath: filepath.Join(codexHome, "app-server-control", "app-server-control.sock"),
			Version:    "0.147.0",
		}, nil
	}
	lifecycle := recoverableLifecycleInspector(t, codexHome)
	if _, err := configureCodexSharing(
		context.Background(), configPath, true, ensure, lifecycle, noopRemoveSharedDaemonOwner,
	); err != nil {
		t.Fatal(err)
	}
	beforeDisable, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	wantErr := errors.New("launchctl bootout denied")
	_, err = configureCodexSharing(
		context.Background(),
		configPath,
		false,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			t.Fatal("关闭共享不能重新确保 daemon")
			return appserver.LocalDaemonStatus{}, nil
		},
		unexpectedLifecycleInspector(t),
		func(context.Context) error { return wantErr },
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("应返回 owner 卸载错误：%v", err)
	}
	afterFailure, readErr := os.ReadFile(configPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(beforeDisable, afterFailure) {
		t.Fatal("owner 卸载失败时必须恢复原 shared 配置")
	}
}

func TestConfigureCodexSharingDisabledRetryCleansResidualOwner(t *testing.T) {
	clearSetupEnv(t)
	configPath, _, _ := writeCodexSharingTestConfig(t)
	removeCalls := 0
	result, err := configureCodexSharing(
		context.Background(),
		configPath,
		false,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			t.Fatal("已是 WS 配置时不能启动或探测 daemon")
			return appserver.LocalDaemonStatus{}, nil
		},
		unexpectedLifecycleInspector(t),
		func(context.Context) error {
			removeCalls++
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || result.Changed || result.RestartRequired || result.Transport != "ws" || removeCalls != 1 {
		t.Fatalf("禁用重试必须幂等清理残留 owner：calls=%d result=%+v", removeCalls, result)
	}
}

func TestRestartCodexSharingDaemonRequiresMimiOwnedSharedConfig(t *testing.T) {
	clearSetupEnv(t)
	configPath, _, _ := writeCodexSharingTestConfig(t)
	_, err := restartCodexSharingDaemon(
		context.Background(),
		configPath,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			t.Fatal("独立 WS 配置不能重启共享 daemon")
			return appserver.LocalDaemonStatus{}, nil
		},
	)
	if err == nil || !strings.Contains(err.Error(), "不是 Mimi 管理") {
		t.Fatalf("应拒绝非 Mimi owner：%v", err)
	}
}

func TestRestartCodexSharingDaemonReturnsAtomicRestartResult(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	socketPath := filepath.Join(codexHome, "app-server-control", "app-server-control.sock")
	lifecycle := recoverableLifecycleInspector(t, codexHome)
	if _, err := configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{SocketPath: socketPath, Version: "0.147.0", Started: true}, nil
		},
		lifecycle,
		noopRemoveSharedDaemonOwner,
	); err != nil {
		t.Fatal(err)
	}
	restartCalls := 0
	result, err := restartCodexSharingDaemon(
		context.Background(),
		configPath,
		func(_ context.Context, options appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			restartCalls++
			if options.CodexBin != "/test/codex" || options.Env["CODEX_HOME"] != codexHome {
				t.Fatalf("重启必须沿用现有 Codex 配置：%+v", options)
			}
			if options.ValidateStableOwner == nil {
				t.Fatal("显式重启必须在 appserver 跨进程锁内重新验证磁盘配置")
			}
			return appserver.LocalDaemonStatus{SocketPath: socketPath, Version: "0.147.0", Started: true}, nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if restartCalls != 1 || !result.Restarted || result.SocketPath != socketPath || result.Version != "0.147.0" {
		t.Fatalf("重启结果错误：calls=%d result=%+v", restartCalls, result)
	}
}

func TestRestartCodexSharingDaemonIgnoresUnavailableScanRoot(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	socketPath := filepath.Join(codexHome, "app-server-control", "app-server-control.sock")
	if _, err := configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{SocketPath: socketPath, Version: "0.147.0", Started: true}, nil
		},
		recoverableLifecycleInspector(t, codexHome),
		noopRemoveSharedDaemonOwner,
	); err != nil {
		t.Fatal(err)
	}
	document := readCodexSharingTestDocument(t, configPath)
	document["scan_roots"] = []string{filepath.Join(t.TempDir(), "offline-volume")}
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	restartCalls := 0
	result, err := restartCodexSharingDaemon(
		context.Background(),
		configPath,
		func(_ context.Context, options appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			restartCalls++
			if options.ValidateStableOwner == nil {
				t.Fatal("迁移仍必须在 daemon 锁内复核配置所有权")
			}
			if err := options.ValidateStableOwner(); err != nil {
				t.Fatalf("离线 scan_root 不能阻断锁内 owner 复核：%v", err)
			}
			return appserver.LocalDaemonStatus{SocketPath: socketPath, Version: "0.147.0", Started: true}, nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if restartCalls != 1 || !result.Restarted {
		t.Fatalf("离线 scan_root 不应阻止显式迁移：calls=%d result=%+v", restartCalls, result)
	}
}

func TestConfigureCodexSharingDaemonFailureDoesNotWriteConfig(t *testing.T) {
	clearSetupEnv(t)
	configPath, _, _ := writeCodexSharingTestConfig(t)
	before, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	wantErr := errors.New("daemon unavailable")
	_, err = configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{}, wantErr
		},
		unexpectedLifecycleInspector(t),
		noopRemoveSharedDaemonOwner,
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("应原样返回 daemon 错误：%v", err)
	}
	after, readErr := os.ReadFile(configPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("daemon 未就绪时不能提前修改配置")
	}
}

func TestConfigureCodexSharingReturnsCommittedPendingResultAfterPostCommitStartFailure(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	socketPath := filepath.Join(codexHome, "app-server-control", "app-server-control.sock")
	wantErr := errors.New("launchctl kickstart failed")
	result, err := configureCodexSharingWithTransactions(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			t.Fatal("production commit helper should own fresh enable")
			return appserver.LocalDaemonStatus{}, nil
		},
		unexpectedLifecycleInspector(t),
		noopRemoveSharedDaemonOwner,
		func(
			_ context.Context,
			_ appserver.LocalDaemonOptions,
			validate func() error,
			commit func() error,
		) (appserver.LocalDaemonStatus, error) {
			if err := validate(); err != nil {
				return appserver.LocalDaemonStatus{}, err
			}
			if err := commit(); err != nil {
				return appserver.LocalDaemonStatus{}, err
			}
			return appserver.LocalDaemonStatus{
				SocketPath:             socketPath,
				OwnerMigrationRequired: true,
				ConfigCommitted:        true,
			}, wantErr
		},
		func(context.Context, func() error, func() error) error {
			t.Fatal("enable path must not call disable transaction")
			return nil
		},
	)
	if err != nil {
		t.Fatalf("提交后的启动失败不能丢失机器可读结果：%v", err)
	}
	if !result.Enabled || !result.Changed || !result.RestartRequired ||
		!result.DaemonRestartRequired || result.Transport != "unix" ||
		result.CodexHome != codexHome || !strings.Contains(result.Warning, wantErr.Error()) {
		t.Fatalf("已提交失败必须返回 pending+warning：%+v", result)
	}
	document := readCodexSharingTestDocument(t, configPath)
	appServer := document["app_server"].(map[string]any)
	if appServer["transport"] != "unix" || appServer["shared_fallback"] == nil {
		t.Fatalf("机器结果必须匹配已经提交的 shared 配置：%+v", appServer)
	}
}

func TestConfigureCodexSharingAlreadyEnabledStillVerifiesDaemon(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	firstEnsure := func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
		return appserver.LocalDaemonStatus{
			SocketPath: filepath.Join(codexHome, "app-server-control", "app-server-control.sock"),
			Version:    "0.147.0",
		}, nil
	}
	lifecycle := recoverableLifecycleInspector(t, codexHome)
	if _, err := configureCodexSharing(context.Background(), configPath, true, firstEnsure, lifecycle, noopRemoveSharedDaemonOwner); err != nil {
		t.Fatal(err)
	}
	verified := false
	result, err := configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			verified = true
			return appserver.LocalDaemonStatus{
				SocketPath: filepath.Join(codexHome, "app-server-control", "app-server-control.sock"),
				Version:    "0.147.0",
			}, nil
		},
		lifecycle,
		noopRemoveSharedDaemonOwner,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !verified || result.Changed || result.RestartRequired || !result.Enabled || result.CodexHome != codexHome {
		t.Fatalf("已启用时仍应验证 daemon，但无需重写配置：verified=%t result=%+v", verified, result)
	}
}

func TestConcurrentStaleEnableCannotRecreateOwnerAfterDisable(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	socketPath := filepath.Join(codexHome, "app-server-control", "app-server-control.sock")
	lifecycle := recoverableLifecycleInspector(t, codexHome)
	if _, err := configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{SocketPath: socketPath, Version: "0.147.0"}, nil
		},
		lifecycle,
		noopRemoveSharedDaemonOwner,
	); err != nil {
		t.Fatal(err)
	}

	staleRead := make(chan struct{})
	releaseEnsure := make(chan struct{})
	enableDone := make(chan error, 1)
	go func() {
		_, err := configureCodexSharing(
			context.Background(),
			configPath,
			true,
			func(_ context.Context, options appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
				if options.ValidateStableOwner == nil {
					return appserver.LocalDaemonStatus{}, fmt.Errorf("已 shared 的幂等 enable 缺少锁内配置复核")
				}
				close(staleRead)
				<-releaseEnsure
				if err := options.ValidateStableOwner(); err != nil {
					return appserver.LocalDaemonStatus{}, err
				}
				return appserver.LocalDaemonStatus{}, fmt.Errorf("stale enable 不应通过复核")
			},
			unexpectedLifecycleInspector(t),
			noopRemoveSharedDaemonOwner,
		)
		enableDone <- err
	}()
	<-staleRead

	if _, err := configureCodexSharing(
		context.Background(),
		configPath,
		false,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			t.Fatal("disable 不能 ensure daemon")
			return appserver.LocalDaemonStatus{}, nil
		},
		unexpectedLifecycleInspector(t),
		noopRemoveSharedDaemonOwner,
	); err != nil {
		t.Fatal(err)
	}
	close(releaseEnsure)
	if err := <-enableDone; err == nil || !strings.Contains(err.Error(), "已取消 Mimi 共享 daemon") {
		t.Fatalf("旧 enable 必须看到 disable 后的新磁盘配置并拒绝：%v", err)
	}
}

func TestConfigureCodexSharingUsesOneRawSnapshotForConfigDocumentAndCAS(t *testing.T) {
	clearSetupEnv(t)
	configPath, _, documentA := writeCodexSharingTestConfig(t)
	documentB := readCodexSharingTestDocument(t, configPath)
	codexHomeB := t.TempDir()
	documentB["codex"].(map[string]any)["bin"] = "/new/codex"
	documentB["codex"].(map[string]any)["env"] = map[string]string{
		"CODEX_HOME": codexHomeB,
		"TERM":       "xterm-256color",
	}
	documentB["future_root"] = "new-generation"
	rawA, err := json.MarshalIndent(documentA, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	rawB, err := json.MarshalIndent(documentB, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	rawA = append(rawA, '\n')
	rawB = append(rawB, '\n')

	originalRead := readCodexSharingConfigFile
	reads := 0
	readCodexSharingConfigFile = func(path string) ([]byte, error) {
		reads++
		if reads == 1 {
			return append([]byte(nil), rawA...), nil
		}
		return os.ReadFile(path)
	}
	t.Cleanup(func() { readCodexSharingConfigFile = originalRead })
	// 第一份快照读完后，模拟另一配置命令提交 B。旧请求的 validator 必须
	// 在任何 owner/daemon 变更前看到 bytes 已变化并拒绝。
	if err := os.WriteFile(configPath, rawB, 0o600); err != nil {
		t.Fatal(err)
	}
	ensureCalls := 0
	_, err = configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			ensureCalls++
			return appserver.LocalDaemonStatus{}, nil
		},
		unexpectedLifecycleInspector(t),
		noopRemoveSharedDaemonOwner,
	)
	if err == nil || !strings.Contains(err.Error(), "配置已被其他进程修改") {
		t.Fatalf("过期快照必须在 owner mutation 前失败：%v", err)
	}
	if ensureCalls != 0 {
		t.Fatalf("过期快照不能进入 daemon/owner 路径：%d", ensureCalls)
	}
	after, readErr := os.ReadFile(configPath)
	if readErr != nil || !bytes.Equal(after, rawB) {
		t.Fatalf("过期操作不能覆盖新配置：read=%v got=%s", readErr, after)
	}
}

func TestConfigureCodexSharingAlreadyEnabledReportsPendingOwnerMigration(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	socketPath := filepath.Join(codexHome, "app-server-control", "app-server-control.sock")
	lifecycle := recoverableLifecycleInspector(t, codexHome)
	if _, err := configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{SocketPath: socketPath, Version: "0.147.0"}, nil
		},
		lifecycle,
		noopRemoveSharedDaemonOwner,
	); err != nil {
		t.Fatal(err)
	}

	result, err := configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{
				SocketPath:             socketPath,
				Version:                "0.147.0",
				OwnerInstalled:         true,
				OwnerMigrationRequired: true,
				LifecycleValidated:     true,
			}, nil
		},
		unexpectedLifecycleInspector(t),
		noopRemoveSharedDaemonOwner,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !result.DaemonRestartRequired || !strings.Contains(result.Message, "迁移尚未完成") {
		t.Fatalf("非 JSON CLI 也必须明确显示待迁移：%+v", result)
	}
}

func TestConfigureCodexSharingKeepsExternalUnixBackendAndCleansOnlyMimiOwner(t *testing.T) {
	clearSetupEnv(t)
	configPath, _, _ := writeCodexSharingTestConfig(t)
	document := readCodexSharingTestDocument(t, configPath)
	appServer := document["app_server"].(map[string]any)
	appServer["transport"] = "unix"
	appServer["listen"] = "unix://"
	delete(appServer, "shared_fallback")
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}

	removeCalls := 0
	result, err := configureCodexSharing(
		context.Background(),
		configPath,
		false,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			t.Fatal("关闭外部 Unix backend 不应启动或探测 daemon")
			return appserver.LocalDaemonStatus{}, nil
		},
		unexpectedLifecycleInspector(t),
		func(context.Context) error {
			removeCalls++
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || result.Changed || result.RestartRequired || result.Transport != "unix" {
		t.Fatalf("外部 Unix backend 应保持原样：%+v", result)
	}
	if removeCalls != 1 {
		t.Fatalf("禁用外部 Unix 时只应幂等清理一次 Mimi 专属 owner：%d", removeCalls)
	}
	after, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("Mimi 未拥有 fallback 时，禁用不能改写外部 Unix 配置")
	}
}

func TestConfigureCodexSharingExternalUnixIsAttachOnly(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	document := readCodexSharingTestDocument(t, configPath)
	appServer := document["app_server"].(map[string]any)
	appServer["transport"] = " UnIx "
	appServer["managed"] = true
	appServer["listen"] = "unix://"
	delete(appServer, "shared_fallback")
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	ensureCalls := 0
	result, err := configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(_ context.Context, options appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			ensureCalls++
			if !options.AttachOnly || options.StableOwner {
				t.Fatalf("外部 Unix backend 只能 attach，不能安装 owner：%+v", options)
			}
			return appserver.LocalDaemonStatus{
				SocketPath: filepath.Join(codexHome, "app-server-control", "app-server-control.sock"),
				Version:    "0.147.0",
			}, nil
		},
		unexpectedLifecycleInspector(t),
		func(context.Context) error {
			t.Fatal("外部 Unix backend 不能安装或移除 Mimi owner")
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if ensureCalls != 1 || !result.Enabled || result.Changed || result.RestartRequired ||
		result.DaemonRestartRequired || result.Transport != "unix" || result.CodexHome != codexHome {
		t.Fatalf("外部 Unix attach 结果错误：calls=%d result=%+v", ensureCalls, result)
	}
	after, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(raw, after) {
		t.Fatal("启用外部 Unix 共享不能改写配置")
	}
}

func TestConfigureCodexSharingRejectsMalformedFallbackBeforeMutation(t *testing.T) {
	clearSetupEnv(t)
	configPath, _, _ := writeCodexSharingTestConfig(t)
	document := readCodexSharingTestDocument(t, configPath)
	appServer := document["app_server"].(map[string]any)
	appServer["transport"] = "unix"
	appServer["listen"] = "unix://"
	appServer["shared_fallback"] = map[string]any{
		"transport": "ws",
		"managed":   true,
		"listen":    "ws://0.0.0.0:4222",
	}
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	_, err = configureCodexSharing(
		context.Background(),
		configPath,
		false,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			t.Fatal("非法 fallback 不应进入 daemon 路径")
			return appserver.LocalDaemonStatus{}, nil
		},
		unexpectedLifecycleInspector(t),
		noopRemoveSharedDaemonOwner,
	)
	if err == nil {
		t.Fatal("不可恢复的 shared_fallback 必须在修改前被拒绝")
	}
	after, readErr := os.ReadFile(configPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(raw, after) {
		t.Fatal("非法 fallback 被拒绝时不能修改配置")
	}
}

func TestConfigureCodexSharingRejectsDaemonWithoutColdStartLifecycle(t *testing.T) {
	clearSetupEnv(t)
	configPath, codexHome, _ := writeCodexSharingTestConfig(t)
	before, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(codexHome, "app-server-control", "app-server-control.sock")
	removeCalls := 0
	_, err = configureCodexSharing(
		context.Background(),
		configPath,
		true,
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{
				SocketPath:   socketPath,
				Version:      "0.147.0",
				OwnerChanged: true,
			}, nil
		},
		func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonLifecycleStatus, error) {
			return appserver.LocalDaemonLifecycleStatus{
				Status:           "running",
				SocketPath:       socketPath,
				AppServerVersion: "0.147.0",
				ManagedCodexPath: filepath.Join(codexHome, "packages", "standalone", "current", "codex"),
			}, nil
		},
		func(context.Context) error {
			removeCalls++
			return nil
		},
	)
	if !errors.Is(err, appserver.ErrLocalDaemonStandaloneMissing) {
		t.Fatalf("缺少 standalone 时必须阻止持久化共享配置：%v", err)
	}
	if removeCalls != 1 {
		t.Fatalf("前置校验失败时必须清理本次新建或更新的 owner：%d", removeCalls)
	}
	after, readErr := os.ReadFile(configPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("冷启动前置条件不完整时不能修改配置")
	}
}

func recoverableLifecycleInspector(
	t *testing.T,
	codexHome string,
) inspectLocalDaemonLifecycleFunc {
	t.Helper()
	managedCodex := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if err := os.MkdirAll(filepath.Dir(managedCodex), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(managedCodex, []byte("test"), 0o700); err != nil {
		t.Fatal(err)
	}
	version := "0.147.0"
	return func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonLifecycleStatus, error) {
		return appserver.LocalDaemonLifecycleStatus{
			Status:              "running",
			ManagedCodexPath:    managedCodex,
			ManagedCodexVersion: &version,
			SocketPath:          filepath.Join(codexHome, "app-server-control", "app-server-control.sock"),
			CLIVersion:          version,
			AppServerVersion:    version,
		}, nil
	}
}

func unexpectedLifecycleInspector(t *testing.T) inspectLocalDaemonLifecycleFunc {
	t.Helper()
	return func(context.Context, appserver.LocalDaemonOptions) (appserver.LocalDaemonLifecycleStatus, error) {
		t.Fatal("当前路径不应检查 daemon lifecycle")
		return appserver.LocalDaemonLifecycleStatus{}, nil
	}
}

func noopRemoveSharedDaemonOwner(context.Context) error { return nil }

func writeCodexSharingTestConfig(t *testing.T) (string, string, map[string]any) {
	t.Helper()
	project := t.TempDir()
	codexHome := t.TempDir()
	configPath := filepath.Join(t.TempDir(), "config.json")
	document := map[string]any{
		"auth":    map[string]any{"token": "0123456789abcdef0123456789abcdef"},
		"runtime": map[string]any{"type": "codex_app_server"},
		"app_server": map[string]any{
			"transport":     "ws",
			"managed":       true,
			"listen":        "ws://127.0.0.1:4555",
			"ws_token_file": "/tmp/upstream-token",
			"auto_title":    false,
			"future_option": "keep",
		},
		"codex": map[string]any{
			"bin":          "/test/codex",
			"default_args": []string{"--no-alt-screen"},
			"env":          map[string]string{"TERM": "xterm-256color", "CODEX_HOME": codexHome},
		},
		"session":     map[string]any{"output_buffer_bytes": 4096},
		"projects":    []map[string]any{{"id": "demo", "name": "Demo", "path": project}},
		"future_root": "keep-root",
	}
	raw, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	return configPath, codexHome, document
}

func readCodexSharingTestDocument(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	return document
}
