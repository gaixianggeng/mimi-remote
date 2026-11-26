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
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/diagnosticlog"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
	"github.com/skip2/go-qrcode"
)

// 正式发布由 GoReleaser 使用 -X 注入版本号；源码构建明确标记为 devel，避免首个正式版本被误判为开发构建。
var version = "devel"

var runAgentSetup = agentsetup.Run

var issuePairingForCommand = requestPairIssue

// managedServicePlatform 默认等于编译目标，只作为平台命令选择的窄测试缝隙；
// 生产代码不修改它，也不根据配置或环境变量伪装操作系统。
var managedServicePlatform = runtime.GOOS

const serveHTTPDrainTimeout = 5 * time.Second

func main() {
	if onboardingJSONCommand(os.Args) {
		log.SetOutput(io.Discard)
	}
	if status := commandExit(os.Args, os.Stdout, os.Stderr); status != 0 {
		os.Exit(status)
	}
}

func run(args []string) error {
	return runCommand(args, os.Stdout, os.Stderr, os.Stderr)
}

func runCommand(args []string, stdout, stderr, notice io.Writer) error {
	cmd := "serve"
	if len(args) > 1 && !strings.HasPrefix(args[1], "-") {
		cmd = args[1]
		args = append([]string{args[0]}, args[2:]...)
	}
	if cmd == "serve" {
		hideStandaloneManagedServiceConsole(args)
	}
	if cmd != "version" {
		if err := ensureProcessUserEnvironment(); err != nil {
			return err
		}
	}

	switch cmd {
	case "version":
		fmt.Println(version)
		return nil
	case "installer-maintenance":
		return runInstallerMaintenance(args[1:])
	case "preflight":
		return runPreflight(args, stdout, stderr)
	case "setup":
		return runSetupWithWriters(args, stdout, notice)
	case "up":
		return runUpWithWriters(args, stdout, notice)
	case "start":
		return runStart(args, stdout, notice)
	case "restart":
		return runRestart(args, stdout, notice)
	case "stop":
		return runStop(args)
	case "status":
		return runStatusWithWriters(args, stdout, notice)
	case "logs":
		return runLogs(args)
	case "pair":
		return runPairWithWriters(args, stdout, notice)
	case "tailcat":
		return runTailcatWithWriters(args, stdout, notice)
	case "network":
		return runNetworkWithWriters(args, stdout, notice)
	case "workspace":
		return runWorkspaceWithWriters(args, stdout, notice)
	case "runtime":
		return runRuntimeWithIO(args, os.Stdin, stdout, notice)
	case "repair-codex-session":
		return runCodexSessionRepair(args)
	case "handoff-command":
		return runHandoffCommand(args)
	case "codex-front":
		return runCodexFront(args)
	case "doctor":
		return runDoctorWithWriters(args, stdout, notice)
	case "diagnostics":
		return runDiagnostics(args)
	case "check-config":
		return runCheckConfig(args)
	case "serve":
		return runServe(args)
	default:
		return fmt.Errorf("未知命令 %q，可用命令：preflight、up、setup、start、restart、stop、status、logs、pair、tailcat、network、workspace、runtime、repair-codex-session、handoff-command、codex-front、serve、doctor、diagnostics、check-config、version", cmd)
	}
}

func runSetup(args []string) error {
	return runSetupWithWriters(args, os.Stdout, os.Stderr)
}

func runServe(args []string) (serveErr error) {
	logFile := ""
	managedService := false
	loggingReady := false
	defer func() {
		if serveErr != nil && !loggingReady && logFile != "" {
			recordDiagnosticStartupFailure(logFile)
		}
	}()
	cfg, registry, checker, err := loadRuntimeConfig(args, false, func(fs *flag.FlagSet) {
		fs.StringVar(&logFile, "log-file", "", "把有容量上限的诊断日志写入指定文件")
		fs.BoolVar(&managedService, "managed-service", false, "由当前平台的用户级后台服务启动")
	})
	if err != nil {
		return err
	}
	closeManagedRuntime, err := prepareManagedServeRuntime(managedService)
	if err != nil {
		return err
	}
	if closeManagedRuntime != nil {
		defer closeManagedRuntime()
	}
	diagnostics, closeLog, err := configureServeFileLogging(logFile)
	if err != nil {
		return err
	}
	if closeLog != nil {
		defer closeLog()
	}
	loggingReady = true
	// 必须早于 serve 启动受管 Codex app-server：子进程环境在启动时确定。
	stopSystemProxyRelay, err := startSystemProxyRelay()
	if err != nil {
		return err
	}
	defer stopSystemProxyRelay()
	diagnosticlog.Record("service", "started", diagnosticlog.Fields{})
	err = serve(cfg, registry, checker, diagnostics)
	if err != nil {
		diagnosticlog.Record("service", "failed", diagnosticlog.Fields{})
	} else {
		diagnosticlog.Record("service", "stopped", diagnosticlog.Fields{})
	}
	return err
}

func runUp(args []string) error {
	return runUpWithWriters(args, os.Stdout, os.Stderr)
}

func runUpWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := onboardingFlagSet("up", args[1:])
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	scanRoot := fs.String("scan-root", "", "项目扫描根目录，默认优先使用 ~/code，其次使用当前目录")
	browseRoot := fs.String("browse-root", "", "移动设备浏览授权目录，新安装默认使用项目扫描目录")
	listen := fs.String("listen", "", "agentd 监听地址，新安装默认只监听本机")
	appServerSSHTarget := fs.String("app-server-ssh-target", "", "共享 Codex App Server 的 SSH 目标；macOS 默认 127.0.0.1，Linux 仅显式指定时使用")
	waitTimeout := fs.Duration("wait", 10*time.Second, "等待后台服务健康检查时间，设置 0 可跳过")
	noPair := fs.Bool("no-pair", false, "启动成功后不输出二维码、Endpoint 和长期访问码，适合 Agent/自动化")
	bootstrap := fs.Bool("installer-bootstrap", false, "Windows 安装器单次初始化或维护")
	lan := fs.Bool("lan-enabled", false, "安装器已核验的局域网设置")
	existing := fs.Bool("require-existing", false, "升级时必须复用已有身份")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := parseOnboardingFlags(fs, args[1:]); err != nil {
		return err
	}

	if err := validateBootstrapFlags(fs, managedServicePlatform, *bootstrap, *noPair, *asJSON, *scanRoot); err != nil {
		return err
	}
	if err := ensureNoLegacyCodexExperimentResidue(); err != nil {
		return err
	}
	if err := ensureManagedServiceDefaultConfig(managedServicePlatform, *configPath); err != nil {
		return invalidOnboardingRequest(err)
	}
	if err := ensureManagedServiceInstalled(managedServicePlatform); err != nil {
		return onboardingFailure("service_not_registered", "service_daemon", onboardingConfigured(*configPath), err)
	}

	if !*asJSON {
		fmt.Fprintln(stdout, "正在准备 Mimi Remote 助手...")
	}
	options := agentsetup.Options{
		ConfigPath:         *configPath,
		LegacyPath:         setupLegacyPath(fs),
		ScanRoot:           *scanRoot,
		BrowseRoot:         *browseRoot,
		Listen:             *listen,
		AppServerSSHTarget: *appServerSSHTarget,
		LocalServiceOnly:   true,
	}
	action := "start"
	var lanErr error
	if *bootstrap {
		options.SaveOnly = true
		options.PendingWorkspace = *scanRoot == ""
		options.BrowseRoot = *scanRoot
		if *lan {
			lanErr = ensurePlatformLANAccessAllowed()
		}
		if lanErr != nil {
			*lan = false
		}
		options.InstallerLAN = lan
		options.RequireExisting = *existing
		action = "reload-or-start"
	}
	result, err := runAgentSetup(context.Background(), options)
	if err != nil {
		return err
	}
	setupMigrationNotice(stderr, result)

	serviceStdout := io.Writer(stdout)
	serviceStderr := io.Writer(stderr)
	if *asJSON {
		serviceStdout = io.Discard
		serviceStderr = io.Discard
	}
	if err := manageCoreService(context.Background(), managedServicePlatform, action, result.Endpoint, result.Token, version, *waitTimeout, serviceStdout, serviceStderr); err != nil {
		return err
	}
	if lanErr != nil {
		return onboardingFailure("lan_firewall_blocked", "network_lan", true, errors.New("核心服务已启动，局域网仍关闭。请在受信任的专用网络中重试维护。"))
	}
	if !*noPair {
		pair, err := requestPairIssue(context.Background(), result.ConfigPath, agentsetup.PairingNetworkAuto)
		if err != nil {
			return err
		}
		pair.Created = result.Created
		result = pair
	}
	if *asJSON {
		output := upJSONOutput(result, true, "", *noPair)
		if *waitTimeout <= 0 {
			delete(output, "service_ok")
			output["start_submitted"] = true
		}
		return printJSONTo(stdout, output)
	}
	if *waitTimeout > 0 {
		fmt.Fprintln(stdout, "Mimi Remote 助手已准备好")
	}

	if *noPair {
		// Agent/自动化日志可以保留安装进度和安全警告，但不能留存任何连接凭据。
		printWarnings(stdout, safeUpWarnings(result))
	} else {
		printServeConnection(stdout, result)
	}
	fmt.Fprintln(stdout, "常用命令：")
	fmt.Fprintln(stdout, "  agentd status       查看当前连接状态")
	fmt.Fprintln(stdout, "  agentd pair         刷新配对二维码")
	fmt.Fprintln(stdout, "  agentd stop         停止当前平台后台服务")
	fmt.Fprintln(stdout, "  agentd doctor --fix 自动检查并修复常见问题")
	return nil
}

func upJSONOutput(result agentsetup.Result, serviceOK bool, serviceError string, noPair bool) map[string]any {
	output := map[string]any{
		"service_ok": serviceOK,
	}
	if !noPair {
		// 保持既有 JSON 输出兼容；调用方只有显式启用安全模式时才收窄字段。
		output["result"] = result
	} else {
		output["ok"] = serviceOK
		output["version"] = version
		if len(result.Warnings) > 0 {
			output["warnings"] = safeUpWarnings(result)
		}
	}
	if serviceError != "" {
		if noPair {
			serviceError = safeUpServiceError(serviceError, result)
		}
		output["service_error"] = serviceError
	}
	return output
}

func safeUpServiceError(serviceError string, result agentsetup.Result) string {
	// 先替换包含其他凭据的长 URL，再替换 Token 和 Endpoint，避免部分替换后无法命中完整值。
	return publicStatusError(
		errors.New(serviceError),
		result.ConnectURL,
		result.PairURL,
		result.Token,
		result.Endpoint,
	)
}

func safeUpWarnings(result agentsetup.Result) []string {
	warnings := make([]string, 0, len(result.Warnings))
	for _, warning := range result.Warnings {
		warnings = append(warnings, safeUpServiceError(warning, result))
	}
	return warnings
}

// managedServiceCommandCopy 收拢 start 与 restart 之间唯一的差异。
// 两个命令的迁移、就绪检查和配对输出流程完全一致，因此共用一份实现。
type managedServiceCommandCopy struct {
	flagSetName     string
	noPairHelp      string
	pairHint        string
	startingMessage string
	serviceAction   string
	readyMessage    string
}

func runStart(args []string, stdout, stderr io.Writer) error {
	return runManagedServiceCommand(args, stdout, stderr, managedServiceCommandCopy{
		flagSetName:     "start",
		noPairHelp:      "启动成功后不输出二维码和长期访问码，适合托盘与自动化",
		pairHint:        "setup",
		startingMessage: "正在启动 Mimi Remote 后台服务...",
		serviceAction:   "start",
		readyMessage:    "agentd 后台服务已启动",
	})
}

func runRestart(args []string, stdout, stderr io.Writer) error {
	return runManagedServiceCommand(args, stdout, stderr, managedServiceCommandCopy{
		flagSetName:     "restart",
		noPairHelp:      "重启成功后不输出二维码和长期访问码，适合远程自动化",
		pairHint:        "up",
		startingMessage: "正在重启 Mimi Remote 助手...",
		serviceAction:   "restart",
		readyMessage:    "Mimi Remote 助手已重新连接",
	})
}

