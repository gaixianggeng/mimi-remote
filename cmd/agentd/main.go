package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
	"github.com/skip2/go-qrcode"
)

// 正式发布由 GoReleaser 使用 -X 注入版本号；源码构建明确标记为 devel，避免首个正式版本被误判为开发构建。
var version = "devel"

// managedServicePlatform 默认等于编译目标，只作为平台命令选择的窄测试缝隙；
// 生产代码不修改它，也不根据配置或环境变量伪装操作系统。
var managedServicePlatform = runtime.GOOS

const (
	serveHTTPDrainTimeout       = 5 * time.Second
	serveRuntimeShutdownTimeout = 3 * time.Second
)

func main() {
	if err := run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "错误：%v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	cmd := "serve"
	if len(args) > 1 && !strings.HasPrefix(args[1], "-") {
		cmd = args[1]
		args = append([]string{args[0]}, args[2:]...)
	}

	switch cmd {
	case "version":
		fmt.Println(version)
		return nil
	case "setup":
		return runSetup(args)
	case "up":
		return runUp(args)
	case "start":
		return runStart(args)
	case "restart":
		return runRestart(args)
	case "stop":
		return runStop(args)
	case "status":
		return runStatus(args)
	case "logs":
		return runLogs(args)
	case "pair":
		return runPair(args)
	case "doctor":
		return runDoctor(args)
	case "serve":
		cfg, registry, checker, err := loadRuntimeConfig(args, false)
		if err != nil {
			return err
		}
		return serve(cfg, registry, checker)
	default:
		return fmt.Errorf("未知命令 %q，可用命令：up、setup、start、restart、stop、status、logs、pair、serve、doctor、version", cmd)
	}
}

func runSetup(args []string) error {
	fs := flag.NewFlagSet("setup", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	scanRoot := fs.String("scan-root", "", "项目扫描根目录，默认优先使用 ~/code，其次使用当前目录")
	browseRoot := fs.String("browse-root", "", "iPad 目录浏览/打开 workspace 的授权根目录，默认使用用户 Home")
	listen := fs.String("listen", "", "agentd 监听地址，默认优先绑定 Tailscale IP")
	appServerListen := fs.String("app-server-listen", "", "本机 Codex app-server WebSocket 地址")
	force := fs.Bool("force", false, "覆盖已有配置并重新生成 token")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, os.Stderr); err != nil {
		return err
	}
	result, err := agentsetup.Run(context.Background(), agentsetup.Options{
		ConfigPath:      *configPath,
		ScanRoot:        *scanRoot,
		BrowseRoot:      *browseRoot,
		Listen:          *listen,
		AppServerListen: *appServerListen,
		Force:           *force,
	})
	if err != nil {
		return err
	}
	if *asJSON {
		return printJSON(result)
	}
	printSetupResult(os.Stdout, result)
	return nil
}

func runUp(args []string) error {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	scanRoot := fs.String("scan-root", "", "项目扫描根目录，默认优先使用 ~/code，其次使用当前目录")
	browseRoot := fs.String("browse-root", "", "iPad 目录浏览/打开 workspace 的授权根目录，默认使用用户 Home")
	listen := fs.String("listen", "", "agentd 监听地址，默认优先绑定 Tailscale IP")
	appServerListen := fs.String("app-server-listen", "", "本机 Codex app-server WebSocket 地址")
	waitTimeout := fs.Duration("wait", 10*time.Second, "等待后台服务健康检查时间，设置 0 可跳过")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, os.Stderr); err != nil {
		return err
	}
	if err := ensureManagedServiceDefaultConfig(managedServicePlatform, *configPath); err != nil {
		return err
	}
	if err := ensureManagedServiceInstalled(managedServicePlatform); err != nil {
		return err
	}

	if !*asJSON {
		fmt.Fprintln(os.Stdout, "正在准备 Mimi Mac 助手...")
	}
	result, err := agentsetup.Run(context.Background(), agentsetup.Options{
		ConfigPath:      *configPath,
		ScanRoot:        *scanRoot,
		BrowseRoot:      *browseRoot,
		Listen:          *listen,
		AppServerListen: *appServerListen,
	})
	if err != nil {
		return err
	}
	if err := ensureCodexCLIAvailable(result.ConfigPath); err != nil {
		return err
	}

	serviceStdout := io.Writer(os.Stdout)
	serviceStderr := io.Writer(os.Stderr)
	if *asJSON {
		serviceStdout = io.Discard
		serviceStderr = io.Discard
	}
	if err := runManagedServiceForPlatform(managedServicePlatform, "start", serviceStdout, serviceStderr); err != nil {
		if managedServicePlatform == "darwin" {
			return fmt.Errorf("%w\n\n安装 Homebrew 后请重新运行：agentd up\n排查环境可以运行：agentd doctor --fix", err)
		}
		return fmt.Errorf("%w\n\n排查环境可以运行：agentd doctor --fix", err)
	}

	serviceOK := true
	serviceError := ""
	if err := waitForServiceReady(context.Background(), result.Endpoint, result.Token, version, *waitTimeout); err != nil {
		serviceOK = false
		serviceError = err.Error()
		if *asJSON {
			return printJSON(map[string]any{
				"result":        result,
				"service_ok":    serviceOK,
				"service_error": serviceError,
			})
		}
		return fmt.Errorf("Mimi Mac 助手还没有启动成功，暂时不要扫码。\n\n原因：%v\n下一步：\n  agentd doctor --fix\n  agentd logs", err)
	} else if *waitTimeout > 0 {
		if *asJSON {
			return printJSON(map[string]any{
				"result":     result,
				"service_ok": serviceOK,
			})
		}
		fmt.Fprintln(os.Stdout, "Mimi Mac 助手已准备好")
	}
	if *asJSON {
		return printJSON(map[string]any{
			"result":     result,
			"service_ok": serviceOK,
		})
	}

	printServeConnection(os.Stdout, result)
	fmt.Fprintln(os.Stdout, "常用命令：")
	fmt.Fprintln(os.Stdout, "  agentd status       查看当前连接状态")
	fmt.Fprintln(os.Stdout, "  agentd pair         刷新配对二维码")
	fmt.Fprintln(os.Stdout, "  agentd stop         停止当前平台后台服务")
	fmt.Fprintln(os.Stdout, "  agentd doctor --fix 自动检查并修复常见问题")
	return nil
}

