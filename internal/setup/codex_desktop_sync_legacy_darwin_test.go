//go:build darwin

package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestCleanupDesktopSyncLegacyArtifactsRestoresOwnedEnvironmentAndFixedFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		content := []byte("legacy")
		switch filepath.Base(path) {
		case legacyLaunchAgentLabel + ".plist":
			content = []byte("<plist><string>" + legacyLaunchAgentLabel + "</string><string>--codex-daemon-supervisor</string></plist>")
		case "codex-shared-daemon-migration-required":
			content = []byte("restart-required\n")
		case "codex-shared-daemon-enable-prepared":
			content = []byte("enable-prepared\n")
		case legacyOperationLockName:
			content = nil
		}
		if err := os.WriteFile(path, content, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	oldRunner := runDesktopSyncLegacyCommand
	var environmentWrites []string
	environment := map[string]string{
		legacyDaemonEnvKey:    "mimi-daemon",
		legacyCodexHomeEnvKey: "/tmp/mimi-codex",
		legacyEpochEnvKey:     "epoch-1",
	}
	commandIndex, bootoutIndex, firstEnvironmentWriteIndex := 0, 0, 0
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		commandIndex++
		joined := name + " " + strings.Join(args, " ")
		switch {
		case strings.Contains(joined, "lsappinfo find"):
			return nil, nil
		case strings.Contains(joined, "defaults read"):
			key := args[len(args)-1]
			values := map[string]string{
				"MimiRemoteMac.codexDesktop.previousValue":       "previous-daemon",
				"MimiRemoteMac.codexDesktop.writtenValue":        "mimi-daemon",
				"MimiRemoteMac.codexDesktop.ownsEnvironment":     "true",
				"MimiRemoteMac.codexDesktop.previousCodexHome":   "",
				"MimiRemoteMac.codexDesktop.writtenCodexHome":    "/tmp/mimi-codex",
				"MimiRemoteMac.codexDesktop.ownsCodexHome":       "true",
				"MimiRemoteMac.codexDesktop.writtenSessionEpoch": "epoch-1",
				"MimiRemoteMac.codexDesktop.ownsSessionEpoch":    "true",
			}
			if value := values[key]; value != "" {
				return []byte(value), nil
			}
			return nil, errors.New("missing")
		case strings.Contains(joined, "launchctl getenv"):
			if value, ok := environment[args[1]]; ok {
				return []byte(value), nil
			}
			return nil, nil
		case strings.Contains(joined, "launchctl setenv"):
			if firstEnvironmentWriteIndex == 0 {
				firstEnvironmentWriteIndex = commandIndex
			}
			environmentWrites = append(environmentWrites, strings.Join(args, " "))
			environment[args[1]] = args[2]
			return nil, nil
		case strings.Contains(joined, "launchctl unsetenv"):
			if firstEnvironmentWriteIndex == 0 {
				firstEnvironmentWriteIndex = commandIndex
			}
			environmentWrites = append(environmentWrites, strings.Join(args, " "))
			delete(environment, args[1])
			return nil, nil
		case strings.Contains(joined, "launchctl print"):
			return []byte("path = " + paths[0] + "\n" + legacyLaunchAgentLabel + "\n--codex-daemon-supervisor\n"), nil
		case strings.Contains(joined, "launchctl bootout"):
			bootoutIndex = commandIndex
			return nil, nil
		default:
			return nil, nil
		}
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("legacy fixed file still exists: %s err=%v", path, err)
		}
	}
	want := []string{
		"setenv " + legacyDaemonEnvKey + " previous-daemon",
		"unsetenv " + legacyCodexHomeEnvKey,
		"unsetenv " + legacyEpochEnvKey,
	}
	if !reflect.DeepEqual(environmentWrites, want) {
		t.Fatalf("ownership-matched environment restore mismatch:\n got=%v\nwant=%v", environmentWrites, want)
	}
	if bootoutIndex == 0 || firstEnvironmentWriteIndex <= bootoutIndex {
		t.Fatalf("launchctl environment was restored before LaunchAgent cleanup: bootout=%d restore=%d", bootoutIndex, firstEnvironmentWriteIndex)
	}
}

