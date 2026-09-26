//go:build darwin

package appserver

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// 前门让 launchd 在用户登录会话（Aqua）中持续持有 Codex 的标准 control socket。
// Desktop 经 SSH 执行的 `codex app-server --listen unix://` 会先连接该路径，能连上就以
// AddrInUse 退出，因此 SSH 不会再创建 Background 实例。前门把每条连接转发到私有
// backend socket；backend 只由前门在 Aqua 中启动，并脱离前门的进程组，前门重启时
// 进行中的任务不受影响。
const (
	sharedLocalBackendSocketName = "app-server-backend.sock"
	sharedLocalBackendLockName   = "app-server-backend.lock"
	frontDoorMigrationLockName   = "app-server-front-migration.lock"
	frontDoorBackendReadyTimeout = 20 * time.Second
	frontDoorDialAttemptTimeout  = 2 * time.Second
)

type FrontDoor struct {
	options           SharedLocalOptions
	backendHome       string
	public            string
	backend           string
	lockPath          string
	migrationLockPath string
	logf              func(string, ...any)
	launchMu          sync.Mutex
	launch            func(context.Context, SharedLocalOptions, string) error
	orphans           frontDoorOrphanOps
}

func NewFrontDoor(options SharedLocalOptions, logf func(string, ...any)) (*FrontDoor, error) {
	public, err := SharedLocalSocketPath(options.Env)
	if err != nil {
		return nil, err
	}
	publicDirectory := filepath.Dir(public)
	backendHome, err := resolveFrontDoorBackendHome(options.BackendCodexHome, publicDirectory)
	if err != nil {
		return nil, err
	}
	backendDirectory := filepath.Join(backendHome, sharedLocalSocketDir)
	backend := filepath.Join(backendDirectory, sharedLocalBackendSocketName)
	if len([]byte(backend)) >= 104 {
		return nil, errors.New("Codex backend socket 路径过长，请缩短 CODEX_HOME")
	}
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &FrontDoor{
		options: SharedLocalOptions{
			CodexBin:         strings.TrimSpace(options.CodexBin),
			Env:              cloneStringMap(options.Env),
			BackendCodexHome: options.BackendCodexHome,
			ConnectOnly:      options.ConnectOnly,
		},
		backendHome:       backendHome,
		public:            public,
		backend:           backend,
		lockPath:          filepath.Join(backendDirectory, sharedLocalBackendLockName),
		migrationLockPath: filepath.Join(publicDirectory, frontDoorMigrationLockName),
		logf:              logf,
		launch:            startSharedLocalAppServerListening,
		orphans:           defaultFrontDoorOrphanOps(),
	}, nil
}

func (f *FrontDoor) PublicSocketPath() string  { return f.public }
func (f *FrontDoor) BackendSocketPath() string { return f.backend }
func (f *FrontDoor) BackendCodexHome() string  { return f.backendHome }

func resolveFrontDoorBackendHome(configured, publicDirectory string) (string, error) {
	publicHome := filepath.Dir(publicDirectory)
	if configured == "" {
		return publicHome, nil
	}
	if !filepath.IsAbs(configured) {
		return "", errors.New("独立 Codex backend 要求 CODEX_HOME 使用绝对路径")
	}
	backendHome, err := canonicalExistingDirectory(configured)
	if err != nil {
		return "", fmt.Errorf("独立 Codex backend 的 CODEX_HOME 无效：%w", err)
	}
	if pathsOverlap(publicHome, backendHome) || pathsOverlapByIdentity(publicHome, backendHome) {
		return "", errors.New("独立 Codex backend 的 CODEX_HOME 不能与公共 CODEX_HOME 相同或相互包含")
	}
	return backendHome, nil
}

// pathsOverlapByIdentity 覆盖大小写不敏感文件系统上的别名路径；仅比较已存在目录，
// 不用字符串大小写规则猜测文件系统语义。
func pathsOverlapByIdentity(left, right string) bool {
	return pathContainsByIdentity(left, right) || pathContainsByIdentity(right, left)
}

