package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"golang.org/x/sys/windows"
)

func TestWindowsSetupSavesConfigWithOldAutomaticCodex(t *testing.T) {
	clearSetupEnv(t)
	oldProbe := observeSetupAssistant
	observeSetupAssistant = func(context.Context, string, config.Config, string, PreflightHost) PreflightObservation {
		return unavailable("codex_version_too_old")
	}
	t.Cleanup(func() { observeSetupAssistant = oldProbe })
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex.cmd")
	if err := os.WriteFile(bin, []byte("@echo off\r\necho called > \"%~f0.called\"\r\necho codex-cli 0.149.0\r\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	path := filepath.Join(dir, "config.json")
	result, err := Run(context.Background(), Options{ConfigPath: path, ScanRoot: dir, BrowseRoot: dir, Listen: "127.0.0.1:8787", SaveOnly: true})
	if err != nil || !result.Created {
		t.Fatalf("fresh automatic config was not saved: %v", err)
	}
	cfg, err := config.Load(path)
	if err != nil || cfg.Codex.IsEnabled() || cfg.Codex.Bin != "codex" || cfg.AppServer.Transport != "ws" {
		t.Fatalf("saved config: binary=%q, transport=%q, err=%v", cfg.Codex.Bin, cfg.AppServer.Transport, err)
	}
	if _, err := os.Stat(bin + ".called"); !os.IsNotExist(err) {
		t.Fatalf("automatic setup ran the old CLI: %v", err)
	}
}

func TestWindowsSetupPreservesCanonicalDACLAndReferencedToken(t *testing.T) {
	clearSetupEnv(t)
	path := filepath.Join(t.TempDir(), "config.json")
	options := atomicSetupOptions(t, path, false)
	if _, err := Run(t.Context(), options); err != nil {
		t.Fatal(err)
	}
	prior, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	tokenPath := prior.AppServer.WSTokenFile
	dacl := func(path string) string {
		t.Helper()
		sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		return sd.String()
	}
	cfgACL, tokenACL := dacl(path), dacl(tokenPath)
	token, err := config.ReadPrivatePreflightFile(tokenPath, 4096)
	if err != nil {
		t.Fatal(err)
	}
	options.ScanRoot = t.TempDir()
	if _, err := Run(t.Context(), options); err != nil {
		t.Fatal(err)
	}
	options.ScanRoot = t.TempDir()
	fault := errors.New("directory flush")
	if _, err := runWithFileOps(t.Context(), options, failingSetupFileOps(path, "directory-fsync", fault)); !errors.Is(err, fault) {
		t.Fatalf("did not reach flush: %v", err)
	}
	post, err := config.Load(path)
	if err != nil || post.Auth.Token != prior.Auth.Token || post.AppServer.WSTokenFile != tokenPath {
		t.Fatalf("configuration no longer references original credentials: %v", err)
	}
	newToken, err := config.ReadPrivatePreflightFile(tokenPath, 4096)
	if err != nil || string(newToken) != string(token) {
		t.Fatalf("referenced WS token changed: %v", err)
	}
	if cfgACL != dacl(path) || tokenACL != dacl(tokenPath) {
		t.Fatal("canonical DACL changed after save or rollback")
	}
}

func TestWindowsStageChecksInheritedDACLBeforeWritingSecrets(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	owner := "(A;OICI;FA;;;" + user.User.Sid.String() + ")"
	setDACL := func(path, sddl string, protection windows.SECURITY_INFORMATION) {
		t.Helper()
		sd, err := windows.SecurityDescriptorFromString(sddl)
		if err != nil {
			t.Fatal(err)
		}
		acl, _, err := sd.DACL()
		if err != nil {
			t.Fatal(err)
		}
		if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|protection, nil, nil, acl, nil); err != nil {
			t.Fatal(err)
		}
	}
	destDir := t.TempDir()
	setDACL(destDir, "D:P"+owner+"(A;OICI;FR;;;WD)", windows.PROTECTED_DACL_SECURITY_INFORMATION)
	stageOps := privateFileStageOps{
		write: func(f *os.File, raw []byte) (int, error) {
			sd, err := windows.GetSecurityInfo(windows.Handle(f.Fd()), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
			if err != nil {
				t.Fatal(err)
			}
			control, _, err := sd.Control()
			if err != nil || control&windows.SE_DACL_PROTECTED == 0 {
				t.Fatal("stage inherited its parent DACL before writing")
			}
			if err := config.CheckPrivatePermissions(f.Name()); err != nil {
				t.Fatal(err)
			}
			return f.Write(raw)
		},
		sync: func(f *os.File) error { return f.Sync() },
	}
	name, err := stagePrivateFileWithOps(destDir, "stage-", []byte("fixture"), stageOps)
	if err != nil {
		t.Fatal(err)
	}
	if raw, err := config.ReadPrivatePreflightFile(name, 64); err != nil || string(raw) != "fixture" {
		t.Fatalf("published stage: %v", err)
	}
}
