//go:build darwin

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

type fakeCodexFrontLaunchd struct {
	mu              sync.Mutex
	loaded          bool
	job             []byte
	bootstrapCalls  int
	beforeBootstrap func(int, []byte) error
}

func (f *fakeCodexFrontLaunchd) ops() codexFrontManagementOps {
	return codexFrontManagementOps{
		loaded: func(string) bool {
			f.mu.Lock()
			defer f.mu.Unlock()
			return f.loaded
		},
		bootout: func(string) error {
			f.mu.Lock()
			defer f.mu.Unlock()
			f.loaded = false
			f.job = nil
			return nil
		},
		bootstrap: func(path string) error {
			plist, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			f.mu.Lock()
			f.bootstrapCalls++
			call := f.bootstrapCalls
			hook := f.beforeBootstrap
			f.mu.Unlock()
			if hook != nil {
				if err := hook(call, plist); err != nil {
					return err
				}
			}
			f.mu.Lock()
			defer f.mu.Unlock()
			f.loaded = true
			f.job = append([]byte(nil), plist...)
			return nil
		},
		socketListening: func(string) bool {
			f.mu.Lock()
			defer f.mu.Unlock()
			return f.loaded
		},
	}
}

func TestCodexFrontConcurrentColdInstallsKeepOneRegisteredIdentity(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "front-management-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	setCodexFrontManagementTestHome(t, root)
	publicHome := filepath.Join(root, "public")
	configA := writeCodexFrontIsolationManagementConfig(t, root, "a", publicHome, filepath.Join(root, "backend-a"))
	configB := writeCodexFrontIsolationManagementConfig(t, root, "b", publicHome, filepath.Join(root, "backend-b"))
	plistPath := filepath.Join(root, "shared.plist")
	label := "test.mimi.front.concurrent-" + filepath.Base(root)
	enteredBootstrap := make(chan struct{})
	releaseBootstrap := make(chan struct{})
	fake := &fakeCodexFrontLaunchd{}
	fake.beforeBootstrap = func(call int, _ []byte) error {
		if call == 1 {
			close(enteredBootstrap)
			<-releaseBootstrap
		}
		return nil
	}
	args := func(configPath string) []string {
		return []string{"install", "--direct", "--config", configPath, "--label", label, "--plist", plistPath, "--log-file", filepath.Join(root, "front.log")}
	}

	firstDone := make(chan error, 1)
	go func() { firstDone <- runCodexFrontInstallWithOps(args(configA), &bytes.Buffer{}, fake.ops()) }()
	<-enteredBootstrap
	secondDone := make(chan error, 1)
	go func() { secondDone <- runCodexFrontInstallWithOps(args(configB), &bytes.Buffer{}, fake.ops()) }()
	select {
	case err := <-secondDone:
		t.Fatalf("第二次安装越过了首次 bootstrap 事务：%v", err)
	case <-time.After(150 * time.Millisecond):
	}
	close(releaseBootstrap)
	if err := <-firstDone; err != nil {
		t.Fatalf("首次安装失败：%v", err)
	}
	if err := <-secondDone; err == nil || !strings.Contains(err.Error(), "会话目录与配置不同") {
		t.Fatalf("第二套身份应在锁内读取首次安装结果并拒绝覆盖：%v", err)
	}

	onDisk, err := os.ReadFile(plistPath)
	if err != nil {
		t.Fatal(err)
	}
	fake.mu.Lock()
	job, bootstrapCalls := append([]byte(nil), fake.job...), fake.bootstrapCalls
	fake.mu.Unlock()
	installA, err := resolveCodexFrontInstallation(configA, label, plistPath)
	if err != nil {
		t.Fatal(err)
	}
	registeredHome, err := codexFrontPlistBackendHome(plistPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(onDisk, job) || registeredHome != installA.BackendHome {
		t.Fatalf("磁盘登记与已加载 job 必须保持 A 身份：registered=%q want=%q diskJobEqual=%v", registeredHome, installA.BackendHome, bytes.Equal(onDisk, job))
	}
	if bootstrapCalls != 1 {
		t.Fatalf("被拒绝的第二套身份不应调用 bootstrap：calls=%d", bootstrapCalls)
	}
}

func TestCodexFrontColdBootstrapFailureRemovesNewRegistration(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "front-rollback-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	setCodexFrontManagementTestHome(t, root)
	configPath := writeCodexFrontManagementConfig(t, root, "public")
	plistPath := filepath.Join(root, "front.plist")
	fake := &fakeCodexFrontLaunchd{beforeBootstrap: func(int, []byte) error { return errors.New("injected bootstrap failure") }}
	err = runCodexFrontInstallWithOps([]string{
		"install", "--direct", "--config", configPath, "--label", "test.mimi.front.rollback-" + filepath.Base(root),
		"--plist", plistPath, "--log-file", filepath.Join(root, "front.log"),
	}, &bytes.Buffer{}, fake.ops())
	if err == nil || !strings.Contains(err.Error(), "injected bootstrap failure") {
		t.Fatalf("应返回注入的 bootstrap 失败：%v", err)
	}
	if _, err := os.Stat(plistPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("首次加载失败后不能留下未加载的登记：%v", err)
	}
}

func TestCodexFrontUpdateBootstrapFailureRestoresLoadedJob(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "front-update-rollback-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	setCodexFrontManagementTestHome(t, root)
	configPath := writeCodexFrontManagementConfig(t, root, "public")
	plistPath := filepath.Join(root, "front.plist")
	label := "test.mimi.front.update-rollback-" + filepath.Base(root)
	install, err := resolveCodexFrontInstallation(configPath, label, plistPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(install.Socket), 0o700); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if resolved, resolveErr := filepath.EvalSymlinks(executable); resolveErr == nil {
		executable = resolved
	}
	oldArgs, err := codexFrontProgramArguments(executable, true, configPath, filepath.Join(root, "old.log"))
	if err != nil {
		t.Fatal(err)
	}
	revision, err := codexFrontExecutableRevision(executable)
	if err != nil {
		t.Fatal(err)
	}
	oldPlist := renderCodexFrontPlist(label, oldArgs, install.Socket, revision, install.BackendHome)
	if err := os.WriteFile(plistPath, oldPlist, 0o644); err != nil {
		t.Fatal(err)
	}
	fake := &fakeCodexFrontLaunchd{loaded: true, job: append([]byte(nil), oldPlist...)}
	fake.beforeBootstrap = func(call int, _ []byte) error {
		if call == 1 {
			return errors.New("injected update bootstrap failure")
		}
		return nil
	}
	err = runCodexFrontInstallWithOps([]string{
		"install", "--direct", "--config", configPath, "--label", label,
		"--plist", plistPath, "--log-file", filepath.Join(root, "new.log"),
	}, &bytes.Buffer{}, fake.ops())
	if err == nil || !strings.Contains(err.Error(), "injected update bootstrap failure") {
		t.Fatalf("应返回新版 bootstrap 失败：%v", err)
	}
	onDisk, err := os.ReadFile(plistPath)
	if err != nil {
		t.Fatal(err)
	}
	fake.mu.Lock()
	job, loaded, calls := append([]byte(nil), fake.job...), fake.loaded, fake.bootstrapCalls
	fake.mu.Unlock()
	if !loaded || calls != 2 || !bytes.Equal(onDisk, oldPlist) || !bytes.Equal(job, oldPlist) {
		t.Fatalf("更新失败后必须恢复旧磁盘与旧 job：loaded=%v calls=%d diskOld=%v jobOld=%v", loaded, calls, bytes.Equal(onDisk, oldPlist), bytes.Equal(job, oldPlist))
	}
}

func TestCodexFrontStatusWaitsForInstallSnapshot(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "front-status-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	setCodexFrontManagementTestHome(t, root)
	configPath := writeCodexFrontManagementConfig(t, root, "public")
	plistPath := filepath.Join(root, "front.plist")
	label := "test.mimi.front.status-" + filepath.Base(root)
	enteredBootstrap := make(chan struct{})
	releaseBootstrap := make(chan struct{})
	fake := &fakeCodexFrontLaunchd{beforeBootstrap: func(call int, _ []byte) error {
		if call == 1 {
			close(enteredBootstrap)
			<-releaseBootstrap
		}
		return nil
	}}
	installArgs := []string{
		"install", "--direct", "--config", configPath, "--label", label,
		"--plist", plistPath, "--log-file", filepath.Join(root, "front.log"),
	}
	installDone := make(chan error, 1)
	go func() { installDone <- runCodexFrontInstallWithOps(installArgs, &bytes.Buffer{}, fake.ops()) }()
	<-enteredBootstrap

	var output bytes.Buffer
	statusDone := make(chan error, 1)
	go func() {
		statusDone <- runCodexFrontStatusWithOps([]string{
			"status", "--config", configPath, "--label", label, "--plist", plistPath,
		}, &output, fake.ops())
	}()
	select {
	case err := <-statusDone:
		t.Fatalf("status 读取了 install 的中间快照：%v %s", err, output.String())
	case <-time.After(150 * time.Millisecond):
	}
	close(releaseBootstrap)
	if err := <-installDone; err != nil {
		t.Fatal(err)
	}
	if err := <-statusDone; err != nil {
		t.Fatal(err)
	}
	var status codexFrontStatus
	if err := json.Unmarshal(output.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if !status.Loaded || status.ConfigurationError != "" || status.BackendCodexHome != status.ConfiguredBackendCodexHome || filepath.Base(status.BackendCodexHome) != "public" {
		t.Fatalf("status 应返回安装完成后的同一身份快照：%+v", status)
	}
}

func TestCodexFrontManagementLockIgnoresTMPDIR(t *testing.T) {
	root := t.TempDir()
	setCodexFrontManagementTestHome(t, root)
	firstTemp, secondTemp := filepath.Join(root, "tmp-a"), filepath.Join(root, "tmp-b")
	for _, directory := range []string{firstTemp, secondTemp} {
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("TMPDIR", firstTemp)
	unlock, err := appserver.LockFrontDoorManagement(context.Background(), "test.mimi.front.stable-lock", true)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	t.Setenv("TMPDIR", secondTemp)
	waitCtx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if secondUnlock, err := appserver.LockFrontDoorManagement(waitCtx, "test.mimi.front.stable-lock", true); err == nil {
		secondUnlock()
		t.Fatal("不同 TMPDIR 的同 label 管理操作必须争用同一把锁")
	}
}

func writeCodexFrontManagementConfig(t *testing.T, root, name string) string {
	t.Helper()
	home := filepath.Join(root, name)
	return writeCodexFrontIsolationManagementConfig(t, root, name, home, "")
}

func writeCodexFrontIsolationManagementConfig(t *testing.T, root, name, publicHome, backendHome string) string {
	t.Helper()
	for _, home := range []string{publicHome, backendHome} {
		if home == "" {
			continue
		}
		if err := os.MkdirAll(home, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	appServer := map[string]any{"transport": "local"}
	if backendHome != "" {
		appServer["shared_codex_home"] = backendHome
	}
	raw, err := json.Marshal(map[string]any{
		"codex":      map[string]any{"env": map[string]string{"CODEX_HOME": publicHome}},
		"app_server": appServer,
	})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, name+".json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func setCodexFrontManagementTestHome(t *testing.T, home string) {
	t.Helper()
	t.Setenv("HOME", home)
}