func pathContainsByIdentity(parent, candidate string) bool {
	parentInfo, err := os.Stat(parent)
	if err != nil {
		return false
	}
	for current := candidate; ; current = filepath.Dir(current) {
		if currentInfo, statErr := os.Stat(current); statErr == nil && os.SameFile(parentInfo, currentInfo) {
			return true
		}
		next := filepath.Dir(current)
		if next == current {
			return false
		}
	}
}

func pathsOverlap(left, right string) bool {
	return pathContains(left, right) || pathContains(right, left)
}

func pathContains(parent, candidate string) bool {
	relative, err := filepath.Rel(parent, candidate)
	if err != nil {
		return false
	}
	return relative == "." || relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// FrontDoorCodexBin 按 Desktop 经 SSH 的解析顺序选 Codex：`${CODEX_INSTALL_DIR:-$HOME/.local/bin}`
// 优先，其次才是配置。Desktop 升级 Codex 后会强杀旧 App Server 再重连；前门若仍启动配置里的
// 旧版本，Desktop 会反复提示需要升级。
func FrontDoorCodexBin(configured string, env map[string]string) string {
	installDir := strings.TrimSpace(env["CODEX_INSTALL_DIR"])
	if installDir == "" {
		installDir = strings.TrimSpace(os.Getenv("CODEX_INSTALL_DIR"))
	}
	if installDir == "" {
		home := strings.TrimSpace(env["HOME"])
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		if home != "" {
			installDir = filepath.Join(home, ".local", "bin")
		}
	}
	if installDir != "" {
		candidate := filepath.Join(installDir, "codex")
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return strings.TrimSpace(configured)
}

// BackendPeerPID 返回当前 backend 的进程号；backend 不可达时返回错误，不会启动它。
func (f *FrontDoor) BackendPeerPID(ctx context.Context) (int, error) {
	conn, err := f.dialBackendOnce(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	pid, _, err := sharedLocalPeerIdentity(conn)
	return pid, err
}

// Serve 接受 launchd 交来的监听 socket 上的连接，直到 ctx 结束。
func (f *FrontDoor) Serve(ctx context.Context, listener net.Listener) error {
	stop := context.AfterFunc(ctx, func() { _ = listener.Close() })
	defer stop()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			if errors.Is(err, net.ErrClosed) {
				return err
			}
			f.logf("codex front door accept failed: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go f.handle(ctx, conn)
	}
}

func (f *FrontDoor) handle(ctx context.Context, client net.Conn) {
	defer client.Close()
	readyCtx, cancel := context.WithTimeout(ctx, frontDoorBackendReadyTimeout)
	backend, err := f.DialBackend(readyCtx)
	cancel()
	if err != nil {
		f.logf("codex front door backend unavailable: %v", err)
		return
	}
	defer backend.Close()
	proxyUnixStreams(client, backend)
}

// DialBackend 连接 backend；不存在时在进程内与跨进程锁内启动一次，再等待就绪。
func (f *FrontDoor) DialBackend(ctx context.Context) (net.Conn, error) {
	// 共享锁随客户端连接持有；永久移交或前门换代先取排他锁，
	// 等旧连接全部关闭后才检查空闲状态，期间不允许新的连接插入。
	unlock, err := lockFrontDoorFileMode(ctx, f.migrationLockPath, unix.LOCK_SH)
	if err != nil {
		return nil, err
	}
	conn, err := f.dialBackend(ctx)
	if err != nil {
		unlock()
		return nil, err
	}
	return &frontDoorLockedConn{Conn: conn, unlock: unlock}, nil
}

func (f *FrontDoor) dialBackend(ctx context.Context) (net.Conn, error) {
	// 旧标准 socket 被 launchd 重新绑定后，旧 resident 仍可能持有活动会话。
	// 必须等它退出，才允许任何客户端进入私有 backend，避免同一 Thread 出现两个 writer。
	if err := f.waitForOrphans(ctx); err != nil {
		return nil, err
	}
	if conn, err := f.dialBackendOnce(ctx); err == nil {
		return conn, nil
	}
	f.launchMu.Lock()
	defer f.launchMu.Unlock()
	if conn, err := f.dialBackendOnce(ctx); err == nil {
		return conn, nil
	}
	if err := os.MkdirAll(filepath.Dir(f.backend), 0o700); err != nil {
		return nil, fmt.Errorf("创建共享 Codex backend 控制目录失败：%w", err)
	}
	unlock, err := lockFrontDoorFile(ctx, f.lockPath)
	if err != nil {
		return nil, err
	}
	defer unlock()
	if conn, err := f.dialBackendOnce(ctx); err == nil {
		return conn, nil
	}
	// 残留的 backend socket 文件交给 Codex 自己的探测处理：连接被拒才删除并重新绑定。
	launchOptions := f.options
	if launchOptions.BackendCodexHome != "" {
		// 公共 socket 始终由原环境决定；只在启动私有 backend 时切换身份目录。
		launchOptions.Env = cloneStringMap(f.options.Env)
		launchOptions.Env["CODEX_HOME"] = f.backendHome
	}
	launchErr := f.launch(ctx, launchOptions, "unix://"+f.backend)
	if launchErr != nil {
		f.logf("codex front door backend launch reported: %v", launchErr)
	} else {
		f.logf("codex front door started backend socket=%s", f.backend)
	}
	for {
		conn, err := f.dialBackendOnce(ctx)
		if err == nil {
			return conn, nil
		}
		select {
		case <-ctx.Done():
			if launchErr != nil {
				return nil, fmt.Errorf("启动共享 Codex backend 失败：%w", launchErr)
			}
			return nil, fmt.Errorf("等待共享 Codex backend 就绪超时：%w", err)
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// LockMigration 排他阻止新客户端，直到换代或卸载操作完成。
func (f *FrontDoor) LockMigration(ctx context.Context) (func(), error) {
	return lockFrontDoorFileMode(ctx, f.migrationLockPath, unix.LOCK_EX)
}

type frontDoorLockedConn struct {
	net.Conn
	unlock func()
	once   sync.Once
}

func (c *frontDoorLockedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.unlock)
	return err
}

func (c *frontDoorLockedConn) CloseWrite() error {
	if closer, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return closer.CloseWrite()
	}
	return c.Close()
}

func (f *FrontDoor) waitForOrphans(ctx context.Context) error {
	for {
		orphans, err := f.ReleaseIdleOrphans(ctx)
		if err != nil {
			return fmt.Errorf("无法确认旧共享 Codex 实例已退出：%w", err)
		}
		if len(orphans) == 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("旧共享 Codex 实例尚未退出，暂不开放新 backend：%w", ctx.Err())
		case <-time.After(200 * time.Millisecond):
		}
	}
}

// WaitForOrphans 只在调用方已确认前门持有标准 socket 时使用，永久移交前等待旧实例真正退出。
func (f *FrontDoor) WaitForOrphans(ctx context.Context) error {
	return f.waitForOrphans(ctx)
}

func (f *FrontDoor) dialBackendOnce(ctx context.Context) (net.Conn, error) {
	dialer := net.Dialer{Timeout: frontDoorDialAttemptTimeout}
	return dialer.DialContext(ctx, "unix", f.backend)
}

func lockFrontDoorFile(ctx context.Context, path string) (func(), error) {
	return lockFrontDoorFileMode(ctx, path, unix.LOCK_EX)
}

func lockFrontDoorFileMode(ctx context.Context, path string, mode int) (func(), error) {
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("打开共享 Codex backend 启动锁失败：%w", err)
	}
	for {
		err := unix.Flock(int(file.Fd()), mode|unix.LOCK_NB)
		if err == nil {
			return func() {
				_ = unix.Flock(int(file.Fd()), unix.LOCK_UN)
				_ = file.Close()
			}, nil
		}
		if !errors.Is(err, unix.EWOULDBLOCK) && !errors.Is(err, unix.EINTR) {
			_ = file.Close()
			return nil, fmt.Errorf("获取共享 Codex backend 启动锁失败：%w", err)
		}
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, fmt.Errorf("等待共享 Codex backend 启动锁超时：%w", ctx.Err())
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// proxyUnixStreams 双向转发字节。一侧读到 EOF 时只半关闭另一侧的写方向，
// 让 WebSocket close 帧与剩余响应仍能送达。
func proxyUnixStreams(left, right net.Conn) {
	var wg sync.WaitGroup
	copyHalf := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		if closer, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}
	wg.Add(2)
	go copyHalf(right, left)
	go copyHalf(left, right)
	wg.Wait()
}
