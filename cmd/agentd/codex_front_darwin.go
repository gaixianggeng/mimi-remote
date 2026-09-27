//go:build darwin

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// codex-front 管理 Codex 共享服务的 launchd 前门，见 internal/appserver/front_door_darwin.go。
const (
	codexFrontLabel          = "com.gaixianggeng.mimi.mac.codex-front"
	codexFrontAppFlag        = "--codex-front-door"
	codexFrontOrphanInterval = time.Minute
	codexFrontSupervisorPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
)

// 只在已安装的 Mac App 使用默认配置时自动登记前门。隔离构建和 Homebrew
// 不能把临时 bundle 或裸 agentd 注册成用户登录项。
func prepareMacAppCodexFront(cfg config.Config, configPath string) (bool, error) {
	if !cfg.Codex.IsEnabled() || !strings.EqualFold(cfg.AppServer.Transport, "local") ||
		filepath.Clean(config.ExpandPath(configPath)) != filepath.Clean(config.DefaultPath()) {
		return false, nil
	}
	executable, err := os.Executable()
	if err != nil {
		return false, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return false, err
	}
	if !isInstalledMacAppAgentd(executable, home) {
		return false, nil
	}
	return true, runCodexFrontInstall([]string{"codex-front install", "--config", configPath}, io.Discard)
}

func isInstalledMacAppAgentd(executable, home string) bool {
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	relative := filepath.Join("Mimi Remote Mac.app", "Contents", "Resources", "agentd")
	for _, applications := range []string{"/Applications", filepath.Join(home, "Applications")} {
		if filepath.Clean(executable) == filepath.Join(applications, relative) {
			return true
		}
	}
	return false
}

func runCodexFront(args []string) error {
	if len(args) < 2 {
		return errors.New("用法：agentd codex-front serve|install|uninstall|status")
	}
	sub := args[1]
	rest := append([]string{args[0] + " " + sub}, args[2:]...)
	switch sub {
	case "serve":
		return runCodexFrontServe(rest)
	case "install":
		return runCodexFrontInstall(rest, os.Stdout)
	case "uninstall":
		return runCodexFrontUninstall(rest, os.Stdout)
	case "status":
		return runCodexFrontStatus(rest, os.Stdout)
	default:
		return fmt.Errorf("未知子命令 %q，可用：serve、install、uninstall、status", sub)
	}
}

func runCodexFrontServe(args []string) error {
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	logFile := fs.String("log-file", "", "前门日志文件")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	listenerFile := os.NewFile(0, "launchd-listener")
	listener, err := net.FileListener(listenerFile)
	if err != nil {
		return fmt.Errorf("codex-front serve 只能由 launchd 以 inetdCompatibility Wait=true 启动：%w", err)
	}
	_ = listenerFile.Close()
	logger, closeLog, err := redirectCodexFrontStdio(*logFile)
	if err != nil {
		return err
	}
	defer closeLog()

	door, err := loadCodexFrontDoor(*configPath, listener, logger.Printf)
	if err != nil {
		logger.Printf("codex front door init failed: %v", err)
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stop()
	logger.Printf("codex front door serving pid=%d public=%s backend=%s",
		os.Getpid(), door.PublicSocketPath(), door.BackendSocketPath())
	go watchCodexFrontOrphans(ctx, door, logger)
	err = door.Serve(ctx, listener)
	logger.Printf("codex front door stopped: %v", err)
	return err
}

func loadCodexFrontDoor(configPath string, listener net.Listener, logf func(string, ...any)) (*appserver.FrontDoor, error) {
	cfg, err := config.LoadForDoctor(configPath)
	if err != nil {
		return nil, fmt.Errorf("读取前门配置失败，拒绝回退其他 CODEX_HOME：%w", err)
	}
	options := codexFrontOptions(cfg)
	if err := cfg.ValidateSharedCodexHome(); err != nil {
		return nil, err
	}
	options.CodexBin = appserver.FrontDoorCodexBin(options.CodexBin, options.Env)
	door, err := appserver.NewFrontDoor(options, logf)
	if err != nil {
		return nil, err
	}
	if err := validateCodexFrontPinnedHome(os.Getenv(codexFrontBackendHomeKey), door, cfg.AppServer.SharedCodexHome != ""); err != nil {
		return nil, err
	}
	if err := rejectLegacyBackendForIsolation(codexFrontInstallation{Socket: door.PublicSocketPath(), BackendHome: door.BackendCodexHome()}); err != nil {
		return nil, err
	}
	if listener.Addr().Network() != "unix" || listener.Addr().String() != door.PublicSocketPath() {
		return nil, fmt.Errorf("launchd 前门 socket 与配置不一致：listener=%s config=%s", listener.Addr(), door.PublicSocketPath())
	}
	return door, nil
}

// launchd 的 inetd Wait=true 模式把监听 socket 同时放在 fd 0、1、2。换成 /dev/null 与日志文件，
// 避免日志或 panic 写进监听 socket。
func redirectCodexFrontStdio(logPath string) (*log.Logger, func(), error) {
	devNull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return nil, nil, err
	}
	output := devNull
	if strings.TrimSpace(logPath) != "" {
		if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
			return nil, nil, err
		}
		output, err = os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
		if err != nil {
			return nil, nil, err
		}
	}
	_ = syscall.Dup2(int(devNull.Fd()), 0)
	_ = syscall.Dup2(int(output.Fd()), 1)
	_ = syscall.Dup2(int(output.Fd()), 2)
	closeAll := func() {
		_ = devNull.Close()
		if output != devNull {
			_ = output.Close()
		}
	}
	return log.New(output, "", log.LstdFlags), closeAll, nil
}

