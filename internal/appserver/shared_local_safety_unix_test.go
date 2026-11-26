//go:build linux || darwin

package appserver

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func overrideSharedLocalSafetyHooks(
	t *testing.T,
	enabled bool,
	daemonDir string,
	uid uint32,
	lstat sharedLocalLstatFunc,
) {
	t.Helper()
	origEnabled := sharedLocalDirCheckEnabled
	origUID := sharedLocalCurrentUID
	origDaemonDir := sharedLocalLinuxDaemonDir
	origMarkerPath := sharedLocalUnsafeMarkerPath
	origLstat := sharedLocalLstat
	origReadlink := sharedLocalReadlink
	t.Cleanup(func() {
		sharedLocalDirCheckEnabled = origEnabled
		sharedLocalCurrentUID = origUID
		sharedLocalLinuxDaemonDir = origDaemonDir
		sharedLocalUnsafeMarkerPath = origMarkerPath
		sharedLocalLstat = origLstat
		sharedLocalReadlink = origReadlink
	})
	sharedLocalDirCheckEnabled = enabled
	sharedLocalCurrentUID = func() uint32 { return uid }
	sharedLocalLinuxDaemonDir = func() string { return daemonDir }
	sharedLocalUnsafeMarkerPath = func() string { return "" }
	if lstat != nil {
		sharedLocalLstat = lstat
	}
}

func TestSharedLocalSafetyRejectsUnsafeDaemonDir(t *testing.T) {
	const currentUID uint32 = 1000
	cases := []struct {
		name        string
		setup       func(t *testing.T, root string) (daemonDir string, lstat sharedLocalLstatFunc)
		wantContain string
	}{
		{
			name: "symlink",
			setup: func(t *testing.T, root string) (string, sharedLocalLstatFunc) {
				target := filepath.Join(root, "real-dir")
				if err := os.Mkdir(target, 0o700); err != nil {
					t.Fatal(err)
				}
				link := filepath.Join(root, "codex-daemon-1000")
				if err := os.Symlink(target, link); err != nil {
					t.Fatal(err)
				}
				return link, func(path string) (os.FileInfo, uint32, error) {
					info, err := os.Lstat(path)
					return info, currentUID, err
				}
			},
			wantContain: "是符号链接",
		},
		{
			name: "regular_file",
			setup: func(t *testing.T, root string) (string, sharedLocalLstatFunc) {
				file := filepath.Join(root, "codex-daemon-1000")
				if err := os.WriteFile(file, []byte("occupant"), 0o600); err != nil {
					t.Fatal(err)
				}
				return file, func(path string) (os.FileInfo, uint32, error) {
					info, err := os.Lstat(path)
					return info, currentUID, err
				}
			},
			wantContain: "不是目录",
		},
		{
			name: "wrong_owner",
			setup: func(t *testing.T, root string) (string, sharedLocalLstatFunc) {
				dir := filepath.Join(root, "codex-daemon-1000")
				if err := os.Mkdir(dir, 0o700); err != nil {
					t.Fatal(err)
				}
				return dir, func(path string) (os.FileInfo, uint32, error) {
					info, err := os.Lstat(path)
					if err != nil {
						return nil, 0, err
					}
					if filepath.Clean(path) == filepath.Clean(dir) {
						return info, currentUID + 1, nil
					}
					return info, currentUID, nil
				}
			},
			wantContain: "属主",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			codexHome := shortSharedLocalCodexHome(t)
			socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
			stop := startSharedLocalTestServer(t, socket)
			defer stop()

			daemonDir, lstat := tc.setup(t, filepath.Dir(codexHome))
			overrideSharedLocalSafetyHooks(t, true, daemonDir, currentUID, lstat)

			transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
			if err != nil {
				t.Fatal(err)
			}
			var started atomic.Int32
			transport.startOnce = func(context.Context, SharedLocalOptions) error {
				started.Add(1)
				return nil
			}

			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			err = transport.EnsureReady(ctx)
			if err == nil || !strings.Contains(err.Error(), "共享 Codex 目录") || !strings.Contains(err.Error(), tc.wantContain) || !strings.Contains(err.Error(), "已忽略") {
				t.Fatalf("EnsureReady 应拒绝不安全目录(%s)，got %v", tc.wantContain, err)
			}
			if started.Load() != 0 {
				t.Fatalf("不安全目录不得触发启动 resident：starts=%d", started.Load())
			}

			dialer, err := transport.WebSocketDialer(time.Second)
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := dialer.DialContext(ctx, sharedLocalHandshakeURL, nil); err == nil || !strings.Contains(err.Error(), tc.wantContain) {
				t.Fatalf("WebSocketDialer 应在不安全目录时直接拒绝连接，got %v", err)
			}
		})
	}
}

