//go:build darwin

package appserver

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	sharedDaemonOpenAITeamIdentifier     = "2DC432GLL2"
	sharedDaemonCodexSigningIdentifier   = "codex"
	sharedDaemonNodeSigningIdentifier    = "node"
	sharedDaemonDesktopSigningIdentifier = "com.openai.codex"
	sharedDaemonCodeSignRetryAttempts    = 16
	sharedDaemonCodeSignRetryInterval    = time.Second
	sharedDaemonCodeSignTimeout          = 20 * time.Second

	// launcher 只负责把真正的 node supervisor 放进独立 session 后退出。这样
	// LaunchAgent 仍是一条 one-shot job，普通 launcher 退出不会按同一进程组清理
	// supervisor；bootout 的 coalition 行为不作假设，活跃 socket 路径会避开它。
	// Browser 读取到的三级保持为 node_repl -> codex -> node。
	sharedDaemonNodeLauncherScript = `'use strict';
const { spawn } = require('node:child_process');
const argv = process.argv.slice(1);
if (argv.length < 5) process.exit(64);
const node = argv.shift();
const supervisor = spawn(node, ['-e', argv.shift(), '--', ...argv], {
  detached: true,
  env: process.env,
  stdio: ['ignore', 'inherit', 'inherit']
});
supervisor.once('error', () => process.exit(70));
supervisor.once('spawn', () => {
  supervisor.unref();
  process.exit(0);
});`

	// supervisor 必须保持为 app-server 的直接父进程。它不做自动重启或强杀；
	// child 退出后 supervisor 一并退出，由现有 gateway recovery 再次 kickstart
	// one-shot LaunchAgent，避免 socket 冲突时形成隐藏重启风暴。
	sharedDaemonNodeSupervisorScript = `'use strict';
const { spawn } = require('node:child_process');
const argv = process.argv.slice(1);
if (argv.length < 4) process.exit(64);
const child = spawn(argv[0], argv.slice(1), {
  detached: false,
  env: process.env,
  stdio: 'inherit'
});
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(signal, () => {
    // ChildProcess.killed 只表示“曾成功发送过信号”，不表示进程已经退出。
    // 以 exitCode/signalCode 判断，允许 SIGHUP 后仍继续转发真正的 stop。
    if (child.exitCode === null && child.signalCode === null) child.kill(signal);
  });
}
child.once('error', () => process.exit(70));
child.once('exit', (code, signal) => {
  process.exitCode = Number.isInteger(code) ? code : (signal ? 1 : 70);
});`
)

var (
	// 测试替换 resolver/validator 后可以使用临时可执行文件，不依赖本机安装
	// ChatGPT.app，也不会伪造系统 codesign 输出。
	sharedDaemonResolveSupervisorNode = resolveSharedDaemonSupervisorNode
	sharedDaemonValidateSupervisor    = validateSharedDaemonSupervisorBinaries
	sharedDaemonValidateSignedRuntime = validateSignedSharedDaemonRuntime
)

func resolveSharedDaemonSupervisorNode(codexBin string) (string, error) {
	candidates := make([]string, 0, 5)
	resources := filepath.Dir(filepath.Clean(codexBin))
	if filepath.Base(resources) == "Resources" && filepath.Base(codexBin) == "codex" {
		candidates = append(candidates, filepath.Join(resources, "cua_node", "bin", "node"))
	}
	candidates = append(candidates,
		"/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
		"/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
	)
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "cua_node", "bin", "node"),
			filepath.Join(home, "Applications", "Codex.app", "Contents", "Resources", "cua_node", "bin", "node"),
		)
	}

	seen := map[string]struct{}{}
	for _, candidate := range candidates {
		absolute, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		absolute = filepath.Clean(absolute)
		if _, exists := seen[absolute]; exists {
			continue
		}
		seen[absolute] = struct{}{}
		info, err := os.Stat(absolute)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
			continue
		}
		if _, err := sharedDaemonDesktopBundleForNode(absolute); err != nil {
			continue
		}
		canonical, err := filepath.EvalSymlinks(absolute)
		if err != nil {
			continue
		}
		return filepath.Clean(canonical), nil
	}
	return "", fmt.Errorf("未找到 Codex Desktop 内置的签名 node supervisor")
}

func sharedDaemonDesktopBundleForNode(nodePath string) (string, error) {
	canonical, err := filepath.EvalSymlinks(nodePath)
	if err != nil {
		return "", fmt.Errorf("解析 node supervisor 路径失败")
	}
	canonical = filepath.Clean(canonical)
	wantSuffix := filepath.Join("Contents", "Resources", "cua_node", "bin", "node")
	if !strings.HasSuffix(canonical, string(filepath.Separator)+wantSuffix) {
		return "", fmt.Errorf("node supervisor 不在 Codex Desktop bundle 内")
	}
	bundle := canonical
	for range 5 {
		bundle = filepath.Dir(bundle)
	}
	if filepath.Ext(bundle) != ".app" {
		return "", fmt.Errorf("node supervisor 缺少 App bundle 边界")
	}
	return bundle, nil
}