func watchCodexFrontOrphans(ctx context.Context, door *appserver.FrontDoor, logger *log.Logger) {
	check := func() {
		checkCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		if _, err := door.ReleaseIdleOrphans(checkCtx); err != nil {
			logger.Printf("codex front door orphan check failed: %v", err)
		}
	}
	check()
	ticker := time.NewTicker(codexFrontOrphanInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			check()
		}
	}
}

type codexFrontInstallation struct {
	Label       string
	PlistPath   string
	Socket      string
	BackendHome string
	door        *appserver.FrontDoor
}

func codexFrontFlags(fs *flag.FlagSet) (*string, *string, *string) {
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	label := fs.String("label", codexFrontLabel, "launchd label")
	plistPath := fs.String("plist", "", "LaunchAgent plist 路径，默认 ~/Library/LaunchAgents/<label>.plist")
	return configPath, label, plistPath
}

func resolveCodexFrontInstallation(configPath, label, plistPath string) (codexFrontInstallation, error) {
	cfg, err := config.LoadForDoctor(configPath)
	if err != nil {
		return codexFrontInstallation{}, err
	}
	door, err := configuredCodexFrontDoor(cfg)
	if err != nil {
		return codexFrontInstallation{}, err
	}
	if strings.TrimSpace(plistPath) == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return codexFrontInstallation{}, err
		}
		plistPath = filepath.Join(home, "Library", "LaunchAgents", label+".plist")
	}
	return codexFrontInstallation{Label: label, PlistPath: plistPath, Socket: door.PublicSocketPath(), BackendHome: door.BackendCodexHome(), door: door}, nil
}

func runCodexFrontInstall(args []string, stdout io.Writer) error {
	return runCodexFrontInstallWithOps(args, stdout, defaultCodexFrontManagementOps())
}