func runStart(args []string) error {
	fs := flag.NewFlagSet("start", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	waitTimeout := fs.Duration("wait", 8*time.Second, "等待后台服务健康检查时间，设置 0 可跳过")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, os.Stderr); err != nil {
		return err
	}
	if err := ensureManagedServiceDefaultConfig(managedServicePlatform, *configPath); err != nil {
		return err
	}
	if err := ensureManagedServiceInstalled(managedServicePlatform); err != nil {
		return err
	}

	result, err := agentsetup.Pair(context.Background(), *configPath)
	if err != nil {
		return fmt.Errorf("读取连接信息失败，请先执行 agentd setup：%w", err)
	}

	if managedServicePlatform == "darwin" {
		fmt.Fprintln(os.Stdout, "正在启动 Homebrew 后台服务...")
	} else {
		fmt.Fprintln(os.Stdout, "正在启动 Linux user-systemd 后台服务...")
	}
	if err := runManagedServiceForPlatform(managedServicePlatform, "start", os.Stdout, os.Stderr); err != nil {
		return err
	}

	if err := waitForServiceReady(context.Background(), result.Endpoint, result.Token, version, *waitTimeout); err != nil {
		return fmt.Errorf("后台服务已提交，但就绪检查未通过，暂不展示配对二维码：%w", err)
	} else if *waitTimeout > 0 {
		fmt.Fprintln(os.Stdout, "agentd 后台服务已启动")
	}
	printServeConnection(os.Stdout, result)
	return nil
}

func runRestart(args []string) error {
	fs := flag.NewFlagSet("restart", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	waitTimeout := fs.Duration("wait", 8*time.Second, "等待后台服务健康检查时间，设置 0 可跳过")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, os.Stderr); err != nil {
		return err
	}
	if err := ensureManagedServiceDefaultConfig(managedServicePlatform, *configPath); err != nil {
		return err
	}
	if err := ensureManagedServiceInstalled(managedServicePlatform); err != nil {
		return err
	}

	result, err := agentsetup.Pair(context.Background(), *configPath)
	if err != nil {
		return fmt.Errorf("读取连接信息失败，请先执行 agentd up：%w", err)
	}
	fmt.Fprintln(os.Stdout, "正在重启 Mimi Mac 助手...")
	if err := runManagedServiceForPlatform(managedServicePlatform, "restart", os.Stdout, os.Stderr); err != nil {
		return err
	}
	if err := waitForServiceReady(context.Background(), result.Endpoint, result.Token, version, *waitTimeout); err != nil {
		return fmt.Errorf("后台服务已重启，但就绪检查未通过，暂不展示配对二维码：%w", err)
	} else if *waitTimeout > 0 {
		fmt.Fprintln(os.Stdout, "Mimi Mac 助手已重新连接")
	}
	printServeConnection(os.Stdout, result)
	return nil
}

func runStop(args []string) error {
	fs := flag.NewFlagSet("stop", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	// stop 只委托系统服务管理器发信号，不读取 Token、探测 ready，也不触发旧配置迁移；
	// 但仍要拒绝 service 不会读取的自定义配置，避免用户误停另一个前台实例。
	if err := ensureManagedServiceDefaultConfig(managedServicePlatform, *configPath); err != nil {
		return err
	}
	if err := ensureManagedServiceInstalled(managedServicePlatform); err != nil {
		return err
	}

	fmt.Fprintln(os.Stdout, "正在停止 Mimi Mac 助手...")
	if err := runManagedServiceForPlatform(managedServicePlatform, "stop", os.Stdout, os.Stderr); err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, "Mimi Mac 助手已停止")
	return nil
}

func runStatus(args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, os.Stderr); err != nil {
		return err
	}

	cfg, registry, checker, err := loadRuntimeConfigFromPath(*configPath, true)
	if err != nil {
		return err
	}
	result := agentsetup.ResultFromConfig(context.Background(), *configPath, cfg)
	serviceStatus := probeAgentServiceStatus(context.Background(), result.Endpoint, result.Token, version, time.Second)
	doctorResults := checker.Run(context.Background(), false)
	status := serviceStatusFields(serviceStatus, result.Token)
	status["version"] = version
	status["endpoint"] = result.Endpoint
	status["config_path"] = result.ConfigPath
	status["projects"] = len(registry.List())
	status["doctor_ok"] = doctorResults.OK
	status["doctor"] = doctorResults
	status["pair_expires"] = result.PairExpiresAt
	if *asJSON {
		return printJSON(status)
	}

	fmt.Fprintln(os.Stdout, "Mimi Mac 助手状态")
	fmt.Fprintf(os.Stdout, "\n版本：%s\n", version)
	fmt.Fprintf(os.Stdout, "配置：%s\n", result.ConfigPath)
	fmt.Fprintf(os.Stdout, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(os.Stdout, "项目数：%d\n", len(registry.List()))
	printServiceStatus(os.Stdout, serviceStatus, result.Token)
	if doctorResults.OK {
		fmt.Fprintln(os.Stdout, "环境：检查通过")
	} else {
		fmt.Fprintln(os.Stdout, "环境：需要处理")
		printDoctorActions(os.Stdout, doctorResults)
	}
	fmt.Fprintln(os.Stdout, "\n下一步：")
	fmt.Fprintln(os.Stdout, "  agentd pair         刷新配对二维码")
	fmt.Fprintln(os.Stdout, "  agentd doctor --fix 自动检查并修复常见问题")
	fmt.Fprintln(os.Stdout, "  agentd logs         查看最近日志")
	return nil
}

func serviceStatusFields(serviceStatus agentServiceStatus, token string) map[string]any {
	status := map[string]any{
		"process_ok": serviceStatus.ProcessOK(),
		// service_ok 是 Linux 安装脚本已使用的兼容字段；从现在起明确表示 readyz 通过，
		// 不能再用只有进程存活语义的 healthz 冒充移动端可用。
		"service_ok": serviceStatus.Ready(),
	}
	if serviceStatus.ProcessErr != nil {
		status["process_error"] = publicStatusError(serviceStatus.ProcessErr, token)
	}
	if serviceStatus.ReadyErr != nil {
		status["service_error"] = publicStatusError(serviceStatus.ReadyErr, token)
	}
	return status
}