func validateSharedDaemonSupervisorBinaries(nodePath string, codexPath string) error {
	bundlePath, err := sharedDaemonDesktopBundleForNode(nodePath)
	if err != nil {
		return err
	}
	for _, target := range []struct {
		path       string
		identifier string
		name       string
	}{
		{path: bundlePath, identifier: sharedDaemonDesktopSigningIdentifier, name: "Codex Desktop"},
		{path: nodePath, identifier: sharedDaemonNodeSigningIdentifier, name: "node supervisor"},
		{path: codexPath, identifier: sharedDaemonCodexSigningIdentifier, name: "Codex app-server"},
	} {
		// `codesign -d` 只会展示签名声明，即使页哈希已经损坏也可能输出看似
		// 正确的 TeamIdentifier。必须先用指定 requirement 验证真实签名，再把
		// metadata 作为 hardened-runtime 的补充约束。
		if verifyErr := verifySharedDaemonCodeSignature(target.path, target.identifier); verifyErr != nil {
			return fmt.Errorf("%s 代码签名验证失败", target.name)
		}
		metadata, metadataErr := sharedDaemonCodeSigningMetadata(target.path)
		if metadataErr != nil {
			return fmt.Errorf("%s 缺少可读取的代码签名", target.name)
		}
		if metadataErr = validateSharedDaemonCodeSignatureMetadata(metadata, target.identifier); metadataErr != nil {
			return fmt.Errorf("%s 不是受支持的 OpenAI 签名程序", target.name)
		}
	}
	return nil
}

func verifySharedDaemonCodeSignature(path string, expectedIdentifier string) error {
	ctx, cancel := context.WithTimeout(context.Background(), sharedDaemonCodeSignTimeout)
	defer cancel()
	requirement := fmt.Sprintf(
		`=identifier %q and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = %q`,
		expectedIdentifier,
		sharedDaemonOpenAITeamIdentifier,
	)
	return retrySharedDaemonCodeSignature(
		ctx,
		sharedDaemonCodeSignRetryAttempts,
		sharedDaemonCodeSignRetryInterval,
		func() error {
			cmd := exec.CommandContext(
				ctx,
				"/usr/bin/codesign",
				"--verify",
				"--strict",
				"--test-requirement",
				requirement,
				path,
			)
			configureManagedCommand(cmd)
			return cmd.Run()
		},
		waitForSharedDaemonCodeSignatureRetry,
	)
}

func retrySharedDaemonCodeSignature(
	ctx context.Context,
	attempts int,
	interval time.Duration,
	verify func() error,
	wait func(context.Context, time.Duration) error,
) error {
	if attempts < 1 {
		return fmt.Errorf("代码签名校验重试次数必须大于零")
	}
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		if err := verify(); err == nil {
			return nil
		} else {
			lastErr = err
		}
		if attempt == attempts {
			break
		}
		if err := wait(ctx, interval); err != nil {
			return fmt.Errorf("等待代码签名稳定失败：%w", err)
		}
	}
	return lastErr
}