func runCodexFrontInstallWithOps(args []string, stdout io.Writer, ops codexFrontManagementOps) error {
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	configPath, label, plistPath := codexFrontFlags(fs)
	direct := fs.Bool("direct", false, "直接由 launchd 启动 agentd（仅供开发验证，后端不继承 Mimi Remote Mac 的隐私授权）")
	logFile := fs.String("log-file", "", "前门日志文件，默认 ~/Library/Logs/mimi-remote/codex-front.log")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	unlockManagement, err := lockCodexFrontManagement(*label, true)
	if err != nil {
		return err
	}
	defer unlockManagement()
	install, err := resolveCodexFrontInstallation(*configPath, *label, *plistPath)
	if err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	programArgs, err := codexFrontProgramArguments(executable, *direct, *configPath, *logFile)
	if err != nil {
		return err
	}
	revision, err := codexFrontExecutableRevision(executable)
	if err != nil {
		return err
	}
	plist := renderCodexFrontPlist(install.Label, programArgs, install.Socket, revision, install.BackendHome)
	loaded := ops.loaded(install.Label)
	existing, readErr := os.ReadFile(install.PlistPath)
	if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
		return fmt.Errorf("无法读取已有前门配置，拒绝覆盖：%w", readErr)
	}
	if readErr == nil {
		if err := validateCodexFrontRegisteredHome(install.PlistPath, install.BackendHome); err != nil {
			return err
		}
	}
	if err := rejectLegacyBackendForIsolation(install); err != nil {
		return err
	}
	if loaded && readErr == nil && bytes.Equal(existing, plist) && ops.socketListening(install.Socket) {
		fmt.Fprintf(stdout, "前门已安装：%s\n", install.Socket)
		return nil
	}
	if loaded {
		if readErr != nil {
			return fmt.Errorf("无法读取已加载的前门配置，拒绝热更新：%w", readErr)
		}
		previousSocket, err := codexFrontPlistSocket(install.PlistPath)
		if err != nil || previousSocket != install.Socket {
			return errors.New("前门标准 socket 配置已改变，拒绝在旧会话运行时自动切换 CODEX_HOME")
		}
		// 安装身份与安全检查共用同一配置快照，避免并发改配置后检查了另一套后端。
		door := install.door
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		unlock, err := door.LockMigration(ctx)
		if err != nil {
			return fmt.Errorf("等待前门共享连接结束失败：%w", err)
		}
		defer unlock()
		if err := door.CanReload(ctx); err != nil {
			return fmt.Errorf("前门有活动共享任务，暂缓加载新版：%w", err)
		}
	}
	if !loaded && ops.socketListening(install.Socket) {
		// launchd 加载时会删除并重新绑定该路径，现有实例将失去新连接。必须先让它结束。
		return fmt.Errorf("标准 socket 已有 Codex 实例在监听：%s。请结束共享任务并关闭 Desktop SSH 页面，按共享 App Server 文档安全释放旧实例后重试前门安装", install.Socket)
	}
	if err := os.MkdirAll(filepath.Dir(install.Socket), 0o700); err != nil {
		return err
	}
	if err := writeFileAtomically(install.PlistPath, plist, 0o644); err != nil {
		return err
	}
	if loaded {
		if err := ops.bootout(install.Label); err != nil {
			return errors.Join(err, restoreCodexFrontPlist(install.PlistPath, existing, readErr == nil))
		}
	}
	if err := ops.bootstrap(install.PlistPath); err != nil {
		return errors.Join(err, rollbackCodexFrontInstall(install, ops, loaded, existing, readErr == nil))
	}
	if !ops.socketListening(install.Socket) {
		// bootstrap 已成功时保留一致的 job/plist，避免探测失败期间已有客户端触发了 backend，
		// 随后回滚前门却把该 backend 遗留为无管理进程。
		return fmt.Errorf("前门已加载，但标准 socket 未就绪：%s", install.Socket)
	}
	fmt.Fprintf(stdout, "前门已安装：label=%s socket=%s plist=%s\n", install.Label, install.Socket, install.PlistPath)
	return nil
}

func runCodexFrontUninstall(args []string, stdout io.Writer) error {
	return runCodexFrontUninstallWithOps(args, stdout, defaultCodexFrontManagementOps())
}