type agentServiceStatus struct {
	ProcessErr error
	ReadyErr   error
}

func (s agentServiceStatus) ProcessOK() bool {
	return s.ProcessErr == nil
}

func (s agentServiceStatus) Ready() bool {
	return s.ReadyErr == nil
}

func probeAgentServiceStatus(ctx context.Context, endpoint string, token string, expectedVersion string, timeout time.Duration) agentServiceStatus {
	// 两个探测必须独立执行：healthz 只回答进程是否存活，readyz 才回答鉴权、版本和
	// Codex upstream 是否已经可以承接移动端请求。
	return agentServiceStatus{
		ProcessErr: waitForServiceHealth(ctx, endpoint, timeout),
		ReadyErr:   waitForServiceReady(ctx, endpoint, token, expectedVersion, timeout),
	}
}

func printServiceStatus(w io.Writer, status agentServiceStatus, token string) {
	if status.ProcessOK() {
		fmt.Fprintln(w, "进程存活：是")
	} else {
		fmt.Fprintf(w, "进程存活：否（%s）\n", publicStatusError(status.ProcessErr, token))
	}
	if status.Ready() {
		fmt.Fprintln(w, "Codex 服务可用：是")
	} else {
		fmt.Fprintf(w, "Codex 服务可用：否（%s）\n", publicStatusError(status.ReadyErr, token))
	}
}

func publicStatusError(err error, secrets ...string) string {
	if err == nil {
		return ""
	}
	message := err.Error()
	// status 同时服务 macOS 与 Linux；内部启动命令保留 Homebrew 处置提示，
	// 对外状态只展示跨平台原因，具体操作统一由下方 doctor/logs 引导承接。
	if index := strings.Index(message, readyServiceRecoveryHint); index >= 0 {
		message = message[:index]
	}
	for _, secret := range secrets {
		secret = strings.TrimSpace(secret)
		if secret != "" {
			message = strings.ReplaceAll(message, secret, "<redacted>")
		}
	}
	return message
}

func runLogs(args []string) error {
	fs := flag.NewFlagSet("logs", flag.ExitOnError)
	lineCount := fs.Int("n", defaultLogLineCount, "显示最近日志行数（1-5000，<=0 使用默认 120）")
	follow := fs.Bool("f", false, "跟随日志输出")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	return runManagedLogsForPlatform(managedServicePlatform, *lineCount, *follow, os.Stdout, os.Stderr)
}

func runPair(args []string) error {
	return runPairWithWriters(args, os.Stdout, os.Stderr)
}

func runPairWithWriters(args []string, stdout io.Writer, stderr io.Writer) error {
	fs := flag.NewFlagSet("pair", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	asJSON := fs.Bool("json", false, "输出 JSON")
	qrOnly := fs.Bool("qr-only", false, "只输出短期配对信息和二维码，不输出长期 Token")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, stderr); err != nil {
		return err
	}
	result, err := agentsetup.Pair(context.Background(), *configPath)
	if err != nil {
		return err
	}
	if *asJSON {
		if *qrOnly {
			return printJSONTo(stdout, qrOnlyPairResult(result))
		}
		return printJSONTo(stdout, result)
	}
	if *qrOnly {
		printQROnlyPairResult(stdout, result)
		return nil
	}
	printPairResult(stdout, result)
	return nil
}

func runDoctor(args []string) error {
	checkPort := false
	asJSON := false
	fix := false
	configPath := config.DefaultPath()
	fs := flag.NewFlagSet("doctor", flag.ExitOnError)
	fs.StringVar(&configPath, "config", config.DefaultPath(), "配置文件路径")
	fs.BoolVar(&checkPort, "check-port", false, "检查当前配置端口是否可监听")
	fs.BoolVar(&asJSON, "json", false, "只输出 JSON")
	fs.BoolVar(&fix, "fix", false, "自动修复安全的常见问题")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if err := prepareDefaultConfigMigration(fs, configPath, os.Stderr); err != nil {
		return err
	}
	_, _, checker, err := loadRuntimeConfigFromPath(configPath, true)
	if err != nil {
		if !fix {
			return err
		}
		fixes, repairedChecker, repairedResults, repairErr := rebuildDoctorConfig(context.Background(), configPath, checkPort)
		if repairErr != nil {
			return fmt.Errorf("%v；自动修复也失败：%w", err, repairErr)
		}
		if asJSON {
			return printJSON(map[string]any{"fixes": fixes, "results": repairedResults})
		}
		fmt.Fprintf(os.Stdout, "配置加载失败，已尝试自动修复：%v\n\n", err)
		if len(fixes) > 0 {
			fmt.Fprintln(os.Stdout, "已修复：")
			for _, item := range fixes {
				fmt.Fprintf(os.Stdout, "  OK %s\n", item)
			}
			fmt.Fprintln(os.Stdout)
		}
		doctor.Print(os.Stdout, repairedResults)
		_ = repairedChecker
		if !repairedResults.OK {
			return fmt.Errorf("doctor 检查未通过")
		}
		return nil
	}
	results := checker.Run(context.Background(), checkPort)
	fixes := []string{}
	if fix {
		fixes, checker, results, err = runDoctorFix(context.Background(), configPath, checkPort, results)
		if err != nil {
			return err
		}
	}
	if asJSON {
		payload := any(results)
		if fix {
			payload = map[string]any{"fixes": fixes, "results": results}
		}
		if err := printJSON(payload); err != nil {
			return err
		}
	} else {
		if fix && len(fixes) > 0 {
			fmt.Fprintln(os.Stdout, "已修复：")
			for _, item := range fixes {
				fmt.Fprintf(os.Stdout, "  OK %s\n", item)
			}
			fmt.Fprintln(os.Stdout)
		}
		doctor.Print(os.Stdout, results)
		_ = checker
	}
	if !results.OK {
		return fmt.Errorf("doctor 检查未通过")
	}
	return nil
}