func TestRestoreOwnedLegacyDesktopEnvironmentRejectsMismatchedEpoch(t *testing.T) {
	oldRunner := runDesktopSyncLegacyCommand
	var writes int
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		joined := name + " " + strings.Join(args, " ")
		if strings.Contains(joined, "launchctl getenv "+legacyEpochEnvKey) {
			return []byte("new-owner"), nil
		}
		if strings.Contains(joined, "launchctl setenv") || strings.Contains(joined, "launchctl unsetenv") {
			writes++
		}
		return []byte("mimi-value"), nil
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	ledger := legacyDesktopLedger{
		previousDaemon: "previous", writtenDaemon: "mimi-value", ownsDaemon: true,
		previousHome: "/previous", writtenHome: "mimi-value", ownsHome: true,
		writtenEpoch: "old-owner", ownsEpoch: true, cleanupPhase: legacyCleanupPhaseEnvironmentRestoring,
	}
	if err := restoreOwnedLegacyDesktopEnvironment(context.Background(), &ledger); err == nil {
		t.Fatal("mismatched ownership epoch must block cleanup and preserve the ledger")
	}
	if writes != 0 {
		t.Fatalf("mismatched ownership epoch must not change launchctl environment: writes=%d", writes)
	}
}

func TestCleanupDesktopSyncLegacyArtifactsRequiresDesktopExit(t *testing.T) {
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if strings.Contains(name+" "+strings.Join(args, " "), "lsappinfo find") {
			return []byte("ASN:0x1"), nil
		}
		return nil, nil
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	err := cleanupDesktopSyncLegacyArtifacts(context.Background())
	if err == nil || !strings.Contains(err.Error(), "仍在运行") {
		t.Fatalf("running Desktop must block cleanup: %v", err)
	}
}

func TestCleanupDesktopSyncLegacyArtifactsWaitsForLegacyOperationLock(t *testing.T) {
	fixture := newLegacyCleanupTestFixture(t)
	fixture.install(t)
	lockPath, _, err := legacyDesktopLegacyFilePath(fixture.paths, legacyOperationLockName)
	if err != nil {
		t.Fatal(err)
	}
	oldOperation, err := os.OpenFile(lockPath, os.O_RDWR|syscall.O_NOFOLLOW, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = syscall.Flock(int(oldOperation.Fd()), syscall.LOCK_UN)
		_ = oldOperation.Close()
	})
	if err := syscall.Flock(int(oldOperation.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	err = cleanupDesktopSyncLegacyArtifacts(ctx)
	if err == nil || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("cleanup did not wait for the legacy operation lock: %v", err)
	}
	if fixture.bootouts != 0 || len(fixture.environmentWrites) != 0 || len(fixture.deletedPreferences) != 0 {
		t.Fatalf("cleanup mutated legacy resources without the operation lock: bootouts=%d env=%v prefs=%v",
			fixture.bootouts, fixture.environmentWrites, fixture.deletedPreferences)
	}
	for _, path := range fixture.paths {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("cleanup removed a legacy file without the operation lock: %s: %v", path, err)
		}
	}
}

func TestCleanupDesktopSyncLegacyArtifactsRejectsReplacedPlist(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		t.Fatal(err)
	}
	plist := paths[0]
	if err := os.MkdirAll(filepath.Dir(plist), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(plist, []byte("user managed"), 0o600); err != nil {
		t.Fatal(err)
	}
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if strings.Contains(name+" "+strings.Join(args, " "), "lsappinfo find") {
			return nil, nil
		}
		return nil, errors.New("missing")
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })
	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err == nil || !strings.Contains(err.Error(), "拒绝删除") {
		t.Fatalf("replaced plist was not blocked: %v", err)
	}
	if _, err := os.Lstat(plist); err != nil {
		t.Fatalf("replaced plist was removed: %v", err)
	}
}