func runCodexFrontUninstallWithOps(args []string, stdout io.Writer, ops codexFrontManagementOps) error {
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	configPath, label, plistPath := codexFrontFlags(fs)
	stopIdleBackend := fs.Bool("stop-idle-backend", false, "仅在私有 backend 空闲并退出后卸载前门")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	unlockManagement, err := lockCodexFrontManagement(*label, true)
	if err != nil {
		return err
	}
	defer unlockManagement()
	install, err := resolveCodexFrontInstallation(*configPath, *label, *plistPath)
	if err != nil {
		return err
	}
	if _, err := os.Stat(install.PlistPath); err == nil {
		if err := validateCodexFrontRegisteredHome(install.PlistPath, install.BackendHome); err != nil {
			return err
		}
	}
	if install.BackendHome != filepath.Dir(filepath.Dir(install.Socket)) && !*stopIdleBackend {
		return errors.New("独立会话目录的前门必须使用 --stop-idle-backend 安全卸载，不能遗留旧运行时后切换目录")
	}
	loaded := ops.loaded(install.Label)
	if loaded {
		registeredSocket, err := codexFrontPlistSocket(install.PlistPath)
		if err != nil || registeredSocket != install.Socket {
			return errors.New("已加载前门的标准 socket 与当前配置不一致，拒绝卸载错误的共享环境")
		}
	}
	if *stopIdleBackend {
		// 安装身份与安全检查共用同一配置快照，避免并发改配置后检查了另一套后端。
		door := install.door
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		unlock, err := door.LockMigration(ctx)
		if err != nil {
			return fmt.Errorf("等待前门共享连接结束失败：%w", err)
		}
		defer unlock()
		if loaded {
			if err := door.WaitForOrphans(ctx); err != nil {
				return fmt.Errorf("旧共享 Codex 实例尚未退出，无法安全恢复 Homebrew：%w", err)
			}
		}
		if err := door.StopIdleBackend(ctx); err != nil {
			return fmt.Errorf("前门仍有活动服务，无法安全恢复 Homebrew：%w", err)
		}
	}
	if loaded {
		if err := ops.bootout(install.Label); err != nil {
			return err
		}
	}
	if err := os.Remove(install.PlistPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	// launchd 卸载后留下的 socket 文件已无人监听；Codex 探测到连接被拒也会自行清理。
	if info, err := os.Lstat(install.Socket); err == nil && info.Mode()&os.ModeSocket != 0 && !ops.socketListening(install.Socket) {
		_ = os.Remove(install.Socket)
	}
	if *stopIdleBackend {
		fmt.Fprintln(stdout, "前门已卸载；空闲私有 Codex backend 已安全退出。")
	} else {
		fmt.Fprintln(stdout, "前门已卸载；后端 Codex 保持运行，直到它自行退出或被修复流程释放。")
	}
	return nil
}

type codexFrontStatus struct {
	Label                      string `json:"label"`
	Loaded                     bool   `json:"loaded"`
	PlistPath                  string `json:"plist"`
	PublicSocket               string `json:"public_socket"`
	PublicListening            bool   `json:"public_listening"`
	BackendSocket              string `json:"backend_socket"`
	BackendCodexHome           string `json:"backend_codex_home"`
	ConfiguredBackendCodexHome string `json:"configured_backend_codex_home"`
	IsolatedHistory            bool   `json:"isolated_history"`
	ConfigurationError         string `json:"configuration_error,omitempty"`
	BackendPID                 int    `json:"backend_pid,omitempty"`
	BackendError               string `json:"backend_error,omitempty"`
}

func runCodexFrontStatus(args []string, stdout io.Writer) error {
	return runCodexFrontStatusWithOps(args, stdout, defaultCodexFrontManagementOps())
}

func runCodexFrontStatusWithOps(args []string, stdout io.Writer, ops codexFrontManagementOps) error {
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	configPath, label, plistPath := codexFrontFlags(fs)
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	unlockManagement, err := lockCodexFrontManagement(*label, false)
	if err != nil {
		return err
	}
	defer unlockManagement()
	install, err := resolveCodexFrontInstallation(*configPath, *label, *plistPath)
	if err != nil {
		return err
	}
	status := codexFrontStatus{
		Label: install.Label, Loaded: ops.loaded(install.Label), PlistPath: install.PlistPath,
		PublicSocket: install.Socket, ConfiguredBackendCodexHome: install.BackendHome,
	}
	// 即使 job 已退出，磁盘登记仍是旧 backend 的身份；不能把新配置当作已切换成功。
	door, err := registeredCodexFrontDoor(install.PlistPath)
	if err != nil {
		status.ConfigurationError = err.Error()
	} else {
		status.PublicSocket = door.PublicSocketPath()
		status.BackendSocket = door.BackendSocketPath()
		status.BackendCodexHome = door.BackendCodexHome()
		status.IsolatedHistory = status.Loaded && door.BackendCodexHome() != filepath.Dir(filepath.Dir(door.PublicSocketPath()))
		if door.BackendCodexHome() != install.BackendHome || door.PublicSocketPath() != install.Socket {
			status.ConfigurationError = "当前配置与已登记前门不一致；运行态字段仍显示已登记的旧后端"
		}
		// 只检查 backend 本身，不经过前门，因此不会触发启动。
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if pid, err := door.BackendPeerPID(ctx); err == nil {
			status.BackendPID = pid
		} else {
			status.BackendError = err.Error()
		}
	}
	status.PublicListening = status.Loaded || ops.socketListening(status.PublicSocket)
	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(status)
}

// App 内安装时由 Mimi Remote Mac 主可执行文件承接 TCC 责任，再启动包内 agentd。
// 开发验证可用 --direct 让 launchd 直接启动 agentd。
func codexFrontProgramArguments(executable string, direct bool, configPath, logFile string) ([]string, error) {
	if strings.TrimSpace(logFile) == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		logFile = filepath.Join(home, "Library", "Logs", "mimi-remote", "codex-front.log")
	}
	defaultConfig := filepath.Clean(config.ExpandPath(configPath)) == filepath.Clean(config.DefaultPath())
	resources := filepath.Dir(executable)
	contents := filepath.Dir(resources)
	appMain := filepath.Join(contents, "MacOS", "Mimi Remote Mac")
	if !direct && filepath.Base(resources) == "Resources" && strings.HasSuffix(filepath.Dir(contents), ".app") {
		if _, err := os.Stat(appMain); err == nil {
			args := []string{appMain, codexFrontAppFlag}
			if !defaultConfig {
				args = append(args, "--config", config.ExpandPath(configPath))
			}
			return args, nil
		}
	}
	if !direct {
		return nil, errors.New("未找到 Mimi Remote Mac 主程序；开发环境请显式使用 --direct")
	}
	return []string{executable, "codex-front", "serve", "--config", config.ExpandPath(configPath), "--log-file", logFile}, nil
}

