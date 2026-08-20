//go:build darwin

package appserver

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSharedDaemonSupervisorSigningTargetsValidateOnlyExecutedBinaries(t *testing.T) {
	bundlePath := filepath.Join(t.TempDir(), "ChatGPT.app")
	nodePath := filepath.Join(bundlePath, "Contents", "Resources", "cua_node", "bin", "node")
	codexPath := filepath.Join(bundlePath, "Contents", "Resources", "codex")
	if err := os.MkdirAll(filepath.Dir(nodePath), 0o700); err != nil {
		t.Fatalf("创建 node 目录失败：%v", err)
	}
	for _, path := range []string{nodePath, codexPath} {
		if err := os.WriteFile(path, []byte("binary"), 0o700); err != nil {
			t.Fatalf("创建签名目标 fixture 失败：%v", err)
		}
	}

	targets, err := sharedDaemonSupervisorSigningTargets(nodePath, codexPath)
	if err != nil {
		t.Fatalf("解析签名目标失败：%v", err)
	}
	if len(targets) != 2 {
		t.Fatalf("只能验证实际执行的 node/codex，不能递归验证 Desktop bundle：%+v", targets)
	}
	if targets[0].path != nodePath || targets[0].identifier != sharedDaemonNodeSigningIdentifier ||
		targets[1].path != codexPath || targets[1].identifier != sharedDaemonCodexSigningIdentifier {
		t.Fatalf("签名目标错误：%+v", targets)
	}
}

func TestRetrySharedDaemonCodeSignatureWaitsForTransientShutdownWindow(t *testing.T) {
	verifyCalls := 0
	waitCalls := 0
	err := retrySharedDaemonCodeSignature(
		context.Background(),
		4,
		time.Second,
		func() error {
			verifyCalls++
			if verifyCalls < 3 {
				return errors.New("temporary codesign failure")
			}
			return nil
		},
		func(context.Context, time.Duration) error {
			waitCalls++
			return nil
		},
	)
	if err != nil {
		t.Fatalf("退出阶段的瞬时签名失败应在稳定后恢复：%v", err)
	}
	if verifyCalls != 3 || waitCalls != 2 {
		t.Fatalf("签名退避次数错误：verify=%d wait=%d", verifyCalls, waitCalls)
	}
}

func TestRetrySharedDaemonCodeSignatureFailsClosedAfterBound(t *testing.T) {
	wantErr := errors.New("invalid signature")
	verifyCalls := 0
	waitCalls := 0
	err := retrySharedDaemonCodeSignature(
		context.Background(),
		3,
		0,
		func() error {
			verifyCalls++
			return wantErr
		},
		func(context.Context, time.Duration) error {
			waitCalls++
			return nil
		},
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("持续无效签名必须 fail closed：%v", err)
	}
	if verifyCalls != 3 || waitCalls != 2 {
		t.Fatalf("必须严格遵守重试上限：verify=%d wait=%d", verifyCalls, waitCalls)
	}
}

func TestRetrySharedDaemonCodeSignaturePreservesLastFailureWhenWaitStops(t *testing.T) {
	verifyErr := errors.New("invalid signature")
	waitErr := context.DeadlineExceeded
	err := retrySharedDaemonCodeSignature(
		context.Background(),
		3,
		time.Second,
		func() error { return verifyErr },
		func(context.Context, time.Duration) error { return waitErr },
	)
	if !errors.Is(err, verifyErr) || !errors.Is(err, waitErr) {
		t.Fatalf("等待中止时必须同时保留截止时间和最后一次验签错误：%v", err)
	}
	if !strings.Contains(err.Error(), "最后一次代码签名验证失败") {
		t.Fatalf("错误信息缺少最后一次验签上下文：%v", err)
	}
}

func TestSharedDaemonCodeSignatureResultPreservesTimeoutAndVerificationFailure(t *testing.T) {
	verifyErr := errors.New("invalid signature")
	err := sharedDaemonCodeSignatureResult(verifyErr, context.DeadlineExceeded)
	if !errors.Is(err, verifyErr) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("超时不能覆盖真实验签错误：%v", err)
	}
	if !strings.Contains(err.Error(), "代码签名校验超时") || !strings.Contains(err.Error(), "invalid signature") {
		t.Fatalf("超时错误缺少可操作的验签上下文：%v", err)
	}
}