func loadRuntimeConfig(args []string, forDoctor bool, configure ...func(*flag.FlagSet)) (config.Config, *projects.Registry, *doctor.Checker, error) {
	fs := flag.NewFlagSet(args[0], flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	for _, fn := range configure {
		fn(fs)
	}
	if err := fs.Parse(args[1:]); err != nil {
		return config.Config{}, nil, nil, err
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, os.Stderr); err != nil {
		return config.Config{}, nil, nil, err
	}
	var (
		cfg config.Config
		err error
	)
	if forDoctor {
		cfg, err = config.LoadForDoctor(*configPath)
	} else {
		cfg, err = config.Load(*configPath)
	}
	if err != nil {
		return config.Config{}, nil, nil, err
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		return config.Config{}, nil, nil, err
	}
	checker := doctor.NewChecker(version, cfg, registry, *configPath)
	return cfg, registry, checker, nil
}

func loadRuntimeConfigFromPath(configPath string, forDoctor bool) (config.Config, *projects.Registry, *doctor.Checker, error) {
	var (
		cfg config.Config
		err error
	)
	if forDoctor {
		cfg, err = config.LoadForDoctor(configPath)
	} else {
		cfg, err = config.Load(configPath)
	}
	if err != nil {
		return config.Config{}, nil, nil, err
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		return config.Config{}, nil, nil, err
	}
	checker := doctor.NewChecker(version, cfg, registry, configPath)
	return cfg, registry, checker, nil
}

func runDoctorFix(ctx context.Context, configPath string, checkPort bool, current doctor.Results) ([]string, *doctor.Checker, doctor.Results, error) {
	configPath = expandUserPath(configPath)
	fixes := []string{}
	needsSetup := false
	if _, err := os.Stat(configPath); err != nil {
		if os.IsNotExist(err) {
			needsSetup = true
		} else {
			return nil, nil, current, fmt.Errorf("读取配置状态失败：%w", err)
		}
	}
	if hasFailedCheck(current, "token") || hasFailedCheck(current, "projects") {
		needsSetup = true
	}
	if hasFailedCheck(current, "config-file") {
		fixed, err := tightenSensitiveFilePermissions(configPath)
		if err != nil {
			return nil, nil, current, fmt.Errorf("修复配置文件权限失败：%w", err)
		}
		if fixed {
			fixes = append(fixes, "已将配置文件权限收紧为 0600")
		}
	}
	if hasFailedCheck(current, "app-server-token-file") && !needsSetup {
		// legacy 配置没有独立 upstream token，或原文件已丢失时，只补 token 路径，不重建整份用户配置。
		tokenPath, repaired, repairErr := agentsetup.RepairManagedWSTokenFile(configPath)
		if repairErr != nil {
			return nil, nil, current, fmt.Errorf("修复 app-server token file 失败：%w", repairErr)
		}
		if repaired {
			fixes = append(fixes, "已生成独立 app-server token file 并原子更新配置")
		} else if strings.TrimSpace(tokenPath) != "" {
			fixed, fixErr := tightenSensitiveFilePermissions(tokenPath)
			if fixErr != nil {
				return nil, nil, current, fmt.Errorf("修复 app-server token file 权限失败：%w", fixErr)
			}
			if fixed {
				fixes = append(fixes, "已将 app-server token file 权限收紧为 0600")
			}
		}
	}
	if needsSetup {
		setupFixes, err := forceSetupWithBackup(ctx, configPath)
		if err != nil {
			return nil, nil, current, err
		}
		fixes = append(fixes, setupFixes...)
	}
	_, registry, checker, err := loadRuntimeConfigFromPath(configPath, true)
	if err != nil {
		return nil, nil, current, err
	}
	_ = registry
	return fixes, checker, checker.Run(ctx, checkPort), nil
}

func tightenSensitiveFilePermissions(path string) (bool, error) {
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 == 0 {
		return false, nil
	}
	// 不读取也不重写文件内容，只收紧 mode，避免 doctor --fix 意外轮换现有 token。
	if err := os.Chmod(path, 0o600); err != nil {
		return false, err
	}
	return true, nil
}

func rebuildDoctorConfig(ctx context.Context, configPath string, checkPort bool) ([]string, *doctor.Checker, doctor.Results, error) {
	fixes, err := forceSetupWithBackup(ctx, configPath)
	if err != nil {
		return nil, nil, doctor.Results{}, err
	}
	_, _, checker, err := loadRuntimeConfigFromPath(configPath, true)
	if err != nil {
		return nil, nil, doctor.Results{}, err
	}
	return fixes, checker, checker.Run(ctx, checkPort), nil
}

func forceSetupWithBackup(ctx context.Context, configPath string) ([]string, error) {
	fixes := []string{}
	if fileExists(configPath) {
		backup, err := backupFile(configPath)
		if err != nil {
			return nil, err
		}
		fixes = append(fixes, "已备份旧配置："+backup)
	}
	if _, err := agentsetup.Run(ctx, agentsetup.Options{ConfigPath: configPath, Force: true}); err != nil {
		return nil, fmt.Errorf("自动生成配置失败：%w", err)
	}
	fixes = append(fixes, "已生成可配对的默认配置")
	return fixes, nil
}

func serve(cfg config.Config, registry *projects.Registry, checker *doctor.Checker) error {
	var appServerWSProcess *appserver.ManagedWebSocketProcess
	if cfg.AppServer.Transport != "ws" {
		return fmt.Errorf("当前 iPad 链路只支持 app_server.transport=ws")
	}
	if strings.TrimSpace(cfg.AppServer.Listen) == "" {
		return fmt.Errorf("app_server.listen 未配置，无法启用 app-server gateway")
	}
	if cfg.AppServer.Managed {
		process, err := startManagedAppServerWebSocket(cfg)
		if err != nil {
			return err
		}
		appServerWSProcess = process
		log.Printf("agentd managed app-server ws upstream=%s", cfg.AppServer.Listen)
	} else {
		log.Printf("agentd app-server ws upstream=%s", cfg.AppServer.Listen)
	}
	manager := session.NewManager(session.Options{
		CodexBin:     cfg.Codex.Bin,
		DefaultArgs:  cfg.Codex.DefaultArgs,
		Env:          cfg.Codex.Env,
		OutputBuffer: cfg.Session.OutputBufferBytes,
	})

	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           httpapi.NewRouterWithRuntime(cfg, registry, manager, checker, version, nil),
		ReadHeaderTimeout: 10 * time.Second,
	}

	listener, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		_ = shutdownServeResources(manager, appServerWSProcess)
		return err
	}
	maybePrintServeConnection(os.Stdout, agentsetup.ResultFromConfig(context.Background(), "", cfg))

	// HTTP 与 managed upstream 各自最多发送一次退出事件；容量必须覆盖二者，确保 shutdown
	// 同时触发两个 goroutine 退出时不会因为主 goroutine 已选中另一事件而遗留阻塞发送。
	errCh := make(chan error, 2)
	go func() {
		log.Printf("agentd listening on http://%s", cfg.Listen)
		errCh <- server.Serve(listener)
	}()
	if appServerWSProcess != nil {
		go func() {
			<-appServerWSProcess.Done()
			errCh <- managedAppServerExitedError(appServerWSProcess)
		}()
	}

	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(stopCh)
	return waitForServeExit(stopCh, errCh, func() error {
		return shutdownServe(server, serveHTTPDrainTimeout, func() error {
			return shutdownServeResources(manager, appServerWSProcess)
		})
	})
}