func TestLaunchctlGetenvDistinguishesUnsetAndRealErrors(t *testing.T) {
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name != "/bin/launchctl" || len(args) != 2 || args[0] != "getenv" {
			return nil, nil
		}
		key := args[1]
		switch key {
		case "MISSING_ENV":
			return []byte("Could not find environment variable: " + key), errors.New("exit status 113")
		case "BROKEN_ENV":
			return []byte("launchctl operation failed"), errors.New("exit status 1")
		case "EMPTY_ENV":
			return nil, nil
		default:
			return []byte("value"), nil
		}
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	if value, present, err := launchctlGetenv(context.Background(), "MISSING_ENV"); err != nil || present || value != "" {
		t.Fatalf("unset environment variable was not distinguished: value=%q present=%t err=%v", value, present, err)
	}
	if _, present, err := launchctlGetenv(context.Background(), "EMPTY_ENV"); err != nil || present {
		t.Fatalf("empty environment value should be treated as unset: present=%t err=%v", present, err)
	}
	if _, _, err := launchctlGetenv(context.Background(), "BROKEN_ENV"); err == nil || !strings.Contains(err.Error(), "BROKEN_ENV") {
		t.Fatalf("real launchctl getenv error was swallowed: %v", err)
	}
}

func TestLegacyDefaultsReadDistinguishesMissingAndRealErrors(t *testing.T) {
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = func(_ context.Context, _ string, args ...string) ([]byte, error) {
		key := args[len(args)-1]
		switch key {
		case "MISSING_KEY":
			return []byte("Error: Could not find key 'MISSING_KEY' in domain '" + legacyDefaultsDomain + "'"), errors.New("exit status 1")
		case "BROKEN_KEY":
			return []byte("defaults database unavailable"), errors.New("exit status 1")
		default:
			return []byte(" value "), nil
		}
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	if value, present, err := legacyDefaultsRead(context.Background(), "MISSING_KEY"); err != nil || present || value != "" {
		t.Fatalf("missing defaults key was not distinguished: value=%q present=%t err=%v", value, present, err)
	}
	if _, _, err := legacyDefaultsRead(context.Background(), "BROKEN_KEY"); err == nil || !strings.Contains(err.Error(), "BROKEN_KEY") {
		t.Fatalf("real defaults read error was swallowed: %v", err)
	}
	if value, present, err := legacyDefaultsRead(context.Background(), "PRESENT_KEY"); err != nil || !present || value != "value" {
		t.Fatalf("present defaults value mismatch: value=%q present=%t err=%v", value, present, err)
	}
}

func TestCleanupDesktopSyncLegacyArtifactsReturnsDefaultsDeleteError(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	oldRunner := runDesktopSyncLegacyCommand
	values := map[string]string{
		"MimiRemoteMac.codexDesktop.enabled":             "true",
		"MimiRemoteMac.codexDesktop.previousValue":       "previous-daemon",
		"MimiRemoteMac.codexDesktop.writtenValue":        "mimi-daemon",
		"MimiRemoteMac.codexDesktop.ownsEnvironment":     "true",
		"MimiRemoteMac.codexDesktop.writtenCodexHome":    "/tmp/mimi-codex",
		"MimiRemoteMac.codexDesktop.ownsCodexHome":       "true",
		"MimiRemoteMac.codexDesktop.writtenSessionEpoch": "epoch-1",
		"MimiRemoteMac.codexDesktop.ownsSessionEpoch":    "true",
	}
	environment := map[string]string{
		legacyDaemonEnvKey:    "mimi-daemon",
		legacyCodexHomeEnvKey: "/tmp/mimi-codex",
		legacyEpochEnvKey:     "epoch-1",
	}
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "/usr/bin/defaults" {
			switch args[0] {
			case "read":
				if value, ok := values[args[2]]; ok {
					return []byte(value), nil
				}
				return nil, errors.New("missing")
			case "write":
				values[args[2]] = args[4]
				return nil, nil
			case "delete":
				return []byte("delete failed"), errors.New("simulated defaults failure")
			}
		}
		if name == "/usr/bin/lsappinfo" {
			return nil, nil
		}
		if name == "/bin/launchctl" {
			switch args[0] {
			case "getenv":
				if value, ok := environment[args[1]]; ok {
					return []byte(value), nil
				}
				return nil, nil
			case "setenv":
				environment[args[1]] = args[2]
				return nil, nil
			case "unsetenv":
				delete(environment, args[1])
				return nil, nil
			}
		}
		return nil, nil
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	err := cleanupDesktopSyncLegacyArtifacts(context.Background())
	if err == nil || !strings.Contains(err.Error(), "删除旧 Desktop 偏好") || !strings.Contains(err.Error(), "MimiRemoteMac.codexDesktop.enabled") {
		t.Fatalf("defaults delete failure was not returned: %v", err)
	}
}

func TestCleanupDesktopSyncLegacyArtifactsRetriesAfterEpochUnset(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		content := []byte("legacy")
		switch filepath.Base(path) {
		case legacyLaunchAgentLabel + ".plist":
			content = []byte("<plist><string>" + legacyLaunchAgentLabel + "</string><string>--codex-daemon-supervisor</string></plist>")
		case "codex-shared-daemon-migration-required":
			content = []byte("restart-required\n")
		case "codex-shared-daemon-enable-prepared":
			content = []byte("enable-prepared\n")
		case legacyOperationLockName:
			content = nil
		}
		if err := os.WriteFile(path, content, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	ledger := map[string]string{
		"MimiRemoteMac.codexDesktop.enabled":             "true",
		"MimiRemoteMac.codexDesktop.previousValue":       "previous-daemon",
		"MimiRemoteMac.codexDesktop.writtenValue":        "mimi-daemon",
		"MimiRemoteMac.codexDesktop.ownsEnvironment":     "true",
		"MimiRemoteMac.codexDesktop.writtenCodexHome":    "/tmp/mimi-codex",
		"MimiRemoteMac.codexDesktop.ownsCodexHome":       "true",
		"MimiRemoteMac.codexDesktop.writtenSessionEpoch": "epoch-1",
		"MimiRemoteMac.codexDesktop.ownsSessionEpoch":    "true",
	}
	environment := map[string]string{
		legacyDaemonEnvKey:    "mimi-daemon",
		legacyCodexHomeEnvKey: "/tmp/mimi-codex",
		legacyEpochEnvKey:     "epoch-1",
	}
	firstDeleteFailure := true
	epochUnsets := 0
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		switch name {
		case "/usr/bin/lsappinfo":
			return nil, nil
		case "/usr/bin/defaults":
			switch args[0] {
			case "read":
				if value, ok := ledger[args[2]]; ok {
					return []byte(value), nil
				}
				return nil, errors.New("missing")
			case "write":
				ledger[args[2]] = args[4]
				return nil, nil
			case "delete":
				if firstDeleteFailure && args[2] == "MimiRemoteMac.codexDesktop.enabled" {
					firstDeleteFailure = false
					return []byte("delete failed"), errors.New("simulated defaults failure")
				}
				delete(ledger, args[2])
				return nil, nil
			}
		case "/bin/launchctl":
			switch args[0] {
			case "getenv":
				if value, ok := environment[args[1]]; ok {
					return []byte(value), nil
				}
				return []byte("Could not find environment variable: " + args[1]), errors.New("exit status 113")
			case "setenv":
				environment[args[1]] = args[2]
				return nil, nil
			case "unsetenv":
				delete(environment, args[1])
				if args[1] == legacyEpochEnvKey {
					epochUnsets++
				}
				return nil, nil
			case "bootout":
				return nil, nil
			case "print":
				return []byte("path = " + paths[0] + "\n" + legacyLaunchAgentLabel + "\n--codex-daemon-supervisor\n"), nil
			}
		}
		return nil, nil
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err == nil {
		t.Fatal("first cleanup should report the injected defaults failure")
	}
	if _, ok := environment[legacyEpochEnvKey]; ok {
		t.Fatal("first cleanup should have unset the ownership epoch before the injected failure")
	}
	if ledger[legacyCleanupPhaseKey] != legacyCleanupPhaseEnvironmentRestored {
		t.Fatalf("cleanup progress marker was not preserved: %#v", ledger)
	}
	if present, err := desktopSyncLegacyArtifactsPresent(); err != nil || !present {
		t.Fatalf("cleanup progress marker must keep legacy cleanup visible: present=%t err=%v", present, err)
	}

	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err != nil {
		t.Fatalf("cleanup retry should complete after epoch was unset: %v", err)
	}
	if len(ledger) != 0 {
		t.Fatalf("cleanup ledger was not fully removed after retry: %#v", ledger)
	}
	if epochUnsets != 1 {
		t.Fatalf("cleanup retry must not unset an already-unset epoch: unsets=%d", epochUnsets)
	}
	for _, path := range paths {
		if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("legacy fixed file still exists after retry: %s err=%v", path, err)
		}
	}
}

func TestCleanupDesktopSyncLegacyArtifactsRetriesPartialEnvironmentRestore(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ledger := map[string]string{
		"MimiRemoteMac.codexDesktop.previousValue":       "previous-daemon",
		"MimiRemoteMac.codexDesktop.writtenValue":        "mimi-daemon",
		"MimiRemoteMac.codexDesktop.ownsEnvironment":     "true",
		"MimiRemoteMac.codexDesktop.previousCodexHome":   "",
		"MimiRemoteMac.codexDesktop.writtenCodexHome":    "/tmp/mimi-codex",
		"MimiRemoteMac.codexDesktop.ownsCodexHome":       "true",
		"MimiRemoteMac.codexDesktop.writtenSessionEpoch": "epoch-1",
		"MimiRemoteMac.codexDesktop.ownsSessionEpoch":    "true",
	}
	environment := map[string]string{
		legacyDaemonEnvKey:    "mimi-daemon",
		legacyCodexHomeEnvKey: "/tmp/mimi-codex",
		legacyEpochEnvKey:     "epoch-1",
	}
	failHomeRestore := true
	daemonRestores := 0
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		switch name {
		case "/usr/bin/lsappinfo":
			return nil, nil
		case "/usr/bin/defaults":
			switch args[0] {
			case "read":
				if value, ok := ledger[args[2]]; ok {
					return []byte(value), nil
				}
				return nil, errors.New("missing")
			case "write":
				ledger[args[2]] = args[4]
				return nil, nil
			case "delete":
				delete(ledger, args[2])
				return nil, nil
			}
		case "/bin/launchctl":
			switch args[0] {
			case "getenv":
				if value, ok := environment[args[1]]; ok {
					return []byte(value), nil
				}
				return nil, nil
			case "setenv":
				environment[args[1]] = args[2]
				if args[1] == legacyDaemonEnvKey {
					daemonRestores++
				}
				return nil, nil
			case "unsetenv":
				if args[1] == legacyCodexHomeEnvKey && failHomeRestore {
					failHomeRestore = false
					return []byte("simulated failure"), errors.New("exit status 1")
				}
				delete(environment, args[1])
				return nil, nil
			}
		}
		return nil, nil
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err == nil {
		t.Fatal("first cleanup should report the injected partial restore failure")
	}
	if ledger[legacyCleanupPhaseKey] != legacyCleanupPhaseEnvironmentRestoring {
		t.Fatalf("partial restore did not preserve the restoring phase: %#v", ledger)
	}
	if environment[legacyDaemonEnvKey] != "previous-daemon" || environment[legacyCodexHomeEnvKey] != "/tmp/mimi-codex" {
		t.Fatalf("unexpected partial environment state: %#v", environment)
	}
	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err != nil {
		t.Fatalf("partial environment restore was not retryable: %v", err)
	}
	if daemonRestores != 1 {
		t.Fatalf("already-restored daemon value was written again: count=%d", daemonRestores)
	}
	if environment[legacyDaemonEnvKey] != "previous-daemon" {
		t.Fatalf("daemon value was not restored: %#v", environment)
	}
	if _, ok := environment[legacyCodexHomeEnvKey]; ok {
		t.Fatalf("Codex home was not restored to unset: %#v", environment)
	}
	if _, ok := environment[legacyEpochEnvKey]; ok {
		t.Fatalf("ownership epoch was not removed: %#v", environment)
	}
}

func TestCleanupDesktopSyncLegacyArtifactsRejectsEnvironmentMismatchBeforeSideEffects(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		t.Fatal(err)
	}
	plist := paths[0]
	if err := os.MkdirAll(filepath.Dir(plist), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(plist, []byte("<plist><string>"+legacyLaunchAgentLabel+"</string><string>--codex-daemon-supervisor</string></plist>"), 0o600); err != nil {
		t.Fatal(err)
	}
	ledger := map[string]string{
		"MimiRemoteMac.codexDesktop.writtenValue":        "mimi-daemon",
		"MimiRemoteMac.codexDesktop.ownsEnvironment":     "true",
		"MimiRemoteMac.codexDesktop.writtenSessionEpoch": "epoch-1",
		"MimiRemoteMac.codexDesktop.ownsSessionEpoch":    "true",
	}
	mutations := 0
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "/usr/bin/lsappinfo" {
			return nil, nil
		}
		if name == "/usr/bin/defaults" && args[0] == "read" {
			if value, ok := ledger[args[2]]; ok {
				return []byte(value), nil
			}
			return nil, errors.New("missing")
		}
		if name == "/bin/launchctl" && args[0] == "getenv" {
			switch args[1] {
			case legacyDaemonEnvKey:
				return []byte("external-owner"), nil
			case legacyEpochEnvKey:
				return []byte("epoch-1"), nil
			default:
				return nil, nil
			}
		}
		mutations++
		return nil, nil
	}
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })

	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err == nil || !strings.Contains(err.Error(), legacyDaemonEnvKey) {
		t.Fatalf("environment mismatch did not fail closed: %v", err)
	}
	if mutations != 0 {
		t.Fatalf("environment mismatch triggered destructive commands: count=%d", mutations)
	}
	if _, err := os.Lstat(plist); err != nil {
		t.Fatalf("environment mismatch removed the legacy plist: %v", err)
	}
}