func TestValidateSignedSharedDaemonProcessChainRequiresExactSignedParent(t *testing.T) {
	nodePath := "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codexPath := "/Applications/ChatGPT.app/Contents/Resources/codex"
	listener := sharedDaemonListenerProcess{
		PID:        4242,
		ParentPID:  4343,
		UID:        os.Getuid(),
		Executable: "/private/tmp/staged/codex",
		Command:    strings.Join([]string{codexPath, "app-server", "--listen", "unix://"}, "\x00"),
	}
	supervisor := sharedDaemonListenerProcess{
		PID:        4343,
		ParentPID:  1,
		UID:        os.Getuid(),
		Executable: "/private/tmp/staged/node",
		Command: strings.Join([]string{
			nodePath, "-e", sharedDaemonNodeSupervisorScript, "--",
			codexPath, "app-server", "--listen", "unix://",
		}, "\x00"),
	}
	var signatureChecks []string
	validateSignature := func(pid int, identifier string) error {
		signatureChecks = append(signatureChecks, fmt.Sprintf("%d:%s", pid, identifier))
		return nil
	}
	if err := validateSignedSharedDaemonProcessChain(
		listener,
		supervisor,
		os.Getuid(),
		nodePath,
		codexPath,
		validateSignature,
	); err != nil {
		t.Fatalf("完整签名父链应通过：%v", err)
	}
	if got := strings.Join(signatureChecks, ","); got != "4242:codex,4343:node" {
		t.Fatalf("必须分别验证 listener 与 supervisor 的运行态签名：%s", got)
	}

	tests := map[string]func(*sharedDaemonListenerProcess, *sharedDaemonListenerProcess) func(int, string) error{
		"parent mismatch": func(listener *sharedDaemonListenerProcess, _ *sharedDaemonListenerProcess) func(int, string) error {
			listener.ParentPID++
			return validateSignature
		},
		"listener signature": func(_ *sharedDaemonListenerProcess, _ *sharedDaemonListenerProcess) func(int, string) error {
			return func(pid int, _ string) error {
				if pid == listener.PID {
					return fmt.Errorf("invalid listener signature")
				}
				return nil
			}
		},
		"supervisor signature": func(_ *sharedDaemonListenerProcess, _ *sharedDaemonListenerProcess) func(int, string) error {
			return func(pid int, _ string) error {
				if pid == supervisor.PID {
					return fmt.Errorf("invalid supervisor signature")
				}
				return nil
			}
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			candidateListener := listener
			candidateSupervisor := supervisor
			candidateValidator := mutate(&candidateListener, &candidateSupervisor)
			if err := validateSignedSharedDaemonProcessChain(
				candidateListener,
				candidateSupervisor,
				os.Getuid(),
				nodePath,
				codexPath,
				candidateValidator,
			); err == nil {
				t.Fatal("不完整或无效的运行态签名父链必须 fail closed")
			}
		})
	}
}

func TestValidateSharedDaemonNodeSupervisorProcessAcceptsSignedSupervisorArgv(t *testing.T) {
	nodePath := "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codexPath := "/Applications/ChatGPT.app/Contents/Resources/codex"
	baseArgv := []string{
		nodePath,
		"-e",
		sharedDaemonNodeSupervisorScript,
		codexPath,
		"app-server",
		"--listen",
		"unix://",
	}

	for _, withSeparator := range []bool{false, true} {
		argv := append([]string(nil), baseArgv...)
		if withSeparator {
			argv = append(argv[:3], append([]string{"--"}, argv[3:]...)...)
		}
		process := sharedDaemonListenerProcess{
			PID:        4242,
			UID:        os.Getuid(),
			Executable: nodePath,
			Command:    strings.Join(argv, "\x00"),
		}
		if err := validateSharedDaemonNodeSupervisorProcess(process, nodePath, codexPath); err != nil {
			t.Fatalf("带 separator=%t 的 supervisor argv 应通过：%v", withSeparator, err)
		}
	}
}

func TestGeneratedSharedDaemonProgramArgumentsMatchRuntimeValidator(t *testing.T) {
	nodePath := "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codexPath := "/Applications/ChatGPT.app/Contents/Resources/codex"
	process := sharedDaemonListenerProcess{
		PID:        4242,
		UID:        os.Getuid(),
		Executable: nodePath,
		Command:    strings.Join(sharedDaemonSupervisorProgramArguments(nodePath, codexPath), "\x00"),
	}
	if err := validateSharedDaemonNodeSupervisorProcess(process, nodePath, codexPath); err != nil {
		t.Fatalf("LaunchAgent 生成的 supervisor argv 必须通过同一份运行态校验：%v", err)
	}
}