func waitForServeExit(stopCh <-chan os.Signal, errCh <-chan error, shutdown func() error) error {
	var cause error
	select {
	case sig := <-stopCh:
		log.Printf("收到退出信号 %s，正在停止 HTTP 接入并排空请求", sig)
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			cause = err
		}
	}
	shutdownErr := shutdown()
	if cause != nil {
		if shutdownErr != nil {
			return fmt.Errorf("%w；关闭 agentd 资源时发生错误：%v", cause, shutdownErr)
		}
		return cause
	}
	return shutdownErr
}

func shutdownServe(server *http.Server, drainTimeout time.Duration, cleanup func() error) error {
	var shutdownErr error
	if server != nil {
		if drainTimeout <= 0 {
			drainTimeout = serveHTTPDrainTimeout
		}
		ctx, cancel := context.WithTimeout(context.Background(), drainTimeout)
		shutdownErr = server.Shutdown(ctx)
		cancel()
		if shutdownErr != nil {
			// Shutdown 超时后强制关闭普通 HTTP 连接；已 hijack 的 WebSocket 不归
			// net/http 管理，会在随后关闭 managed upstream 时结束转发链路。
			_ = server.Close()
		}
	}
	// 必须在 HTTP listener 已关闭、普通请求 drain 完成（或超时强关）之后，
	// 才停止 session/upstream，避免端口仍接受请求但核心运行时已经不可用。
	if cleanup != nil {
		if cleanupErr := cleanup(); cleanupErr != nil {
			if shutdownErr == nil {
				shutdownErr = cleanupErr
			} else {
				log.Printf("HTTP shutdown 与 runtime cleanup 均失败 runtime_err=%v", cleanupErr)
			}
		}
	}
	return shutdownErr
}

func managedAppServerExitedError(process *appserver.ManagedWebSocketProcess) error {
	if process == nil {
		return fmt.Errorf("托管 codex app-server WebSocket 已退出")
	}
	exitErr := process.ExitError()
	message := "托管 codex app-server WebSocket 已退出"
	if exitErr != nil {
		message += "：" + exitErr.Error()
	}
	diag := process.Diagnostics()
	if len(diag.StderrTail) > 0 {
		message += "\n最近 stderr：\n  " + strings.Join(diag.StderrTail, "\n  ")
	}
	return fmt.Errorf("%s", message)
}

func shutdownServeResources(manager *session.Manager, appServerWSProcess *appserver.ManagedWebSocketProcess) error {
	// listener 绑定失败，或 HTTP 已完成 drain 后，都必须回收运行时资源，避免会话/托管子进程成为孤儿。
	if manager != nil {
		manager.Shutdown()
	}
	if appServerWSProcess != nil {
		ctx, cancel := context.WithTimeout(context.Background(), serveRuntimeShutdownTimeout)
		err := appServerWSProcess.Shutdown(ctx)
		cancel()
		return err
	}
	return nil
}

func startManagedAppServerWebSocket(cfg config.Config) (*appserver.ManagedWebSocketProcess, error) {
	if strings.TrimSpace(cfg.AppServer.WSTokenFile) == "" {
		return nil, fmt.Errorf("app_server.ws_token_file 未配置；请运行 agentd setup --force 生成独立 app-server upstream token")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return appserver.StartManagedWebSocket(ctx, appserver.ManagedWebSocketOptions{
		CodexBin:    cfg.Codex.Bin,
		Env:         cfg.Codex.Env,
		Listen:      cfg.AppServer.Listen,
		WSTokenFile: cfg.AppServer.WSTokenFile,
	})
}

func runBrewService(action string, stdout, stderr io.Writer) error {
	brew, err := exec.LookPath("brew")
	if err != nil {
		return fmt.Errorf("未找到 Homebrew；请先在 Mac 安装 Homebrew：https://brew.sh")
	}
	cmd := exec.Command(brew, "services", action, config.AppName)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("执行 brew services %s %s 失败：%w", action, config.AppName, err)
	}
	return nil
}

const managedServiceUnitName = config.AppName + ".service"

const (
	defaultLogLineCount = 120
	maxLogLineCount     = 5000
)

func runManagedServiceForPlatform(goos string, action string, stdout, stderr io.Writer) error {
	switch goos {
	case "darwin":
		// macOS 继续完整复用已经验证的 Homebrew service 行为和输出。
		return runBrewService(action, stdout, stderr)
	case "linux":
		if err := ensureManagedServiceInstalled(goos); err != nil {
			return err
		}
		systemctl, err := exec.LookPath("systemctl")
		if err != nil {
			return fmt.Errorf("未找到 systemctl，无法管理 Linux user service：%w", err)
		}
		cmd := exec.Command(systemctl, "--user", action, managedServiceUnitName)
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("执行 systemctl --user %s %s 失败：%w", action, managedServiceUnitName, err)
		}
		return nil
	default:
		return unsupportedManagedServicePlatformError(goos)
	}
}