type legacyCleanupTestFixture struct {
	paths              []string
	ledger             map[string]string
	environment        map[string]string
	desktopRunning     bool
	launchctlPrint     string
	onPhaseWrite       func()
	bootouts           int
	deletedPreferences []string
	environmentWrites  []string
}

func newLegacyCleanupTestFixture(t *testing.T) *legacyCleanupTestFixture {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	paths, err := desktopSyncLegacyPaths()
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		content := []byte("legacy log\n")
		switch filepath.Base(path) {
		case legacyLaunchAgentLabel + ".plist":
			content = []byte("<plist><string>" + legacyLaunchAgentLabel + "</string><string>--codex-daemon-supervisor</string></plist>")
		case "codex-shared-daemon-migration-required":
			content = []byte("restart-required\n")
		case "codex-shared-daemon-enable-prepared":
			content = []byte("enable-prepared\n")
		case legacyOperationLockName:
			content = nil
		}
		if err := os.WriteFile(path, content, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return &legacyCleanupTestFixture{
		paths: paths,
		ledger: map[string]string{
			"MimiRemoteMac.codexDesktop.enabled":             "true",
			"MimiRemoteMac.codexDesktop.previousValue":       "previous-daemon",
			"MimiRemoteMac.codexDesktop.writtenValue":        "mimi-daemon",
			"MimiRemoteMac.codexDesktop.ownsEnvironment":     "true",
			"MimiRemoteMac.codexDesktop.previousCodexHome":   "",
			"MimiRemoteMac.codexDesktop.writtenCodexHome":    "/tmp/mimi-codex",
			"MimiRemoteMac.codexDesktop.ownsCodexHome":       "true",
			"MimiRemoteMac.codexDesktop.writtenSessionEpoch": "epoch-1",
			"MimiRemoteMac.codexDesktop.ownsSessionEpoch":    "true",
		},
		environment: map[string]string{
			legacyDaemonEnvKey:    "mimi-daemon",
			legacyCodexHomeEnvKey: "/tmp/mimi-codex",
			legacyEpochEnvKey:     "epoch-1",
		},
		launchctlPrint: "path = " + paths[0] + "\n" + legacyLaunchAgentLabel + "\n--codex-daemon-supervisor\n",
	}
}

func (f *legacyCleanupTestFixture) install(t *testing.T) {
	t.Helper()
	oldRunner := runDesktopSyncLegacyCommand
	runDesktopSyncLegacyCommand = f.run
	t.Cleanup(func() { runDesktopSyncLegacyCommand = oldRunner })
}

func (f *legacyCleanupTestFixture) run(_ context.Context, name string, args ...string) ([]byte, error) {
	switch name {
	case "/usr/bin/lsappinfo":
		if f.desktopRunning {
			return []byte("ASN:0x1"), nil
		}
		return nil, nil
	case "/usr/bin/defaults":
		switch args[0] {
		case "read":
			key := args[len(args)-1]
			if value, ok := f.ledger[key]; ok {
				return []byte(value), nil
			}
			return nil, errors.New("missing")
		case "write":
			f.ledger[args[2]] = args[4]
			if args[2] == legacyCleanupPhaseKey && f.onPhaseWrite != nil {
				f.onPhaseWrite()
			}
			return nil, nil
		case "delete":
			key := args[2]
			f.deletedPreferences = append(f.deletedPreferences, key)
			delete(f.ledger, key)
			return nil, nil
		}
	case "/bin/launchctl":
		switch args[0] {
		case "getenv":
			if value, ok := f.environment[args[1]]; ok {
				return []byte(value), nil
			}
			return []byte("Could not find environment variable: " + args[1]), errors.New("exit status 113")
		case "setenv":
			f.environmentWrites = append(f.environmentWrites, strings.Join(args, " "))
			f.environment[args[1]] = args[2]
			return nil, nil
		case "unsetenv":
			f.environmentWrites = append(f.environmentWrites, strings.Join(args, " "))
			delete(f.environment, args[1])
			return nil, nil
		case "print":
			return []byte(f.launchctlPrint), nil
		case "bootout":
			f.bootouts++
			return nil, nil
		}
	}
	return nil, nil
}

func replaceLegacyCleanupTestFile(t *testing.T, path string, content []byte) {
	t.Helper()
	replacement, err := os.CreateTemp(filepath.Dir(path), ".legacy-replacement-")
	if err != nil {
		t.Fatal(err)
	}
	replacementPath := replacement.Name()
	defer os.Remove(replacementPath)
	if _, err := replacement.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := replacement.Chmod(0o600); err != nil {
		t.Fatal(err)
	}
	if err := replacement.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacementPath, path); err != nil {
		t.Fatal(err)
	}
}

