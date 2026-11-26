package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
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

func TestWindowsSetupPreservesCustomPrivateDACLAndReferencedToken(t *testing.T) {
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
	principal, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	// Metadata-only access differentiates this fixture from a newly created private DACL.
	sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;" + principal.User.Sid.String() + ")(A;;0x80;;;BU)")
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
		t.Fatal(err)
	}
	tokenSD, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;" + principal.User.Sid.String() + ")(A;;FR;;;SY)")
	if err != nil {
		t.Fatal(err)
	}
	tokenDACL, _, err := tokenSD.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err := windows.SetNamedSecurityInfo(tokenPath, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, tokenDACL, nil); err != nil {
		t.Fatal(err)
	}
	cfgACL, tokenACL := configtest.FileAccess(t, path), configtest.FileAccess(t, tokenPath)
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
	if cfgACL != configtest.FileAccess(t, path) || tokenACL != configtest.FileAccess(t, tokenPath) {
		t.Fatal("custom DACL changed after save or rollback")
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
	sourceDir, destDir := t.TempDir(), t.TempDir()
	setDACL(sourceDir, "D:P"+owner, windows.PROTECTED_DACL_SECURITY_INFORMATION)
	setDACL(destDir, "D:P"+owner+"(A;OICI;FR;;;WD)", windows.PROTECTED_DACL_SECURITY_INFORMATION)
	source, err := config.CreatePrivateTemp(sourceDir, "source-")
	if err != nil {
		t.Fatal(err)
	}
	if err = source.Close(); err != nil {
		t.Fatal(err)
	}
	setDACL(source.Name(), "D:(A;;FA;;;"+user.User.Sid.String()+")", windows.UNPROTECTED_DACL_SECURITY_INFORMATION)
	if _, err = config.ReadPrivatePreflightFile(source.Name(), 64); err != nil {
		t.Fatal(err)
	}
	stageOps := privateFileStageOps{
		write: func(f *os.File, raw []byte) (int, error) {
			// If this filesystem can preserve the private policy exactly, it
			// must already be in effect at the first write.
			sd, err := windows.GetSecurityInfo(windows.Handle(f.Fd()), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
			if err != nil || strings.Contains(sd.String(), ";;;WD)") {
				t.Fatal("secret write attempted with an unsafe inherited DACL")
			}
			return f.Write(raw)
		},
		sync: func(f *os.File) error { return f.Sync() },
	}
	name, err := stagePrivateFileWithOps(destDir, "stage-", []byte("fixture"), config.StagePermissions{Source: source.Name()}, stageOps)
	if err == nil {
		if _, err := config.ReadPrivatePreflightFile(name, 64); err != nil {
			t.Fatal(err)
		}
		policy := func(p string) string {
			sd, err := windows.GetNamedSecurityInfo(p, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
			if err != nil {
				t.Fatal(err)
			}
			return sd.String()
		}
		if policy(name) != policy(source.Name()) {
			t.Fatal("staging changed the access policy")
		}
	} else {
		assertSetupDirectoryEntries(t, destDir)
	}
	tokenStage, err := stagePrivateFile(destDir, "token-", []byte("fixture"), config.StagePermissions{Token: true})
	if err != nil {
		t.Fatal(err)
	}
	companion := filepath.Join(destDir, "companion")
	if err := publishSetupCompanion(tokenStage, companion, defaultSetupFileTransactionOps()); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{tokenStage, companion} {
		raw, err := config.ReadPrivateTokenFile(path, 64)
		if err != nil || string(raw) != "fixture" {
			t.Fatalf("token inherited access from its directory: %v", err)
		}
		sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		control, _, err := sd.Control()
		if err != nil || control&windows.SE_DACL_PROTECTED == 0 {
			t.Fatalf("token lost its protected DACL: %v", err)
		}
	}

}

func TestWindowsTwoFileSaveRetainsBothPrivateDACLs(t *testing.T) {
	dir := t.TempDir()
	destination, token := filepath.Join(dir, "config.json"), filepath.Join(dir, "token")
	principal, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	sid := principal.User.Sid.String()
	for path, extra := range map[string]string{destination: "(A;;0x80;;;BU)", token: "(A;;FR;;;SY)"} {
		configtest.CreatePrivateFile(t, path, []byte("before"))
		sd, err := windows.SecurityDescriptorFromString("D:P(D;;0x2;;;OW)(A;;FA;;;" + sid + ")" + extra)
		if err != nil {
			t.Fatal(err)
		}
		acl, _, err := sd.DACL()
		if err != nil {
			t.Fatal(err)
		}
		if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
			t.Fatal(err)
		}
	}
	cfgBefore, tokenBefore := configtest.FileAccess(t, destination), configtest.FileAccess(t, token)
	if err := writeSetupFilesAtomically(destination, token, []byte("after"), []byte("new token"), defaultSetupFileTransactionOps()); err != nil {
		t.Fatal(err)
	}
	if configtest.FileAccess(t, destination) != cfgBefore || configtest.FileAccess(t, token) != tokenBefore {
		t.Fatal("two-file save changed an original owner or DACL")
	}
	raw, err := config.ReadPrivateTokenFile(token, 64)
	if err != nil || string(raw) != "new token" {
		t.Fatalf("token publication failed: %v", err)
	}
}

func TestWindowsPublishRejectsAnACLOnlyChange(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, path, []byte("old"))
	set := func(extra string) {
		t.Helper()
		sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;" + user.User.Sid.String() + ")" + extra)
		if err != nil {
			t.Fatal(err)
		}
		acl, _, err := sd.DACL()
		if err != nil {
			t.Fatal(err)
		}
		if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
			t.Fatal(err)
		}
	}
	set("(A;;FR;;;SY)")
	stage, err := stagePrivateFile(dir, "stage-", []byte("new"), config.StagePermissions{Source: path})
	if err != nil {
		t.Fatal(err)
	}
	set("")
	if err := renameSetupFile(stage, path); err == nil {
		t.Fatal("published access that the destination owner had removed")
	}
	raw, err := os.ReadFile(path)
	if err != nil || string(raw) != "old" {
		t.Fatal("failed publication changed the original")
	}
}