func runManagedLogsForPlatform(goos string, lineCount int, follow bool, stdout, stderr io.Writer) error {
	normalizedLineCount, err := normalizeLogLineCount(lineCount)
	if err != nil {
		return err
	}
	lineCount = normalizedLineCount
	switch goos {
	case "darwin":
		return runHomebrewLogs(lineCount, follow, stdout, stderr)
	case "linux":
		if err := ensureManagedServiceInstalled(goos); err != nil {
			return err
		}
		journalctl, err := exec.LookPath("journalctl")
		if err != nil {
			return fmt.Errorf("未找到 journalctl，无法读取 Linux user service 日志：%w", err)
		}
		args := []string{"--user", "-u", managedServiceUnitName, "-n", fmt.Sprint(lineCount), "--no-pager"}
		if follow {
			args = append(args, "-f")
		}
		// 只把 journalctl 接到当前终端，不复制日志、不维护额外状态。
		cmd := exec.Command(journalctl, args...)
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("读取 Linux user service 日志失败：%w", err)
		}
		return nil
	default:
		return unsupportedManagedServicePlatformError(goos)
	}
}

func normalizeLogLineCount(lineCount int) (int, error) {
	// <=0 沿用历史默认值，避免已有脚本行为突变；正数使用硬上限，防止一次读取
	// 极大 journal 或分配过大的 tail 环形缓冲。超限明确报错比静默 clamp 更利于脚本发现问题。
	if lineCount <= 0 {
		return defaultLogLineCount, nil
	}
	if lineCount > maxLogLineCount {
		return 0, fmt.Errorf("日志行数 -n 必须在 1 到 %d 之间；<=0 可使用默认 %d", maxLogLineCount, defaultLogLineCount)
	}
	return lineCount, nil
}

func runHomebrewLogs(lineCount int, follow bool, stdout, stderr io.Writer) error {
	path, err := homebrewLogPath()
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "日志文件：%s\n\n", path)
	if follow {
		tail, err := exec.LookPath("tail")
		if err != nil {
			return fmt.Errorf("未找到 tail 命令，无法跟随日志：%w", err)
		}
		cmd := exec.Command(tail, "-n", fmt.Sprint(lineCount), "-f", path)
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		return cmd.Run()
	}
	lines, err := tailLines(path, lineCount)
	if err != nil {
		return err
	}
	for _, line := range lines {
		fmt.Fprintln(stdout, line)
	}
	return nil
}

func ensureManagedServiceInstalled(goos string) error {
	switch goos {
	case "darwin":
		return nil
	case "linux":
		unitPath, err := linuxUserServiceUnitPath()
		if err != nil {
			return fmt.Errorf("定位 Linux user-systemd unit 失败：%w", err)
		}
		info, err := os.Stat(unitPath)
		if err == nil && info.Mode().IsRegular() {
			return nil
		}
		if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("检查 Linux user-systemd unit 失败：%w", err)
		}
		return fmt.Errorf("尚未安装 Linux user-systemd 服务：%s\n请先从正式 Release 解压目录运行：\n  bash ./scripts/install-linux.sh install", unitPath)
	default:
		return unsupportedManagedServicePlatformError(goos)
	}
}

func linuxUserServiceUnitPath() (string, error) {
	configHome := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME"))
	if configHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		configHome = filepath.Join(home, ".config")
	}
	return filepath.Join(configHome, "systemd", "user", managedServiceUnitName), nil
}

func unsupportedManagedServicePlatformError(goos string) error {
	return fmt.Errorf("当前系统 %q 不支持后台服务命令；只支持 macOS Homebrew 和 Linux user-systemd，可改用 agentd serve 前台运行", goos)
}

func printDoctorActions(w io.Writer, results doctor.Results) {
	printedHeader := false
	for _, check := range results.Checks {
		// warning 表示可选能力降级（当前是 Tailscale 缺失），不能混进阻断启动的错误清单。
		if check.OK || strings.EqualFold(strings.TrimSpace(check.Level), "warning") {
			continue
		}
		if !printedHeader {
			fmt.Fprintln(w, "\n需要处理：")
			printedHeader = true
		}
		fmt.Fprintf(w, "  ! %s：%s\n", check.Name, check.Message)
		if strings.TrimSpace(check.Fix) != "" {
			fmt.Fprintf(w, "    处理：%s\n", check.Fix)
		}
	}
}

func homebrewLogPath() (string, error) {
	candidates := []string{}
	if brew, err := exec.LookPath("brew"); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if out, err := exec.CommandContext(ctx, brew, "--prefix").Output(); err == nil {
			prefix := strings.TrimSpace(string(out))
			if prefix != "" {
				candidates = append(candidates, filepath.Join(prefix, "var", "log", config.AppName+".log"))
			}
		}
	}
	candidates = append(candidates,
		filepath.Join("/opt/homebrew/var/log", config.AppName+".log"),
		filepath.Join("/usr/local/var/log", config.AppName+".log"),
	)
	for _, path := range candidates {
		if stat, err := os.Stat(path); err == nil && !stat.IsDir() {
			return path, nil
		}
	}
	return "", fmt.Errorf("未找到 Mimi Mac 助手日志文件；请先运行 agentd up，或用 agentd serve 前台调试")
}

func tailLines(path string, count int) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("打开日志文件失败：%w", err)
	}
	defer file.Close()

	if count <= 0 {
		count = defaultLogLineCount
	}
	lines := make([]string, 0, count)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1024), 1024*1024)
	for scanner.Scan() {
		if len(lines) == count {
			copy(lines, lines[1:])
			lines[count-1] = scanner.Text()
			continue
		}
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("读取日志文件失败：%w", err)
	}
	return lines, nil
}

func hasFailedCheck(results doctor.Results, name string) bool {
	for _, check := range results.Checks {
		if check.Name == name && !check.OK {
			return true
		}
	}
	return false
}

func backupFile(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("备份配置前读取失败：%w", err)
	}
	backup := fmt.Sprintf("%s.bak-%s", path, time.Now().Format("20060102150405"))
	if err := os.WriteFile(backup, raw, 0o600); err != nil {
		return "", fmt.Errorf("写入配置备份失败：%w", err)
	}
	return backup, nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func expandUserPath(path string) string {
	value := strings.TrimSpace(path)
	if !strings.HasPrefix(value, "~/") {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return value
	}
	return filepath.Join(home, strings.TrimPrefix(value, "~/"))
}