func TestValidateSharedDaemonNodeSupervisorProcessRejectsUnsafeArgv(t *testing.T) {
	nodePath := "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codexPath := "/Applications/ChatGPT.app/Contents/Resources/codex"
	validArgv := []string{
		nodePath,
		"-e",
		sharedDaemonNodeSupervisorScript,
		codexPath,
		"app-server",
		"--listen",
		"unix://",
	}
	newProcess := func(argv []string) sharedDaemonListenerProcess {
		return sharedDaemonListenerProcess{
			PID:        4242,
			UID:        os.Getuid(),
			Executable: nodePath,
			Command:    strings.Join(argv, "\x00"),
		}
	}

	tests := map[string]func(sharedDaemonListenerProcess) sharedDaemonListenerProcess{
		"invalid pid": func(process sharedDaemonListenerProcess) sharedDaemonListenerProcess {
			process.PID = 1
			return process
		},
		"foreign uid": func(process sharedDaemonListenerProcess) sharedDaemonListenerProcess {
			process.UID++
			return process
		},
		"wrong node script": func(process sharedDaemonListenerProcess) sharedDaemonListenerProcess {
			argv := strings.Split(process.Command, "\x00")
			argv[2] = "console.log('unexpected')"
			process.Command = strings.Join(argv, "\x00")
			return process
		},
		"shell style command": func(process sharedDaemonListenerProcess) sharedDaemonListenerProcess {
			process.Command = strings.Join([]string{nodePath, "-e", sharedDaemonNodeSupervisorScript, codexPath, "daemon", "start"}, "\x00")
			return process
		},
		"unexpected child argument": func(process sharedDaemonListenerProcess) sharedDaemonListenerProcess {
			argv := append([]string(nil), validArgv...)
			argv = append(argv, "unexpected")
			process.Command = strings.Join(argv, "\x00")
			return process
		},
	}

	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			if err := validateSharedDaemonNodeSupervisorProcess(mutate(newProcess(validArgv)), nodePath, codexPath); err == nil {
				t.Fatal("不安全的 supervisor argv 必须 fail closed")
			}
		})
	}
}

func TestValidateSignedSharedDaemonListenerProcessAcceptsStagedExecutable(t *testing.T) {
	codexPath := "/Applications/ChatGPT.app/Contents/Resources/codex"
	process := sharedDaemonListenerProcess{
		PID:        4242,
		UID:        os.Getuid(),
		Executable: "/private/tmp/random/codex",
		Command:    strings.Join([]string{codexPath, "app-server", "--listen", "unix://"}, "\x00"),
	}
	if err := validateSignedSharedDaemonListenerProcess(process, os.Getuid(), codexPath); err != nil {
		t.Fatalf("已由调用方动态验签的一次性 codex 应按原始 argv 通过：%v", err)
	}
	process.Command = strings.Join([]string{process.Executable, "app-server", "--listen", "unix://"}, "\x00")
	if err := validateSignedSharedDaemonListenerProcess(process, os.Getuid(), codexPath); err == nil {
		t.Fatal("一次性 executable 路径不得冒充原始 Codex argv")
	}
}

func TestSharedDaemonNodeSupervisorForwardsSignalsWithoutChildKilledState(t *testing.T) {
	// Node 的 child.killed 只表示最近一次 kill 调用，不表示子进程仍然存活；
	// supervisor 必须依据可观测退出状态决定是否转发信号，避免漏发终止信号。
	if strings.Contains(sharedDaemonNodeSupervisorScript, "child.killed") {
		t.Fatal("supervisor signal forwarding 不能把 child.killed 当作存活状态")
	}
	if !strings.Contains(sharedDaemonNodeSupervisorScript, "child.kill(signal)") {
		t.Fatal("supervisor 必须把 SIGTERM/SIGINT/SIGHUP 转发给 app-server child")
	}
}

func TestSharedDaemonNodeSupervisorUsesStagedCodexWithoutLeakingItToChild(t *testing.T) {
	if !strings.Contains(sharedDaemonNodeSupervisorScript, "process.env.MIMI_REMOTE_PINNED_CODEX_PATH") ||
		!strings.Contains(sharedDaemonNodeSupervisorScript, "delete process.env.MIMI_REMOTE_PINNED_CODEX_PATH") {
		t.Fatal("supervisor 必须只从内部环境读取一次性 codex，并在 spawn 前从 child 环境删除")
	}
	if !strings.Contains(sharedDaemonNodeSupervisorScript, "argv0:argv[0]") {
		t.Fatal("一次性 codex 必须保留原始 Codex argv0，供运行态父链验收")
	}
}

func TestSharedDaemonNodeSupervisorLaunchesPinnedCodex(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skipf("当前环境没有 node：%v", err)
	}
	cmd := exec.Command(
		node,
		"-e",
		sharedDaemonNodeSupervisorScript,
		"--",
		"/usr/bin/true",
		"app-server",
		"--listen",
		"unix://",
	)
	env := make([]string, 0, len(os.Environ())+1)
	for _, item := range os.Environ() {
		if !strings.HasPrefix(item, sharedDaemonPinnedCodexEnvironmentKey+"=") {
			env = append(env, item)
		}
	}
	cmd.Env = append(env, sharedDaemonPinnedCodexEnvironmentKey+"=/usr/bin/true")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("node supervisor 必须拉起 pinned codex：%v output=%s", err, output)
	}
}

func TestSharedDaemonNodeSupervisorScriptHasNoPlistLineBreaks(t *testing.T) {
	// encoding/xml 会把换行编码为 &#xA;；launchctl bootstrap 对
	// ProgramArguments 的这种实体会只保留第一行，最终让 node 正常退出但不拉起 child。
	if strings.ContainsAny(sharedDaemonNodeSupervisorScript, "\r\n") {
		t.Fatal("node supervisor inline script 必须保持为单行")
	}
	if !strings.HasSuffix(sharedDaemonNodeSupervisorScript, "});") {
		t.Fatal("node supervisor inline script 缺少 child exit 尾部哨兵")
	}
}