func runManagedServiceCommand(args []string, stdout, stderr io.Writer, copy managedServiceCommandCopy) error {
	fs := onboardingFlagSet(copy.flagSetName, args[1:])
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	waitTimeout := fs.Duration("wait", 8*time.Second, "等待后台服务健康检查时间，设置 0 可跳过")
	asJSON := fs.Bool("json", false, "输出 JSON")
	noPair := fs.Bool("no-pair", false, copy.noPairHelp)
	if err := parseOnboardingFlags(fs, args[1:]); err != nil {
		return err
	}
	if err := prepareRequiredConfig(fs, *configPath, stderr); err != nil {
		return err
	}
	if err := ensureNoLegacyCodexExperimentResidue(); err != nil {
		return err
	}
	if err := ensureManagedServiceDefaultConfig(managedServicePlatform, *configPath); err != nil {
		return invalidOnboardingRequest(err)
	}
	if err := ensureManagedServiceInstalled(managedServicePlatform); err != nil {
		return onboardingFailure("service_not_registered", "service_daemon", onboardingConfigured(*configPath), err)
	}
	if err := prepareSavedCoreConfig(*configPath); err != nil {
		return err
	}

	result, err := agentsetup.LocalServiceAccess(*configPath)
	if err != nil {
		return fmt.Errorf("读取连接信息失败，请先执行 agentd %s：%w", copy.pairHint, err)
	}

	serviceOutput, serviceErrors := stdout, stderr
	if *asJSON {
		serviceOutput, serviceErrors = io.Discard, io.Discard
	}
	fmt.Fprintln(serviceOutput, copy.startingMessage)
	if err := manageCoreService(context.Background(), managedServicePlatform, copy.serviceAction, result.Endpoint, result.Token, version, *waitTimeout, serviceOutput, serviceErrors); err != nil {
		return err
	}
	var pairErr error
	if !*noPair {
		pairResult, err := issuePairingForCommand(context.Background(), *configPath, agentsetup.PairingNetworkAuto)
		if err != nil {
			// 服务已经启动或重启成功；配对属于可选交接步骤，失败时降级为警告而不是让启停命令返回非零。
			pairErr = err
		} else {
			result = pairResult
		}
	}
	if *asJSON {
		payload := map[string]any{"ok": true, "service_ok": true, "version": version}
		if *waitTimeout <= 0 {
			payload = map[string]any{"ok": true, "start_submitted": true}
		}
		if pairErr != nil {
			payload["pair_ok"] = false
			payload["pair_error"] = publicStatusError(pairErr, result.ConnectURL, result.PairURL, result.Token, result.Endpoint)
		}
		return printJSONTo(stdout, payload)
	}
	if *waitTimeout > 0 {
		fmt.Fprintln(stdout, copy.readyMessage)
	}
	if !*noPair {
		if pairErr != nil {
			safePairError := publicStatusError(pairErr, result.ConnectURL, result.PairURL, result.Token, result.Endpoint)
			printManagedServicePairingFailure(stderr, *configPath, setupLegacyPath(fs), managedServicePlatform, safePairError, *waitTimeout > 0)
		} else {
			printServeConnection(stdout, result)
		}
	}
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

	fmt.Fprintln(os.Stdout, "正在停止 Mimi Remote 助手...")
	if err := runManagedServiceForPlatform(managedServicePlatform, "stop", os.Stdout, os.Stderr); err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, "Mimi Remote 助手已停止")
	return nil
}

func runStatus(args []string) error {
	return runStatusWithWriters(args, os.Stdout, os.Stderr)
}

func runStatusWithWriters(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	asJSON := fs.Bool("json", false, "输出 JSON")
	pairingOnly := fs.Bool("pairing", false, "只输出配对前提检查结果")
	includeRuntime := fs.Bool("runtime", false, "附加本机 Codex / Claude 运行时状态")
	refreshRuntime := fs.Bool("runtime-refresh", false, "强制刷新并等待本机运行时状态")
	inspectNetworkPolicy := fs.Bool("network-policy", false, "附加 Windows 防火墙和默认网络类别检查")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *pairingOnly {
		if *asJSON || *includeRuntime || *refreshRuntime || *inspectNetworkPolicy {
			return errors.New("status --pairing 仅支持人类可读输出，不能与 --json、--runtime 或 --network-policy 同时使用")
		}
		// 诊断命令保持只读：交由 preflight 的只读 legacy 预览读取旧配置，避免复制迁移或在旧配置异常时提前退出。
		readiness := inspectPairingReadiness(context.Background(), *configPath, setupLegacyPath(fs), managedServicePlatform)
		printPairingReadiness(stdout, readiness)
		return nil
	}
	if *includeRuntime && !*asJSON {
		return errors.New("status --runtime 只能与 --json 一起使用")
	}
	if *refreshRuntime && (!*includeRuntime || !*asJSON) {
		return errors.New("status --runtime-refresh 只能与 --runtime --json 一起使用")
	}
	if *inspectNetworkPolicy && !*asJSON {
		return errors.New("status --network-policy 只能与 --json 一起使用")
	}
	if managedServicePlatform == "windows" && isManagedCoreConfig(*configPath) {
		// Task Scheduler 的 Query 是只读且幂等的。先确认安装器注册的任务仍存在，
		// 再做 HTTP 健康检查，才能区分“尚未安装”和“任务已安装但服务离线”。
		if err := ensureManagedServiceInstalled(managedServicePlatform); err != nil {
			return err
		}
	}
	if err := prepareDefaultConfigMigration(fs, *configPath, stderr); err != nil {
		return err
	}

	if err := agentsetup.CheckRepairSource(config.ExpandPath(*configPath)); err != nil {
		return err
	}
	cfg, registry, _, err := loadRuntimeConfigFromPath(*configPath, true)
	if err != nil {
		return err
	}
	result := agentsetup.StatusFromConfig(context.Background(), *configPath, cfg)
	loopbackEndpoint := loopbackServiceEndpoint(result.Endpoint)
	networkStatus := configuredAgentNetworkStatus(cfg)
	var networkStatusCh chan agentNetworkStatus
	if *inspectNetworkPolicy {
		networkStatusCh = make(chan agentNetworkStatus, 1)
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			networkStatusCh <- inspectPlatformNetworkStatus(ctx, cfg)
		}()
	}
	serviceStatus := agentServiceStatus{}
	managed := isManagedCoreConfig(*configPath)
	if managed {
		owner, results, err := inspectCoreService(context.Background(), managedServicePlatform, loopbackEndpoint, result.Token, version, "")
		if owner.manager == "" && err == nil {
			err = errors.New("后台服务未运行")
		}
		serviceStatus.ReadyErr = err
		if owner.manager == "" {
			serviceStatus.ProcessErr = err
		}
		if results.Version != "" {
			serviceStatus.ReadinessResults = &results
		}
	} else {
		serviceStatus = probeAgentServiceStatus(context.Background(), loopbackEndpoint, result.Token, version, 2*time.Second)
	}
	var runtimeStatusCh chan runtimeStatusResult
	if *refreshRuntime && !serviceStatus.Ready() {
		return fmt.Errorf("强制刷新运行时状态失败：%w", serviceStatus.ReadyErr)
	}
	if *includeRuntime && serviceStatus.Ready() {
		runtimeStatusCh = make(chan runtimeStatusResult, 1)
		go func() {
			runtimeStatusCh <- fetchRuntimeStatusForCommand(
				loopbackEndpoint,
				result.Token,
				*refreshRuntime,
				*configPath,
			)
		}()
	}
	var runtimeStatus runtimeStatusResult
	if runtimeStatusCh != nil {
		runtimeStatus = <-runtimeStatusCh
	}
	if networkStatusCh != nil {
		networkStatus = <-networkStatusCh
	}
	doctorResults := doctor.Results{
		OK:      false,
		Version: version,
		Checks: []doctor.Check{{
			Name:    "service-readiness",
			OK:      false,
			Level:   "error",
			Message: "agentd readyz 暂不可用或版本不匹配",
			Fix:     "运行 agentd logs 查看服务与 Codex app-server 状态",
		}},
	}
	if serviceStatus.ReadinessResults != nil {
		doctorResults = *serviceStatus.ReadinessResults
	}
	if !serviceStatus.Ready() && doctorResults.OK {
		// 失败 HTTP 理论上会携带 ok=false；若旧服务返回了矛盾结构，仍以探测结果为准。
		doctorResults.OK = false
		doctorResults.Checks = append(doctorResults.Checks, doctor.Check{
			Name:    "service-readiness",
			OK:      false,
			Level:   "error",
			Message: "agentd readyz 暂不可用或版本不匹配",
			Fix:     "运行 agentd logs 查看服务与 Codex app-server 状态",
		})
	}
	if check := networkPolicyDoctorCheck(networkStatus); check.Name != "" {
		doctorResults.OK = false
		doctorResults.Checks = append(doctorResults.Checks, check)
	}
	status := serviceStatusFields(serviceStatus, result.Token)
	status["version"] = version
	status["endpoint"] = result.Endpoint
	status["config_path"] = result.ConfigPath
	status["workspace_confirmed"] = config.ReadPreflightSnapshot(config.ExpandPath(*configPath)).Confirmed
	status["projects"] = len(registry.List())
	status["doctor_ok"] = doctorResults.OK
	status["doctor"] = doctorResults
	status["network_status"] = networkStatus
	var modules *config.ModuleStatus
	moduleStatusState := moduleStatusUnavailable
	if serviceStatus.Ready() {
		modules, moduleStatusState = fetchModuleStatusForCommand(loopbackEndpoint, result.Token, *configPath)
	}
	status["module_status_state"] = moduleStatusState
	if modules != nil {
		status["module_status"] = modules
	}
	status["pair_expires"] = result.PairExpiresAt
	if runtimeStatusCh != nil {
		if err := attachRuntimeStatus(status, runtimeStatus, *refreshRuntime); err != nil {
			return err
		}
	}
	if *asJSON {
		return printJSONTo(stdout, status)
	}

	fmt.Fprintln(stdout, "Mimi Remote 助手状态")
	fmt.Fprintf(stdout, "\n版本：%s\n", version)
	fmt.Fprintf(stdout, "配置：%s\n", result.ConfigPath)
	fmt.Fprintf(stdout, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(stdout, "项目数：%d\n", len(registry.List()))
	printServiceStatus(stdout, serviceStatus, result.Token)
	if doctorResults.OK {
		fmt.Fprintln(stdout, "环境：检查通过")
	} else {
		fmt.Fprintln(stdout, "环境：需要处理")
		printDoctorActions(stdout, doctorResults)
	}
	readiness := inspectPairingReadiness(context.Background(), *configPath, setupLegacyPath(fs), managedServicePlatform)
	fmt.Fprintln(stdout, "\n配对前提：")
	printPairingReadiness(stdout, readiness)
	fmt.Fprintln(stdout, "\n下一步：")
	pairingCmds := newPairingCommandContext(*configPath, managedServicePlatform)
	if readiness.Ready {
		pairCmd := readiness.PairCommand
		if pairCmd == "" {
			pairCmd = pairingCmds.cmd("pair", "--qr-only")
		}
		fmt.Fprintf(stdout, "  %-23s 显示短期配对二维码\n", pairCmd)
	} else {
		fmt.Fprintf(stdout, "  %-23s 查看配对前提与修复命令\n", pairingCmds.cmd("status", "--pairing"))
	}
	fmt.Fprintln(stdout, "  agentd doctor --fix     自动检查并修复常见问题")
	fmt.Fprintln(stdout, "  agentd logs             查看最近日志")
	return nil
}

