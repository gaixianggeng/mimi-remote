//go:build darwin

package appserver

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectLegacyCodexExperimentReportsOwnedResidueWithoutMutation(t *testing.T) {
	launchctlCalls := [][]string{}
	residue, err := inspectLegacyCodexExperiment(legacyExperimentInspectionOps{
		homeDir: func() (string, error) { return "/Users/demo", nil },
		lstat: func(path string) (os.FileInfo, error) {
			if !strings.HasSuffix(path, legacyCodexSharedDaemonLabel+".plist") {
				t.Fatalf("unexpected plist path: %s", path)
			}
			return nil, nil
		},
		launchctl: func(args ...string) (string, bool, error) {
			launchctlCalls = append(launchctlCalls, append([]string(nil), args...))
			if args[0] == "print" {
				return "loaded", true, nil
			}
			return "owned-epoch", true, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"配置仍存在", "job 仍已加载", "ownership 环境仍存在"} {
		if !strings.Contains(residue, expected) {
			t.Fatalf("residue missing %q: %s", expected, residue)
		}
	}
	if len(launchctlCalls) != 2 || launchctlCalls[0][0] != "print" || launchctlCalls[1][0] != "getenv" {
		t.Fatalf("inspection must stay read-only: %v", launchctlCalls)
	}
}

func TestInspectLegacyCodexExperimentAcceptsCleanHost(t *testing.T) {
	residue, err := inspectLegacyCodexExperiment(legacyExperimentInspectionOps{
		homeDir: func() (string, error) { return "/Users/demo", nil },
		lstat:   func(string) (os.FileInfo, error) { return nil, os.ErrNotExist },
		launchctl: func(...string) (string, bool, error) {
			return "", false, nil
		},
	})
	if err != nil || residue != "" {
		t.Fatalf("clean host should pass: residue=%q err=%v", residue, err)
	}
}

func TestInspectLegacyCodexExperimentFailsClosedWhenInspectionFails(t *testing.T) {
	_, err := inspectLegacyCodexExperiment(legacyExperimentInspectionOps{
		homeDir: func() (string, error) { return "/Users/demo", nil },
		lstat:   func(string) (os.FileInfo, error) { return nil, os.ErrNotExist },
		launchctl: func(...string) (string, bool, error) {
			return "", false, errors.New("launchctl unavailable")
		},
	})
	if err == nil || !strings.Contains(err.Error(), "检查旧 Codex 实验") {
		t.Fatalf("inspection failure must fail closed: %v", err)
	}
}

func TestCurrentDesktopSSHFilesAreNotLegacyResidue(t *testing.T) {
	home := t.TempDir()
	ssh := filepath.Join(home, ".ssh")
	if err := os.Mkdir(ssh, 0700); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"config": `Host fixture-other
    HostName host.example.test

# >>> mimi-remote local codex ssh >>>
Host mimi-local
    HostName 127.0.0.1
    User fixture
    IdentityFile ~/.ssh/mimi_codex_local_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
# <<< mimi-remote local codex ssh <<<
`,
		"mimi_codex_local_ed25519":     "synthetic private key fixture\n",
		"mimi_codex_local_ed25519.pub": "synthetic public key fixture\n",
		"authorized_keys":              "synthetic authorized entry mimi-codex-local\n",
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(ssh, name), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	residue, err := inspectLegacyCodexExperiment(legacyExperimentInspectionOps{
		homeDir: func() (string, error) { return home, nil }, lstat: os.Lstat,
		launchctl: func(...string) (string, bool, error) { return "", false, nil },
	})
	if err != nil || residue != "" {
		t.Fatalf("current Desktop SSH reported as residue: %q, %v", residue, err)
	}
	for name, want := range files {
		got, err := os.ReadFile(filepath.Join(ssh, name))
		if err != nil || string(got) != want {
			t.Fatalf("unexpected SSH file change %s: %v", name, err)
		}
	}
	entries, err := os.ReadDir(ssh)
	if err != nil || len(entries) != len(files) {
		t.Fatalf("SSH entries changed: %v %v", entries, err)
	}
}