func TestCleanupDesktopSyncLegacyArtifactsStopsWhenDesktopRestartsDuringCleanup(t *testing.T) {
	fixture := newLegacyCleanupTestFixture(t)
	fixture.onPhaseWrite = func() { fixture.desktopRunning = true }
	fixture.install(t)

	originalEnvironment := map[string]string{}
	for key, value := range fixture.environment {
		originalEnvironment[key] = value
	}
	err := cleanupDesktopSyncLegacyArtifacts(context.Background())
	if err == nil || !strings.Contains(err.Error(), "重新启动") {
		t.Fatalf("Desktop restart after initial validation did not stop cleanup: %v", err)
	}
	if fixture.bootouts != 0 {
		t.Fatalf("Desktop restart must not bootout the loaded job: bootouts=%d", fixture.bootouts)
	}
	if len(fixture.deletedPreferences) != 0 {
		t.Fatalf("Desktop restart must not delete preferences: deleted=%v", fixture.deletedPreferences)
	}
	if len(fixture.environmentWrites) != 0 || !reflect.DeepEqual(fixture.environment, originalEnvironment) {
		t.Fatalf("Desktop restart must not restore launchctl environment: writes=%v environment=%v", fixture.environmentWrites, fixture.environment)
	}
	for _, path := range fixture.paths {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("Desktop restart must preserve legacy file %s: %v", path, err)
		}
	}
}