func waitForSharedDaemonCodeSignatureRetry(ctx context.Context, interval time.Duration) error {
	timer := time.NewTimer(interval)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func sharedDaemonCodeSigningMetadata(path string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/codesign", "-d", "--verbose=4", path)
	configureManagedCommand(cmd)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

// Browser 原生 peer authorization 使用运行中进程的 TeamIdentifier 与
// signingIdentifier。这里对落盘候选执行同一组 metadata 约束；真正提交 stable
// owner 前还会从 socket peer 反查 PID/PPID/argv/真实可执行文件并二次验证。
func validateSharedDaemonCodeSignatureMetadata(metadata string, expectedIdentifier string) error {
	hasIdentifier := false
	hasTeam := false
	hasHardenedRuntime := false
	for _, line := range strings.Split(metadata, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "Identifier="+expectedIdentifier:
			hasIdentifier = true
		case line == "TeamIdentifier="+sharedDaemonOpenAITeamIdentifier:
			hasTeam = true
		case strings.HasPrefix(line, "CodeDirectory ") && strings.Contains(line, "(runtime)"):
			hasHardenedRuntime = true
		}
	}
	if !hasIdentifier || !hasTeam || !hasHardenedRuntime {
		return fmt.Errorf("代码签名 metadata 不符合共享 daemon 约束")
	}
	return nil
}

func sharedDaemonSupervisorProgramArguments(nodePath string, codexPath string) []string {
	return []string{
		nodePath,
		"-e",
		sharedDaemonNodeLauncherScript,
		"--",
		nodePath,
		sharedDaemonNodeSupervisorScript,
		codexPath,
		"app-server",
		"--listen",
		"unix://",
	}
}

func validateSignedSharedDaemonRuntime(
	ctx context.Context,
	options LocalDaemonOptions,
	socketPath string,
) error {
	codexPath, err := resolveSharedDaemonCodexBin(options.CodexBin)
	if err != nil {
		return err
	}
	nodePath, err := sharedDaemonResolveSupervisorNode(codexPath)
	if err != nil {
		return err
	}

	listener, err := inspectSharedDaemonListenerProcess(ctx, socketPath)
	if err != nil {
		return err
	}
	if listener.ParentPID <= 1 {
		return fmt.Errorf("共享 daemon listener 缺少签名 node supervisor")
	}
	supervisor, err := inspectSharedDaemonProcessIdentity(listener.ParentPID, os.Getuid())
	if err != nil {
		return err
	}
	if err := validateSignedSharedDaemonProcessChain(
		listener,
		supervisor,
		os.Getuid(),
		nodePath,
		codexPath,
		validateSharedDaemonRunningCodeSignature,
	); err != nil {
		return err
	}

	// PID、启动时间和命令行在两次取证间任一变化都 fail closed，避免把 PID
	// 复用或 socket 竞争赢家错误归因给刚安装的 supervisor。
	confirmedListener, err := inspectSharedDaemonListenerProcess(ctx, socketPath)
	if err != nil || confirmedListener != listener {
		return fmt.Errorf("共享 daemon listener 在身份复核期间发生变化")
	}
	confirmedSupervisor, err := inspectSharedDaemonProcessIdentity(supervisor.PID, os.Getuid())
	if err != nil || confirmedSupervisor != supervisor {
		return fmt.Errorf("共享 daemon supervisor 在身份复核期间发生变化")
	}
	return nil
}

func validateSignedSharedDaemonProcessChain(
	listener sharedDaemonListenerProcess,
	supervisor sharedDaemonListenerProcess,
	expectedUID int,
	nodePath string,
	codexPath string,
	validateSignature func(int, string) error,
) error {
	if listener.ParentPID <= 1 || listener.ParentPID != supervisor.PID {
		return fmt.Errorf("共享 daemon listener 父进程与 node supervisor 不一致")
	}
	if err := validateSharedDaemonListenerProcess(listener, expectedUID, codexPath); err != nil {
		return err
	}
	if validateSignature == nil {
		return fmt.Errorf("共享 daemon 缺少运行态签名验证器")
	}
	if err := validateSignature(listener.PID, sharedDaemonCodexSigningIdentifier); err != nil {
		return fmt.Errorf("共享 daemon listener 运行态签名无效：%w", err)
	}
	if supervisor.UID != expectedUID {
		return fmt.Errorf("共享 daemon supervisor 不属于当前用户")
	}
	if err := validateSharedDaemonNodeSupervisorProcess(supervisor, nodePath, codexPath); err != nil {
		return err
	}
	if err := validateSignature(supervisor.PID, sharedDaemonNodeSigningIdentifier); err != nil {
		return fmt.Errorf("共享 daemon supervisor 运行态签名无效：%w", err)
	}
	return nil
}

func validateSharedDaemonNodeSupervisorProcess(
	process sharedDaemonListenerProcess,
	nodePath string,
	codexPath string,
) error {
	if process.PID <= 1 || process.UID != os.Getuid() {
		return fmt.Errorf("共享 daemon supervisor 进程身份无效")
	}
	if strings.TrimSpace(process.Executable) == "" || !sameCanonicalPath(process.Executable, nodePath) {
		return fmt.Errorf("共享 daemon supervisor 不是 Codex Desktop 内置 node")
	}
	fields := sharedDaemonCommandFields(process.Command)
	if len(fields) < 7 || !sameCanonicalPath(fields[0], nodePath) || fields[1] != "-e" ||
		fields[2] != sharedDaemonNodeSupervisorScript {
		return fmt.Errorf("共享 daemon supervisor 命令行不符合预期")
	}
	index := 3
	if fields[index] == "--" {
		index++
	}
	if len(fields) != index+4 || !sameCanonicalPath(fields[index], codexPath) ||
		fields[index+1] != "app-server" || fields[index+2] != "--listen" || fields[index+3] != "unix://" {
		return fmt.Errorf("共享 daemon supervisor child 参数不符合预期")
	}
	return nil
}

func sharedDaemonCommandFields(command string) []string {
	if strings.Contains(command, "\x00") {
		fields := make([]string, 0, 8)
		for _, field := range strings.Split(command, "\x00") {
			if field != "" {
				fields = append(fields, field)
			}
		}
		return fields
	}
	return strings.Fields(strings.TrimSpace(command))
}