func serviceStatusFields(serviceStatus agentServiceStatus, token string) map[string]any {
	status := map[string]any{
		"process_ok": serviceStatus.ProcessOK(),
		// service_ok 是 Linux 安装脚本已使用的兼容字段；从现在起明确表示 readyz 通过，
		// 不能再用只有进程存活语义的 healthz 冒充移动端可用。
		"service_ok": serviceStatus.Ready(),
	}
	if serviceStatus.ReadinessResults != nil {
		if runningVersion := strings.TrimSpace(serviceStatus.ReadinessResults.Version); runningVersion != "" {
			// version 是当前命令自身版本；server_version 才是 Endpoint 上真实运行的服务版本。
			// 两者同时返回，Mac App 才能识别安装更新后仍驻留的旧 LaunchAgent。
			status["server_version"] = runningVersion
		}
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
	ProcessErr       error
	ReadyErr         error
	ReadinessResults *doctor.Results
}

func (s agentServiceStatus) ProcessOK() bool {
	return s.ProcessErr == nil
}

func (s agentServiceStatus) Ready() bool {
	return s.ReadyErr == nil
}

func probeAgentServiceStatus(ctx context.Context, endpoint string, token string, expectedVersion string, timeout time.Duration) agentServiceStatus {
	// 两个探测必须独立执行：healthz 只回答进程是否存活，readyz 验证归属、鉴权、版本和控制面配置。
	// 并行执行让 status 总耗时受单个 2 秒窗口约束。
	type readinessProbeResult struct {
		results doctor.Results
		err     error
	}
	healthResult := make(chan error, 1)
	readinessResult := make(chan readinessProbeResult, 1)
	go func() {
		healthResult <- waitForServiceHealth(ctx, endpoint, timeout)
	}()
	go func() {
		results, err := waitForServiceReadyResults(ctx, endpoint, token, expectedVersion, timeout)
		readinessResult <- readinessProbeResult{results: results, err: err}
	}()

	processErr := <-healthResult
	readiness := <-readinessResult
	var readinessResultsPointer *doctor.Results
	if len(readiness.results.Checks) > 0 || strings.TrimSpace(readiness.results.Version) != "" {
		readinessResultsPointer = &readiness.results
	}
	return agentServiceStatus{
		ProcessErr:       processErr,
		ReadyErr:         readiness.err,
		ReadinessResults: readinessResultsPointer,
	}
}

func printServiceStatus(w io.Writer, status agentServiceStatus, token string) {
	if status.ProcessOK() {
		fmt.Fprintln(w, "进程存活：是")
	} else {
		fmt.Fprintf(w, "进程存活：否（%s）\n", publicStatusError(status.ProcessErr, token))
	}
	if status.Ready() {
		fmt.Fprintln(w, "后台服务就绪：是")
	} else {
		fmt.Fprintf(w, "后台服务就绪：否（%s）\n", publicStatusError(status.ReadyErr, token))
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
	fs := onboardingFlagSet("pair", args[1:])
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	networkName := fs.String("network", string(agentsetup.PairingNetworkAuto), "二维码网络：auto、tailscale 或 lan")
	asJSON := fs.Bool("json", false, "输出 JSON")
	qrOnly := fs.Bool("qr-only", false, "只输出短期配对信息和二维码，不输出长期 Token")
	if err := parseOnboardingFlags(fs, args[1:]); err != nil {
		return err
	}
	network, err := agentsetup.ParsePairingNetwork(*networkName)
	if err != nil {
		return invalidOnboardingRequest(err)
	}
	if err := prepareRequiredConfig(fs, *configPath, stderr); err != nil {
		return err
	}
	result, err := requestPairIssue(context.Background(), *configPath, network)
	if err != nil {
		return err
	}
	if *asJSON {
		if *qrOnly {
			return printJSONTo(stdout, qrOnlyPairResult(result))
		}
		return printJSONTo(stdout, struct {
			OK bool `json:"ok"`
			agentsetup.Result
		}{true, result})
	}
	if *qrOnly {
		printQROnlyPairResult(stdout, result)
		return nil
	}
	printPairResult(stdout, result)
	return nil
}

func runDoctor(args []string) error {
	return runDoctorWithWriters(args, os.Stdout, os.Stderr)
}

func runDoctorWithWriters(args []string, stdout, stderr io.Writer) error {
	doctorCtx, cancelDoctor := context.WithTimeout(context.Background(), 75*time.Second)
	defer cancelDoctor()
	checkPort := false
	asJSON := false
	fix := false
	configPath := config.DefaultPath()
	fs := onboardingFlagSet("doctor", args[1:])
	fs.StringVar(&configPath, "config", config.DefaultPath(), "配置文件路径")
	fs.BoolVar(&checkPort, "check-port", false, "检查当前配置端口是否可监听")
	fs.BoolVar(&asJSON, "json", false, "只输出 JSON")
	fs.BoolVar(&fix, "fix", false, "自动修复安全的常见问题")
	permissionFile := fs.String("permission-file", "", "与 --fix 一起修复配置所引用的外部凭据文件权限")
	if err := parseOnboardingFlags(fs, args[1:]); err != nil {
		return err
	}
	if *permissionFile != "" && !fix {
		return invalidOnboardingRequest(errors.New("--permission-file 需要 --fix"))
	}
	if !fix {
		if err := prepareDefaultConfigMigration(fs, configPath, stderr); err != nil {
			return err
		}
	} else {
		if err := ensureNoLegacyCodexExperimentResidue(); err != nil {
			return err
		}
		// A legacy default may supply the existing identity, but doctor never
		// creates one. Validate the original bytes before copying anything.
		repairPath := config.ExpandPath(configPath)
		if !onboardingConfigured(configPath) {
			legacy := setupLegacyPath(fs)
			if _, err := config.CheckCompanionPermissions(repairPath); err == nil && legacy != "" && onboardingConfigured(legacy) && config.CheckSetupWriteAvailable(repairPath) == nil {
				repairPath = legacy
			}
		}
		handled, err := repairDoctorFileAccess(doctorCtx, repairPath, *permissionFile, asJSON, stdout)
		if handled || err != nil {
			return err
		}
		if !onboardingConfigured(configPath) {
			result, err := runAgentSetup(doctorCtx, agentsetup.Options{ConfigPath: configPath, LegacyPath: setupLegacyPath(fs), RequireExisting: true, LocalServiceOnly: true})
			if err != nil {
				return err
			}
			setupMigrationNotice(stderr, result)
		}
	}
	_, _, checker, err := loadRuntimeConfigFromPath(configPath, true)
	if err != nil {
		if errors.Is(err, config.ErrLegacyAppServerConfiguration) {
			return err
		}
		if !fix {
			return err
		}
		if !onboardingConfigured(configPath) {
			return onboardingFailure("config_missing", "config_store", false, err)
		}
		return onboardingFailure("config_invalid", "config_store", true, err)
	}
	results := checker.Run(doctorCtx, checkPort)
	fixes := []string{}
	restartRequired := false
	if fix {
		fixes, restartRequired, checker, results, err = repairDoctor(doctorCtx, configPath, checkPort, results, asJSON)
		if err != nil {
			return err
		}
	}
	if asJSON {
		if fix && !results.OK {
			return fmt.Errorf("doctor 检查未通过")
		}
		payload := any(results)
		if fix {
			payload = map[string]any{
				"fixes":            fixes,
				"results":          results,
				"restart_required": restartRequired,
			}
		}
		if err := printJSONTo(stdout, payload); err != nil {
			return err
		}
	} else {
		if fix && len(fixes) > 0 {
			fmt.Fprintln(stdout, "已修复：")
			for _, item := range fixes {
				fmt.Fprintf(stdout, "  OK %s\n", item)
			}
			fmt.Fprintln(stdout)
		}
		doctor.Print(stdout, results)
		if fix && restartRequired {
			fmt.Fprintln(stdout, "\n配置已更新，需要重启 agentd 后生效。")
		}
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
	if !forDoctor {
		if err := ensureNoLegacyCodexExperimentResidue(); err != nil {
			return config.Config{}, nil, nil, err
		}
	}
	if !forDoctor && fileExists(*configPath) {
		if err := prepareSavedCoreConfig(*configPath); err != nil {
			return config.Config{}, nil, nil, err
		}
	}
	var (
		cfg config.Config
		err error
	)
	if forDoctor {
		cfg, err = config.LoadForDoctor(*configPath)
	} else {
		cfg, err = config.LoadForService(*configPath)
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

func repairDoctor(
	ctx context.Context,
	configPath string,
	checkPort bool,
	current doctor.Results,
	_ bool,
) ([]string, bool, *doctor.Checker, doctor.Results, error) {
	if hasFailedCheck(current, "legacy-codex-experiment") {
		return nil, false, nil, current, fmt.Errorf("检测到旧 Codex Desktop 共享实验残留；doctor --fix 不会终止任务或改写 owner")
	}
	if err := ensureNoLegacyCodexExperimentResidue(); err != nil {
		return nil, false, nil, current, err
	}
	configPath = config.ExpandPath(configPath)
	fixes := []string{}
	restartRequired := false
	needsSetup := false
	if _, err := os.Stat(configPath); err != nil {
		if os.IsNotExist(err) {
			needsSetup = true
		} else {
			return nil, false, nil, current, fmt.Errorf("读取配置状态失败：%w", err)
		}
	}
	if hasFailedCheck(current, "token") || hasFailedCheck(current, "projects") {
		needsSetup = true
	}
	if needsSetup {
		return nil, false, nil, current, blockedDoctorRebuild(configPath, current)
	}
	if hasFailedCheck(current, "config-file") {
		fixed, err := config.RepairPrivatePermissions(configPath)
		if err != nil {
			return nil, false, nil, current, fmt.Errorf("修复配置文件权限失败：%w", err)
		}
		if fixed {
			fixes = append(fixes, "已修复配置文件的访问权限")
		}
	}
	if hasFailedCheck(current, "app-server") {
		if err := ensureAppServerTransportMigration(ctx, configPath, os.Getenv("AGENTD_APP_SERVER_SSH_TARGET")); err != nil {
			return nil, false, nil, current, err
		}
		fixes = append(fixes, "已在共享 App Server 预检通过后原子迁移旧配置")
		restartRequired = true
	}
	if hasFailedCheck(current, "codex") || hasFailedCheck(current, "codex-app-server") {
		// 旧的绝对路径失效或 Windows CLI 缺少 single-writer 基线时只修复
		// codex.bin；无法发现安全替代项则保留原 Doctor 结果继续给出升级指引。
		codexPath, repaired, repairErr := agentsetup.RepairCodexBin(configPath)
		if repairErr == nil && repaired {
			fixes = append(fixes, "已恢复 Codex CLI 路径："+codexPath)
			restartRequired = true
		}
	}
	_, _, checker, err := loadRuntimeConfigFromPath(configPath, true)
	if err != nil {
		return nil, false, nil, current, err
	}
	return fixes, restartRequired, checker, checker.Run(ctx, checkPort), nil
}

func serve(cfg config.Config, registry *projects.Registry, checker *doctor.Checker, diagnostics *managedDiagnosticLogs) error {
	installationID, err := loadInstallationIDForServe()
	if err != nil {
		return err
	}
	serviceCtx, cancelService := context.WithCancel(context.Background())
	defer cancelService()
	gate := platformServeLANGate(serviceCtx, cfg)
	listeners, localOnly, err := bindServeListenersWithPolicy(cfg, moduleListenAddresses(cfg), listenModuleAddress, gate)
	if err != nil {
		return err
	}
	defer func() {
		for _, l := range listeners {
			_ = l.Close()
		}
	}()
	checker.StartFileAccessPreflight()
	routerOptions := httpapi.RouterOptions{EnableHostMetadata: true, BoundListeners: listeners}
	if gate != nil {
		routerOptions.NetworkAvailability = gate.Availability
		routerOptions.ConfirmLANPolicy = gate.Confirm
		routerOptions.LANPolicyDiagnostic = gate.Diagnostic
	}
	if cfg.Codex.IsEnabled() {
		upstream := startOptionalCodex(serviceCtx, cfg, checker.ConfigPath())
		defer upstream.Shutdown()
		routerOptions.AppServerSSH = upstream
	}
	routerOptions.ConfigPath = checker.ConfigPath()
	if diagnostics != nil {
		routerOptions.DiagnosticLogs = diagnostics
		token, err := diagnosticControlToken(checker.ConfigPath(), true)
		if err != nil {
			return errors.New("无法准备本机诊断凭据")
		}
		routerOptions.DiagnosticControlToken = token
	}
	apiHandler, apiRouter := httpapi.NewRouterWithInstallationIDAndOptions(
		cfg,
		registry,
		checker,
		version,
		installationID,
		routerOptions,
	)
	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           apiHandler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, len(listeners)+1)
	for _, listener := range listeners {
		listener := listener
		go func() {
			log.Printf("agentd listening on http://%s", listener.Addr())
			errCh <- server.Serve(listener)
		}()
	}
	if localOnly {
		log.Print(staleTailscaleListenWarning)
	} else if isTerminalOutput(os.Stdout) {
		go func() {
			// The foreground serve process owns these listeners, even when its
			// config has the default system-manager path. Verify the foreground peer.
			result, err := requestPairIssueWithDial(serviceCtx, checker.ConfigPath(), agentsetup.PairingNetworkAuto, coreDialForOwner(false))
			if err == nil && serviceCtx.Err() == nil {
				maybePrintServeConnection(os.Stdout, result)
			}
		}()
	}
	stopCh := make(chan os.Signal, 1)
	stopSignals := notifyServeSignals(stopCh)
	defer stopSignals()
	return waitForServeExit(stopCh, errCh, func() error {
		return shutdownServe(server, serveHTTPDrainTimeout, func() error {
			cancelService()
			apiRouter.Shutdown()
			return nil
		})
	})
}

func loadInstallationIDForServe() (string, error) {
	installationID, err := config.LoadOrCreateInstallationID()
	if err != nil {
		return "", fmt.Errorf("加载 agentd 安装身份失败：%w", err)
	}
	return installationID, nil
}

func agentDListenAddresses(configured string, allowLAN bool) []string {
	address := strings.TrimSpace(configured)
	host, port, err := net.SplitHostPort(address)
	if err != nil || port == "" {
		return []string{address}
	}

	normalizedHost := strings.Trim(strings.TrimSpace(host), "[]")
	ip := net.ParseIP(normalizedHost)
	if allowLAN {
		// 只有显式开启局域网后才扩大到 IPv4 通配监听；它同时覆盖 LAN、Tailscale 和 loopback。
		return []string{net.JoinHostPort("0.0.0.0", port)}
	}
	// loopback 和通配地址本身已经覆盖 127.0.0.1；只在绑定具体的 Tailscale/局域网地址时
	// 增加同端口 loopback，避免为了 Catalyst 本机直连而把服务扩大暴露到所有网卡。
	if normalizedHost == "" || strings.EqualFold(normalizedHost, "localhost") ||
		(ip != nil && (ip.IsLoopback() || ip.IsUnspecified())) {
		return []string{address}
	}
	return []string{address, net.JoinHostPort("127.0.0.1", port)}
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
			// net/http 管理，会在随后关闭 Router 时结束每条连接自己的 SSH proxy。
			_ = server.Close()
		}
	}
	// 必须在 HTTP listener 已关闭、普通请求 drain 完成（或超时强关）之后，
	// 才停止 agentd 自己的 session 和 proxy；共享 App Server 始终留给其他入口。
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

func runBrewService(ctx context.Context, action string, stdout, stderr io.Writer) error {
	brew, err := exec.LookPath("brew")
	if err != nil {
		return fmt.Errorf("未找到 Homebrew；请先在 Mac 安装 Homebrew：https://brew.sh")
	}
	cmd := exec.CommandContext(ctx, brew, "services", action, config.AppName)
	cmd.WaitDelay = time.Second
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("执行 brew services %s %s 失败：%w", action, config.AppName, err)
	}
	return nil
}

const homebrewServiceLabel = "homebrew.mxcl." + config.AppName

func restartHomebrewService(ctx context.Context, stdout, stderr io.Writer) error {
	launchctl, err := exec.LookPath("launchctl")
	if err != nil {
		return fmt.Errorf("未找到 launchctl，无法原子重启 Homebrew 后台服务：%w", err)
	}

	target := fmt.Sprintf("gui/%d/%s", os.Getuid(), homebrewServiceLabel)
	cmd := exec.CommandContext(ctx, launchctl, "kickstart", "-k", target)
	cmd.WaitDelay = time.Second
	cmd.Stdout = stdout
	var launchctlStderr strings.Builder
	cmd.Stderr = &launchctlStderr
	if kickstartErr := cmd.Run(); kickstartErr == nil {
		return nil
	} else {
		// 核心设计：已加载的服务必须使用 launchd 的单次 kickstart 原子重启。
		// 不能执行 brew services restart 的 bootout + bootstrap 两步序列，
		// 否则 agentd 托管的 Codex 发起重启时，会随第一步退出而执行不到第二步。
		detail := strings.TrimSpace(launchctlStderr.String())
		kickstartErr = fmt.Errorf("launchctl kickstart %s 失败：%w", target, kickstartErr)
		if detail != "" {
			kickstartErr = fmt.Errorf("%w：%s", kickstartErr, detail)
		}
		if !strings.Contains(strings.ToLower(detail), "could not find service") {
			return kickstartErr
		}
		err = kickstartErr
	}

	// restart 也应能恢复一个尚未加载或已经 stop 的服务。此时当前命令不可能
	// 由该后台服务托管，可以安全地交给 Homebrew 完成一次 start/bootstrap。
	fmt.Fprintln(stderr, "Homebrew 后台服务当前未加载，改为重新启动...")
	if startErr := runBrewService(ctx, "start", stdout, stderr); startErr != nil {
		return fmt.Errorf("原子重启失败（%v），且重新启动服务失败：%w", err, startErr)
	}
	return nil
}

const managedServiceUnitName = config.AppName + ".service"

const (
	defaultLogLineCount = 120
	maxLogLineCount     = 5000
)

func runManagedServiceForPlatform(goos string, action string, stdout, stderr io.Writer) error {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	return runManagedServiceContext(ctx, goos, action, stdout, stderr)
}

func runManagedServiceContext(ctx context.Context, goos, action string, stdout, stderr io.Writer) error {
	switch goos {
	case "darwin":
		if action == "restart" {
			return restartHomebrewService(ctx, stdout, stderr)
		}
		// start/stop 继续复用 Homebrew；restart 必须保持为上面的 launchd 单次操作。
		return runBrewService(ctx, action, stdout, stderr)
	case "linux":
		if err := ensureManagedServiceInstalled(goos); err != nil {
			return err
		}
		systemctl, err := exec.LookPath("systemctl")
		if err != nil {
			return fmt.Errorf("未找到 systemctl，无法管理 Linux user service：%w", err)
		}
		cmd := exec.CommandContext(ctx, systemctl, "--user", action, managedServiceUnitName)
		cmd.WaitDelay = time.Second
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("执行 systemctl --user %s %s 失败：%w", action, managedServiceUnitName, err)
		}
		return nil
	case "windows":
		return runWindowsManagedService(ctx, action, stdout, stderr)
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
	case "windows":
		return runWindowsManagedLogs(lineCount, follow, stdout, stderr)
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
	case "windows":
		return ensureWindowsManagedTaskInstalled()
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
	return fmt.Errorf("当前系统 %q 不支持后台服务命令；支持 macOS Homebrew、Linux user-systemd 和 Windows Task Scheduler，可改用 agentd serve 前台运行", goos)
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
	return "", fmt.Errorf("未找到 Mimi Remote 助手日志文件；请先运行 agentd up，或用 agentd serve 前台调试")
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

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
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
		code := "config_recovery_required"
		if config.PrivateFileDiagnostic(err) == "config_permissions_unsafe" {
			code = "config_permissions_unsafe"
		}
		return onboardingFailure(code, "config_store", true, fmt.Errorf("迁移旧版默认配置失败：%w", err))
	}
	if migrated && notice != nil {
		// 只提示路径和保留策略，不输出 auth.token 或配置原文；JSON 命令的 stdout 也保持纯净。
		fmt.Fprintf(notice, "已复用旧版配置并迁移到新目录：%s（旧文件已保留）\n", config.PlatformDefaultPath())
	}
	return nil
}

func ensureManagedServiceDefaultConfig(goos string, requestedPath string) error {
	serviceLabel := ""
	switch goos {
	case "darwin":
		serviceLabel = "Homebrew service"
	case "linux":
		serviceLabel = "Linux user-systemd service"
	case "windows":
		serviceLabel = "Windows 当前用户计划任务"
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
	abs, err := filepath.Abs(config.ExpandPath(value))
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

// Resolve only the in-memory launch configuration. Future starts rediscover an
// automatic installation; SSH-only hosts never require a local Codex binary.
func resolveLaunchCodex(ctx context.Context, cfg *config.Config) error {
	if !cfg.Codex.IsEnabled() || strings.EqualFold(cfg.AppServer.Transport, "ssh") {
		return nil
	}
	candidate, err := agentsetup.ResolveRuntime(ctx, agentsetup.CodexRuntime(cfg.Codex, cfg.AppServer.Transport))
	if err != nil {
		return fmt.Errorf("Codex CLI 不可用，请检查配置的路径或升级 Codex：%w", err)
	}
	cfg.Codex.Bin = candidate.Path
	return nil
}

var inspectLegacyCodexExperimentResidue = appserver.LegacyCodexExperimentResidue

func ensureNoLegacyCodexExperimentResidue() error {
	residue, err := inspectLegacyCodexExperimentResidue()
	if err != nil {
		return err
	}
	if residue == "" {
		return nil
	}
	return onboardingFailure("legacy_codex_residue", "config_store", true, fmt.Errorf(
		"检测到旧 Codex Desktop 共享实验残留（%s）。为避免两套 owner 混跑，agentd 已拒绝启动；请先退出 Codex Desktop，并用旧实验版本关闭共享",
		residue,
	))
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
	if result.AppServerSSHTarget != "" {
		fmt.Fprintf(w, "app-server SSH target：%s\n", result.AppServerSSHTarget)
	}
	printConnectionQRCode(w, result.PairURL)
	printWarnings(w, result.Warnings)
	fmt.Fprintln(w, "\n下一步：")
	fmt.Fprintln(w, "  1. agentd doctor --check-port")
	fmt.Fprintln(w, "  2. agentd start")
	fmt.Fprintln(w, "  3. agentd doctor")
	fmt.Fprintln(w, "  4. 在移动设备上的 Mimi Remote 打开设置，扫码连接；二维码不可用时选择“手动连接”，把 Endpoint 填入连接地址、Token 填入访问码")
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
	OK                  bool                      `json:"ok"`
	Endpoint            string                    `json:"endpoint"`
	Network             agentsetup.PairingNetwork `json:"network,omitempty"`
	TailscaleDNSName    string                    `json:"tailscale_dns_name,omitempty"`
	TailscaleDeviceName string                    `json:"tailscale_device_name,omitempty"`
	PairURL             string                    `json:"pair_url"`
	PairExpiresAt       string                    `json:"pair_expires_at"`
	Warnings            []string                  `json:"warnings,omitempty"`
}

func qrOnlyPairResult(result agentsetup.Result) qrOnlyPairOutput {
	// 安装日志可能被终端或 CI 留存；安全模式只暴露短期票据，绝不复制长期 Token/connect URL。
	return qrOnlyPairOutput{
		OK:                  true,
		Endpoint:            result.Endpoint,
		Network:             result.Network,
		TailscaleDNSName:    result.TailscaleDNSName,
		TailscaleDeviceName: result.TailscaleDeviceName,
		PairURL:             result.PairURL,
		PairExpiresAt:       result.PairExpiresAt,
		Warnings:            result.Warnings,
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

// serveConnectionQRHeading 同时用于 --no-pair 泄漏测试，避免文案调整后断言静默失效。
const serveConnectionQRHeading = "用移动设备扫这个二维码连接这台电脑："

func printServeConnection(w io.Writer, result agentsetup.Result) {
	printWarnings(w, result.Warnings)
	fmt.Fprintln(w, "\n"+serveConnectionQRHeading)
	printConnectionQRCode(w, result.PairURL)
	if result.PairExpiresAt != "" {
		fmt.Fprintf(w, "二维码 10 分钟内有效，有效期至：%s\n", result.PairExpiresAt)
	}
	fmt.Fprintln(w, "扫不了时，在移动设备上的 Mimi Remote 选择“手动连接”，填写：")
	fmt.Fprintf(w, "  连接地址：%s\n", result.Endpoint)
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
	_, err := waitForServiceReadyResults(ctx, endpoint, token, expectedVersion, timeout)
	return err
}

func waitForServiceReadyResults(
	ctx context.Context,
	endpoint string,
	token string,
	expectedVersion string,
	timeout time.Duration,
) (doctor.Results, error) {
	if timeout <= 0 {
		return doctor.Results{}, nil
	}
	readyURL, err := readyCheckURL(endpoint)
	if err != nil {
		return doctor.Results{}, err
	}
	parsed, err := url.Parse(readyURL)
	if err != nil || parsed.Scheme != "http" || parsed.User != nil || !net.ParseIP(parsed.Hostname()).IsLoopback() || strings.TrimSpace(token) == "" {
		return doctor.Results{}, errors.New("就绪检查需要本机回环地址和服务凭据")
	}
	deadline := time.Now().Add(timeout)
	client := coreHTTPClient(ctx, "")
	client.Timeout = time.Second
	var latest doctor.Results
	for {
		req, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, readyURL, nil)
		if requestErr != nil {
			return latest, requestErr
		}
		if value := strings.TrimSpace(token); value != "" {
			req.Header.Set("Authorization", "Bearer "+value)
		}
		resp, requestErr := client.Do(req)
		var ownership agentsetup.PreflightHostError
		if errors.As(requestErr, &ownership) {
			return latest, ownership
		}
		if requestErr == nil {
			decoded, decodeErr := decodeReadyServiceResults(resp.Body, expectedVersion)
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			if strings.TrimSpace(decoded.Version) != "" || len(decoded.Checks) > 0 {
				latest = decoded
			}
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				if decodeErr == nil {
					return latest, nil
				}
				requestErr = decodeErr
			} else {
				requestErr = fmt.Errorf("readyz HTTP %d", resp.StatusCode)
			}
		}
		if time.Now().After(deadline) {
			return latest, requestErr
		}
		select {
		case <-ctx.Done():
			return latest, ctx.Err()
		case <-time.After(300 * time.Millisecond):
		}
	}
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

func decodeReadyServiceResults(body io.Reader, expectedVersion string) (doctor.Results, error) {
	var payload doctor.Results
	decoder := json.NewDecoder(io.LimitReader(body, 256*1024))
	if err := decoder.Decode(&payload); err != nil {
		return doctor.Results{}, readyVersionCheckError(fmt.Sprintf("readyz 响应不是有效 JSON：%v", err))
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return doctor.Results{}, readyVersionCheckError("readyz 响应包含多个 JSON 值")
		}
		return doctor.Results{}, readyVersionCheckError(fmt.Sprintf("readyz 响应包含畸形尾部数据：%v", err))
	}
	runningVersion := strings.TrimSpace(payload.Version)
	if runningVersion == "" {
		return doctor.Results{}, readyVersionCheckError("readyz 响应缺少 server version")
	}
	expectedVersion = strings.TrimSpace(expectedVersion)
	if agentsetup.AgentVersionsCompatible(expectedVersion, runningVersion) {
		if !payload.OK {
			return payload, errors.New("后台服务尚未就绪")
		}
		return payload, nil
	}
	return payload, readyVersionCheckError(fmt.Sprintf("运行中的 agentd 版本为 %q，当前命令版本为 %q，可能仍是占用端口的旧服务", runningVersion, expectedVersion))
}

func readyVersionCheckError(reason string) error {
	return onboardingFailure("service_version_mismatch", "service_daemon", true, fmt.Errorf("%s%s", reason, readyServiceRecoveryHint))
}

const readyServiceRecoveryHint = "，无法确认新的 Homebrew 服务已经接管当前 Endpoint。\n请运行：\n  agentd restart\n  agentd logs"

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

func loopbackServiceEndpoint(endpoint string) string {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.Port() == "" {
		return endpoint
	}
	// setup/start/restart/status 都是本机控制面命令。保留对外展示的 Endpoint，
	// 但健康与就绪探测固定走同端口 loopback，避免自检绕 Tailscale 后受 Wi-Fi/打洞抖动影响。
	parsed.Host = net.JoinHostPort("127.0.0.1", parsed.Port())
	return parsed.String()
}