func TestCleanupDesktopSyncLegacyArtifactsPreservesFilesReplacedAfterInitialValidation(t *testing.T) {
	tests := []struct {
		name    string
		path    func([]string) string
		content []byte
	}{
		{
			name:    "plist",
			path:    func(paths []string) string { return paths[0] },
			content: []byte("<plist><string>" + legacyLaunchAgentLabel + "</string><string>--codex-daemon-supervisor</string></plist>"),
		},
		{
			name:    "migration marker",
			path:    func(paths []string) string { return paths[1] },
			content: []byte("restart-required\n"),
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newLegacyCleanupTestFixture(t)
			replacedPath := test.path(fixture.paths)
			fixture.onPhaseWrite = func() { replaceLegacyCleanupTestFile(t, replacedPath, test.content) }
			fixture.install(t)

			err := cleanupDesktopSyncLegacyArtifacts(context.Background())
			if err == nil || !strings.Contains(err.Error(), "验证后发生变化") {
				t.Fatalf("replacement after initial validation was not rejected: %v", err)
			}
			got, err := os.ReadFile(replacedPath)
			if err != nil {
				t.Fatalf("replacement file was removed: %v", err)
			}
			if string(got) != string(test.content) {
				t.Fatalf("replacement file content changed: got=%q want=%q", got, test.content)
			}
		})
	}
}