func TestSharedLocalSafetyRejectsUnsafeSocketSymlinkTargetDir(t *testing.T) {
	const currentUID uint32 = 1000
	cases := []struct {
		name        string
		setup       func(t *testing.T, root, socket string) (daemonDir string, lstat sharedLocalLstatFunc)
		wantContain string
	}{
		{
			name: "target_dir_is_symlink",
			setup: func(t *testing.T, root, socket string) (string, sharedLocalLstatFunc) {
				realDir := filepath.Join(root, "real")
				if err := os.Mkdir(realDir, 0o700); err != nil {
					t.Fatal(err)
				}
				linkDir := filepath.Join(root, "link-dir")
				if err := os.Symlink(realDir, linkDir); err != nil {
					t.Fatal(err)
				}
				if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(linkDir, "s.sock"), socket); err != nil {
					t.Fatal(err)
				}
				return filepath.Join(root, "absent-daemon-dir"), func(path string) (os.FileInfo, uint32, error) {
					info, err := os.Lstat(path)
					return info, currentUID, err
				}
			},
			wantContain: "是符号链接",
		},
		{
			name: "target_dir_wrong_owner",
			setup: func(t *testing.T, root, socket string) (string, sharedLocalLstatFunc) {
				otherDir := filepath.Join(root, "other-owner")
				if err := os.Mkdir(otherDir, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(otherDir, "s.sock"), socket); err != nil {
					t.Fatal(err)
				}
				return filepath.Join(root, "absent-daemon-dir"), func(path string) (os.FileInfo, uint32, error) {
					info, err := os.Lstat(path)
					if err != nil {
						return nil, 0, err
					}
					if filepath.Clean(path) == filepath.Clean(otherDir) {
						return info, currentUID + 42, nil
					}
					return info, currentUID, nil
				}
			},
			wantContain: "属主",
		},
		{
			name: "target_dir_missing",
			setup: func(t *testing.T, root, socket string) (string, sharedLocalLstatFunc) {
				if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(root, "missing-dir", "s.sock"), socket); err != nil {
					t.Fatal(err)
				}
				return filepath.Join(root, "absent-daemon-dir"), func(path string) (os.FileInfo, uint32, error) {
					info, err := os.Lstat(path)
					return info, currentUID, err
				}
			},
			wantContain: "目录不存在",
		},
		{
			name: "chained_symlink",
			setup: func(t *testing.T, root, socket string) (string, sharedLocalLstatFunc) {
				safeDir := filepath.Join(root, "safe-dir")
				if err := os.Mkdir(safeDir, 0o700); err != nil {
					t.Fatal(err)
				}
				hop := filepath.Join(safeDir, "hop.sock")
				if err := os.Symlink(filepath.Join(root, "elsewhere.sock"), hop); err != nil {
					t.Fatal(err)
				}
				if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(hop, socket); err != nil {
					t.Fatal(err)
				}
				return filepath.Join(root, "absent-daemon-dir"), func(path string) (os.FileInfo, uint32, error) {
					info, err := os.Lstat(path)
					return info, currentUID, err
				}
			},
			wantContain: "嵌套符号链接",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			codexHome := shortSharedLocalCodexHome(t)
			socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
			daemonDir, lstat := tc.setup(t, filepath.Dir(codexHome), socket)
			overrideSharedLocalSafetyHooks(t, true, daemonDir, currentUID, lstat)

			transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
			if err != nil {
				t.Fatal(err)
			}
			transport.startOnce = func(context.Context, SharedLocalOptions) error {
				t.Fatal("不安全符号链接目标目录不得触发启动 resident")
				return nil
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			err = transport.EnsureReady(ctx)
			if err == nil || !strings.Contains(err.Error(), tc.wantContain) || !strings.Contains(err.Error(), "已忽略") {
				t.Fatalf("EnsureReady 应拒绝不安全符号链接目标目录(%s)，got %v", tc.wantContain, err)
			}
		})
	}
}

