//go:build darwin

package appserver

import (
	"errors"
	"os"
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