func TestCleanupDesktopSyncLegacyArtifactsRejectsMismatchedLoadedLaunchJob(t *testing.T) {
	fixture := newLegacyCleanupTestFixture(t)
	fixture.launchctlPrint = "path = /tmp/external-launch-agent.plist\n" + legacyLaunchAgentLabel + "\n--codex-daemon-supervisor\n"
	fixture.install(t)

	err := cleanupDesktopSyncLegacyArtifacts(context.Background())
	if err == nil || !strings.Contains(err.Error(), "身份不匹配") {
		t.Fatalf("mismatched loaded job identity was not rejected: %v", err)
	}
	if fixture.bootouts != 0 {
		t.Fatalf("mismatched loaded job must not be booted out: bootouts=%d", fixture.bootouts)
	}
	if len(fixture.environmentWrites) != 0 {
		t.Fatalf("mismatched loaded job must not restore launchctl environment: writes=%v", fixture.environmentWrites)
	}
	for _, path := range fixture.paths {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("mismatched loaded job must preserve legacy file %s: %v", path, err)
		}
	}
}

func TestCleanupDesktopSyncLegacyArtifactsDoesNotOverwriteExternallyChangedEnvironment(t *testing.T) {
	tests := []struct {
		name          string
		key           string
		externalValue string
	}{
		{name: "daemon environment", key: legacyDaemonEnvKey, externalValue: "external-daemon"},
		{name: "ownership epoch", key: legacyEpochEnvKey, externalValue: "external-epoch"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newLegacyCleanupTestFixture(t)
			fixture.onPhaseWrite = func() { fixture.environment[test.key] = test.externalValue }
			fixture.install(t)

			err := cleanupDesktopSyncLegacyArtifacts(context.Background())
			if err == nil {
				t.Fatal("external environment change after initial validation must stop cleanup")
			}
			if len(fixture.environmentWrites) != 0 {
				t.Fatalf("external environment change must not be overwritten: writes=%v", fixture.environmentWrites)
			}
			if got := fixture.environment[test.key]; got != test.externalValue {
				t.Fatalf("external environment value was overwritten: got=%q want=%q", got, test.externalValue)
			}
		})
	}
}

func TestCleanupDesktopSyncLegacyArtifactsFinishesQuarantinedFileAfterInterruption(t *testing.T) {
	fixture := newLegacyCleanupTestFixture(t)
	fixture.ledger[legacyCleanupPhaseKey] = legacyCleanupPhaseEnvironmentRestoring
	original := fixture.paths[1]
	quarantine := original + ".mimi-cleanup"
	if err := os.Rename(original, quarantine); err != nil {
		t.Fatal(err)
	}
	fixture.install(t)

	if err := cleanupDesktopSyncLegacyArtifacts(context.Background()); err != nil {
		t.Fatalf("cleanup did not resume after the file quarantine side effect: %v", err)
	}
	if _, err := os.Lstat(original); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy original unexpectedly remained after retry: %v", err)
	}
	if _, err := os.Lstat(quarantine); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy quarantine unexpectedly remained after retry: %v", err)
	}
}