func codexFrontExecutableRevision(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("读取前门二进制失败：%w", err)
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", fmt.Errorf("计算前门二进制摘要失败：%w", err)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func codexFrontPlistSocket(path string) (string, error) {
	output, err := exec.Command("/usr/bin/plutil", "-extract", "Sockets.Listeners.SockPathName", "raw", "-o", "-", path).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func renderCodexFrontPlist(label string, programArgs []string, socket, revision, backendHome string) []byte {
	escape := func(value string) string {
		var buffer bytes.Buffer
		_ = xml.EscapeText(&buffer, []byte(value))
		return buffer.String()
	}
	var b strings.Builder
	b.WriteString(xml.Header)
	b.WriteString(`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` + "\n")
	b.WriteString("<plist version=\"1.0\">\n<dict>\n")
	fmt.Fprintf(&b, "\t<key>Label</key>\n\t<string>%s</string>\n", escape(label))
	b.WriteString("\t<key>ProgramArguments</key>\n\t<array>\n")
	for _, arg := range programArgs {
		fmt.Fprintf(&b, "\t\t<string>%s</string>\n", escape(arg))
	}
	b.WriteString("\t</array>\n")
	b.WriteString("\t<key>Sockets</key>\n\t<dict>\n\t\t<key>Listeners</key>\n\t\t<dict>\n")
	fmt.Fprintf(&b, "\t\t\t<key>SockPathName</key>\n\t\t\t<string>%s</string>\n", escape(socket))
	b.WriteString("\t\t\t<key>SockPathMode</key>\n\t\t\t<integer>384</integer>\n\t\t</dict>\n\t</dict>\n")
	b.WriteString("\t<key>inetdCompatibility</key>\n\t<dict>\n\t\t<key>Wait</key>\n\t\t<true/>\n\t</dict>\n")
	b.WriteString("\t<key>EnvironmentVariables</key>\n\t<dict>\n")
	fmt.Fprintf(&b, "\t\t<key>PATH</key>\n\t\t<string>%s</string>\n", codexFrontSupervisorPath)
	fmt.Fprintf(&b, "\t\t<key>MIMI_CODEX_FRONT_REVISION</key>\n\t\t<string>%s</string>\n", escape(revision))
	fmt.Fprintf(&b, "\t\t<key>%s</key>\n\t\t<string>%s</string>\n\t</dict>\n", codexFrontBackendHomeKey, escape(backendHome))
	b.WriteString("\t<key>AssociatedBundleIdentifiers</key>\n\t<array>\n\t\t<string>com.gaixianggeng.mimi.mac</string>\n\t</array>\n")
	b.WriteString("\t<key>LimitLoadToSessionType</key>\n\t<string>Aqua</string>\n")
	b.WriteString("\t<key>ProcessType</key>\n\t<string>Interactive</string>\n")
	b.WriteString("</dict>\n</plist>\n")
	return []byte(b.String())
}

func codexFrontDomain() string { return "gui/" + strconv.Itoa(os.Getuid()) }

func codexFrontLoaded(label string) bool {
	return exec.Command("/bin/launchctl", "print", codexFrontDomain()+"/"+label).Run() == nil
}

func codexFrontBootout(label string) error {
	output, err := exec.Command("/bin/launchctl", "bootout", codexFrontDomain()+"/"+label).CombinedOutput()
	if err != nil && codexFrontLoaded(label) {
		return fmt.Errorf("卸载前门失败：%s", strings.TrimSpace(string(output)))
	}
	for attempt := 0; attempt < 50 && codexFrontLoaded(label); attempt++ {
		time.Sleep(100 * time.Millisecond)
	}
	return nil
}

// 刚 bootout 后立即 bootstrap 偶尔返回 I/O error，短暂重试即可。
func codexFrontBootstrap(plistPath string) error {
	var lastOutput []byte
	for attempt := 0; attempt < 5; attempt++ {
		output, err := exec.Command("/bin/launchctl", "bootstrap", codexFrontDomain(), plistPath).CombinedOutput()
		if err == nil {
			return nil
		}
		lastOutput = output
		time.Sleep(time.Second)
	}
	return fmt.Errorf("加载前门失败：%s", strings.TrimSpace(string(lastOutput)))
}

func codexFrontSocketListening(path string) bool {
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func writeFileAtomically(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+"-")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Chmod(mode); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}