func TestSharedLocalSafetyAllowsOwnedDaemonDirAndSymlinkSocket(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	root := filepath.Dir(codexHome)
	daemonDir := filepath.Join(root, "d")
	if err := os.Mkdir(daemonDir, 0o700); err != nil {
		t.Fatal(err)
	}
	targetSocket := filepath.Join(daemonDir, "s.sock")
	stop := startSharedLocalTestServer(t, targetSocket)
	defer stop()

	controlSocket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	if err := os.MkdirAll(filepath.Dir(controlSocket), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(targetSocket, controlSocket); err != nil {
		t.Fatal(err)
	}

	overrideSharedLocalSafetyHooks(t, true, daemonDir, uint32(os.Getuid()), defaultSharedLocalLstat)

	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := transport.EnsureReady(ctx); err != nil {
		t.Fatalf("属主匹配的真实共享目录与符号链接 socket 应允许连接：%v", err)
	}
}

func TestSharedLocalSafetyDisabledKeepsNonLinuxBehavior(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	stop := startSharedLocalTestServer(t, socket)
	defer stop()

	badFile := filepath.Join(filepath.Dir(codexHome), "codex-daemon-occupied")
	if err := os.WriteFile(badFile, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	overrideSharedLocalSafetyHooks(t, false, badFile, 1000, defaultSharedLocalLstat)

	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := transport.EnsureReady(ctx); err != nil {
		t.Fatalf("非 Linux 平台关闭目录校验时应保持原有连接行为：%v", err)
	}
}

func TestSharedLocalSafetyRejectsSystemdUnsafeMarkerAndIgnoresForegroundRuntimeDir(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	runtimeDir := t.TempDir()
	markerDir := filepath.Join(runtimeDir, "mimi-remote")
	if err := os.MkdirAll(markerDir, 0o700); err != nil {
		t.Fatal(err)
	}
	markerPath := filepath.Join(markerDir, "codex-daemon.unsafe")
	if err := os.WriteFile(markerPath, []byte("unsafe\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_RUNTIME_DIR", runtimeDir)

	// 前台进程未注入 MIMI_SHARED_CODEX_UNSAFE_MARKER，即使同会话 XDG_RUNTIME_DIR 下存在旧标记也不受阻断。
	// 保留生产 sharedLocalUnsafeMarkerPath 实现，不替换成测试副本，确保真实检验生产读取逻辑。
	prodMarkerResolver := sharedLocalUnsafeMarkerPath
	overrideSharedLocalSafetyHooks(t, true, filepath.Join(t.TempDir(), "absent"), uint32(os.Getuid()), defaultSharedLocalLstat)
	sharedLocalUnsafeMarkerPath = prodMarkerResolver
	t.Setenv(sharedLocalUnsafeMarkerEnv, "")
	if err := CheckSharedLocalCodexHomeSafety(codexHome); err != nil {
		t.Fatalf("未设置服务专属环境变量的前台进程不应受 XDG_RUNTIME_DIR 标记阻断，got %v", err)
	}

	// systemd 服务进程注入 MIMI_SHARED_CODEX_UNSAFE_MARKER 后，标记存在即拒绝。
	t.Setenv(sharedLocalUnsafeMarkerEnv, markerPath)
	if err := CheckSharedLocalCodexHomeSafety(codexHome); err == nil || !strings.Contains(err.Error(), "systemd 预检已拒绝绑定") {
		t.Fatalf("systemd 预检拒绝标记存在时应直接报不安全，got %v", err)
	}
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	if err := transport.SocketSafetyError(); err == nil || !strings.Contains(err.Error(), "systemd 预检已拒绝绑定") {
		t.Fatalf("SocketSafetyError 应拒绝带预检标记的共享 Codex，got %v", err)
	}
}