func prepareDefaultConfigMigration(fs *flag.FlagSet, requestedPath string, notice io.Writer) error {
	explicitConfig := false
	fs.Visit(func(item *flag.Flag) {
		if item.Name == "config" {
			explicitConfig = true
		}
	})
	migrated, err := config.MigrateLegacyDefaultConfig(requestedPath, explicitConfig)
	if err != nil {
		return fmt.Errorf("迁移旧版默认配置失败：%w", err)
	}
	if migrated && notice != nil {
		// 只提示路径和保留策略，不输出 auth.token 或配置原文；JSON 命令的 stdout 也保持纯净。
		fmt.Fprintf(notice, "已复用旧版配置并迁移到新目录：%s（旧文件已保留）\n", config.PlatformDefaultPath())
	}
	return nil
}

func ensureBrewServiceDefaultConfig(requestedPath string) error {
	return ensureManagedServiceDefaultConfig("darwin", requestedPath)
}

func ensureManagedServiceDefaultConfig(goos string, requestedPath string) error {
	serviceLabel := ""
	switch goos {
	case "darwin":
		serviceLabel = "Homebrew service"
	case "linux":
		serviceLabel = "Linux user-systemd service"
	default:
		return unsupportedManagedServicePlatformError(goos)
	}
	requested, err := absoluteConfigPath(requestedPath)
	if err != nil {
		return fmt.Errorf("解析后台服务配置路径失败：%w", err)
	}
	platformDefault, err := absoluteConfigPath(config.PlatformDefaultPath())
	if err != nil {
		return fmt.Errorf("解析平台默认配置路径失败：%w", err)
	}
	if requested == platformDefault {
		return nil
	}
	return fmt.Errorf("后台服务不支持自定义配置：%s\n%s 固定读取平台默认配置：%s\n\n请改用前台运行：\n  agentd serve --config %s", requested, serviceLabel, platformDefault, shellQuoteArgument(requested))
}

func absoluteConfigPath(path string) (string, error) {
	value := strings.TrimSpace(path)
	if value == "" {
		return "", fmt.Errorf("配置路径不能为空")
	}
	abs, err := filepath.Abs(expandUserPath(value))
	if err != nil {
		return "", err
	}
	return filepath.Clean(abs), nil
}

