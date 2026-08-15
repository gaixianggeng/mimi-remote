//go:build darwin

package appserver

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestValidateSignedSharedDaemonProcessChainRequiresExactSignedParent(t *testing.T) {
	nodePath := "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
	codexPath := "/Applications/ChatGPT.app/Contents/Resources/codex"
	listener := sharedDaemonListenerProcess{
		PID:        4242,
		ParentPID:  4343,
		UID:        os.Getuid(),
		Executable: codexPath,
		Command:    strings.Join([]string{codexPath, "app-server", "--listen", "unix://"}, "\x00"),
	}
	supervisor := sharedDaemonListenerProcess{
		PID:        4343,
		ParentPID:  1,
		UID:        os.Getuid(),
		Executable: nodePath,
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
		"foreign executable": func(process sharedDaemonListenerProcess) sharedDaemonListenerProcess {
			process.Executable = "/tmp/node"
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