func shellQuoteArgument(value string) string {
	// 单引号参数中的单引号用 '"'"' 重新拼接，确保空格、$ 和反引号都不会被 shell 展开。
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func printJSON(value any) error {
	return printJSONTo(os.Stdout, value)
}

func printJSONTo(w io.Writer, value any) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func ensureCodexCLIAvailable(configPath string) error {
	cfg, err := config.LoadForDoctor(configPath)
	if err != nil {
		return fmt.Errorf("读取 Codex 配置失败：%w", err)
	}
	bin := strings.TrimSpace(cfg.Codex.Bin)
	if bin == "" {
		bin = "codex"
	}
	if _, err := exec.LookPath(bin); err != nil {
		return fmt.Errorf("未找到 Codex CLI，Mimi Mac 助手还不能启动。\n\n请先在这台电脑安装并登录 Codex，然后重新运行：\n  agentd up")
	}
	return nil
}

func printSetupResult(w io.Writer, result agentsetup.Result) {
	if result.Created {
		fmt.Fprintln(w, "agentd setup 完成")
	} else {
		fmt.Fprintln(w, "agentd 配置已存在，未覆盖")
	}
	fmt.Fprintf(w, "\n配置文件：%s\n", result.ConfigPath)
	fmt.Fprintf(w, "项目扫描：%s\n", result.ScanRoot)
	if result.BrowseRoot != "" {
		fmt.Fprintf(w, "目录浏览授权根：%s\n", result.BrowseRoot)
	}
	fmt.Fprintf(w, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(w, "Token：%s\n", result.Token)
	fmt.Fprintf(w, "连接链接：%s\n", result.ConnectURL)
	fmt.Fprintf(w, "配对链接：%s\n", result.PairURL)
	if result.PairExpiresAt != "" {
		fmt.Fprintf(w, "二维码有效期至：%s\n", result.PairExpiresAt)
	}
	if result.AppServerListen != "" {
		fmt.Fprintf(w, "app-server upstream：%s\n", result.AppServerListen)
	}
	if result.AppServerTokenFile != "" {
		fmt.Fprintf(w, "app-server token file：%s\n", result.AppServerTokenFile)
	}
	printConnectionQRCode(w, result.PairURL)
	printWarnings(w, result.Warnings)
	fmt.Fprintln(w, "\n下一步：")
	fmt.Fprintln(w, "  1. agentd doctor --check-port")
	fmt.Fprintln(w, "  2. agentd start")
	fmt.Fprintln(w, "  3. agentd doctor")
	fmt.Fprintln(w, "  4. iPad App 打开设置，扫码连接；二维码不可用时再手动输入 Endpoint 和 Token")
}

func printPairResult(w io.Writer, result agentsetup.Result) {
	fmt.Fprintf(w, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(w, "Token：%s\n", result.Token)
	fmt.Fprintf(w, "连接链接：%s\n", result.ConnectURL)
	fmt.Fprintf(w, "配对链接：%s\n", result.PairURL)
	if result.PairExpiresAt != "" {
		fmt.Fprintf(w, "二维码有效期至：%s\n", result.PairExpiresAt)
	}
	printConnectionQRCode(w, result.PairURL)
	printWarnings(w, result.Warnings)
}

type qrOnlyPairOutput struct {
	Endpoint      string   `json:"endpoint"`
	PairURL       string   `json:"pair_url"`
	PairExpiresAt string   `json:"pair_expires_at"`
	Warnings      []string `json:"warnings,omitempty"`
}

func qrOnlyPairResult(result agentsetup.Result) qrOnlyPairOutput {
	// 安装日志可能被终端或 CI 留存；安全模式只暴露短期票据，绝不复制长期 Token/connect URL。
	return qrOnlyPairOutput{
		Endpoint:      result.Endpoint,
		PairURL:       result.PairURL,
		PairExpiresAt: result.PairExpiresAt,
		Warnings:      result.Warnings,
	}
}

func printQROnlyPairResult(w io.Writer, result agentsetup.Result) {
	safeResult := qrOnlyPairResult(result)
	fmt.Fprintf(w, "Endpoint：%s\n", safeResult.Endpoint)
	fmt.Fprintf(w, "配对链接：%s\n", safeResult.PairURL)
	if safeResult.PairExpiresAt != "" {
		fmt.Fprintf(w, "二维码有效期至：%s\n", safeResult.PairExpiresAt)
	}
	printConnectionQRCode(w, safeResult.PairURL)
	printWarnings(w, safeResult.Warnings)
}

func printServeConnection(w io.Writer, result agentsetup.Result) {
	printWarnings(w, result.Warnings)
	fmt.Fprintln(w, "\n用 iPad 扫这个二维码连接这台 Mac：")
	printConnectionQRCode(w, result.PairURL)
	if result.PairExpiresAt != "" {
		fmt.Fprintf(w, "二维码 10 分钟内有效，有效期至：%s\n", result.PairExpiresAt)
	}
	fmt.Fprintln(w, "扫不了时，在 iPad 的“高级手动连接”里填写：")
	fmt.Fprintf(w, "  地址：%s\n", result.Endpoint)
	fmt.Fprintf(w, "  访问码：%s\n", result.Token)
	fmt.Fprintln(w)
}

func maybePrintServeConnection(w *os.File, result agentsetup.Result) {
	if !isTerminalOutput(w) {
		return
	}
	printServeConnection(w, result)
}

func isTerminalOutput(w *os.File) bool {
	if w == nil {
		return false
	}
	info, err := w.Stat()
	if err != nil {
		return false
	}
	// Homebrew service 会把 stdout/stderr 写入日志文件；非交互式输出不打印连接二维码和 Token，
	// 避免外侧 agentd 访问凭证长期留在服务日志里。`agentd start` 仍会在当前终端显式打印二维码。
	return info.Mode()&os.ModeCharDevice != 0
}

func printConnectionQRCode(w io.Writer, connectURL string) {
	if strings.TrimSpace(connectURL) == "" {
		return
	}
	// 二维码只承载短期配对票据，不包含长期 agentd token 或本机 app-server upstream token。
	code, err := qrcode.New(connectURL, qrcode.Medium)
	if err != nil {
		fmt.Fprintf(w, "二维码生成失败：%v\n", err)
		return
	}
	fmt.Fprintln(w)
	fmt.Fprint(w, code.ToSmallString(false))
}

func printWarnings(w io.Writer, warnings []string) {
	for _, warning := range warnings {
		fmt.Fprintf(w, "警告：%s\n", warning)
	}
}

func waitForServiceHealth(ctx context.Context, endpoint string, timeout time.Duration) error {
	if timeout <= 0 {
		return nil
	}
	healthURL, err := healthCheckURL(endpoint)
	if err != nil {
		return err
	}
	return waitForServiceCheck(ctx, healthURL, "", "healthz", timeout, nil)
}

func waitForServiceReady(ctx context.Context, endpoint string, token string, expectedVersion string, timeout time.Duration) error {
	if timeout <= 0 {
		return nil
	}
	readyURL, err := readyCheckURL(endpoint)
	if err != nil {
		return err
	}
	// readiness 必须走和移动端相同的 Bearer 鉴权链路，并确认响应来自当前版本的 agentd。
	return waitForServiceCheck(ctx, readyURL, strings.TrimSpace(token), "readyz", timeout, func(body io.Reader) error {
		return validateReadyServiceVersion(body, expectedVersion)
	})
}

func waitForServiceCheck(ctx context.Context, checkURL string, token string, label string, timeout time.Duration, validate func(body io.Reader) error) error {
	deadline := time.Now().Add(timeout)
	client := http.Client{Timeout: time.Second}
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, checkURL, nil)
		if err != nil {
			return err
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(req)
		if err == nil {
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				if validate == nil {
					_, _ = io.Copy(io.Discard, resp.Body)
					_ = resp.Body.Close()
					return nil
				}
				err = validate(resp.Body)
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				if err == nil {
					return nil
				}
			} else {
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				err = fmt.Errorf("%s HTTP %d", label, resp.StatusCode)
			}
		}
		if time.Now().After(deadline) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(300 * time.Millisecond):
		}
	}
}

func validateReadyServiceVersion(body io.Reader, expectedVersion string) error {
	var payload struct {
		Version string `json:"version"`
	}
	decoder := json.NewDecoder(io.LimitReader(body, 256*1024))
	if err := decoder.Decode(&payload); err != nil {
		return readyVersionCheckError(fmt.Sprintf("readyz 响应不是有效 JSON：%v", err))
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return readyVersionCheckError("readyz 响应包含多个 JSON 值")
		}
		return readyVersionCheckError(fmt.Sprintf("readyz 响应包含畸形尾部数据：%v", err))
	}
	runningVersion := strings.TrimSpace(payload.Version)
	if runningVersion == "" {
		return readyVersionCheckError("readyz 响应缺少 server version")
	}
	expectedVersion = strings.TrimSpace(expectedVersion)
	if isDevelopmentAgentVersion(expectedVersion) || runningVersion == expectedVersion {
		return nil
	}
	return readyVersionCheckError(fmt.Sprintf("运行中的 agentd 版本为 %q，当前命令版本为 %q，可能仍是占用端口的旧服务", runningVersion, expectedVersion))
}

func isDevelopmentAgentVersion(value string) bool {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" || normalized == "devel" || normalized == "(devel)" {
		return true
	}
	return strings.Contains(normalized, "-next") || strings.Contains(normalized, "dirty")
}

func readyVersionCheckError(reason string) error {
	return fmt.Errorf("%s%s", reason, readyServiceRecoveryHint)
}

const readyServiceRecoveryHint = "，无法确认新的 Homebrew 服务已经接管当前 Endpoint。\n请运行：\n  brew services restart mimi-remote\n  agentd logs"

func healthCheckURL(endpoint string) (string, error) {
	return serviceCheckURL(endpoint, "/healthz")
}

func readyCheckURL(endpoint string) (string, error) {
	return serviceCheckURL(endpoint, "/api/readyz")
}

func serviceCheckURL(endpoint string, path string) (string, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("Endpoint 无效：%s", endpoint)
	}
	parsed.Path = path
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}
