package config

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"golang.org/x/sys/windows"
)

func TestCopyAndRepairPrivateWindowsDACL(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	sid := user.User.Sid.String()
	dir := t.TempDir()
	source := filepath.Join(dir, "existing")
	original := []byte("synthetic-private-fixture")
	if err := os.WriteFile(source, original, 0600); err != nil {
		t.Fatal(err)
	}
	setACL := func(path, extra string) {
		t.Helper()
		sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;" + sid + ")" + extra)
		if err != nil {
			t.Fatal(err)
		}
		acl, _, err := sd.DACL()
		if err != nil {
			t.Fatal(err)
		}
		err = windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION|windows.OWNER_SECURITY_INFORMATION, user.User.Sid, nil, acl, nil)
		if err != nil {
			t.Fatal(err)
		}
	}
	setACL(source, "(A;;FR;;;SY)(A;;0x80;;;BU)")
	expected := configtest.FileAccess(t, source)
	stage, err := CreatePrivateStage(dir, "transaction-", StagePermissions{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := stage.Write(original); err != nil {
		t.Fatal(err)
	}
	if err := stage.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadPrivatePreflightFile(stage.Name(), 1024); err != nil {
		t.Fatal(err)
	}
	if err := CopyPrivatePermissions(source, stage.Name()); err != nil {
		t.Fatal(err)
	}
	if configtest.FileAccess(t, stage.Name()) != expected || configtest.FileAccess(t, source) != expected {
		t.Fatal("copy changed a protected Windows access policy")
	}
	setACL(source, "(A;;FR;;;WD)")
	before, err := os.Stat(source)
	if err != nil {
		t.Fatal(err)
	}
	changed, err := RepairPrivatePermissions(source)
	if err != nil || !changed {
		t.Fatalf("repair changed=%v err=%v", changed, err)
	}
	raw, err := ReadPrivatePreflightFile(source, 1024)
	if err != nil || !bytes.Equal(raw, original) {
		t.Fatalf("private identity read: %v", err)
	}
	after, err := os.Stat(source)
	if err != nil || !os.SameFile(before, after) {
		t.Fatal("changed file identity during DACL repair")
	}
	if changed, err := RepairPrivatePermissions(source); err != nil || changed {
		t.Fatalf("repeat repair changed=%v err=%v", changed, err)
	}
}

func TestWindowsCopyPrivatePermissionsBeforeAndAfterWrite(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
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
	setDACL(dir, "D:P(A;OICI;FA;;;"+user.User.Sid.String()+")", windows.PROTECTED_DACL_SECURITY_INFORMATION)

	for _, tc := range []struct {
		name                        string
		protected, explicitMetadata bool
	}{
		{"protected at creation", true, false},
		{"inherited at creation", false, false},
		{"explicit and inherited", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(dir, tc.name)
			if tc.protected {
				configtest.CreatePrivateFile(t, path, nil)
			} else {
				if err := os.WriteFile(path, nil, 0600); err != nil {
					t.Fatal(err)
				}
				// An elevated runner can have a group as its default owner.
				if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION, user.User.Sid, nil, nil, nil); err != nil {
					t.Fatal(err)
				}
				if tc.explicitMetadata {
					setDACL(path, "D:(A;;0x80;;;BU)", windows.UNPROTECTED_DACL_SECURITY_INFORMATION)
				}
			}
			aces := func(path string) string {
				t.Helper()
				sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
				if err != nil {
					t.Fatal(err)
				}
				control, _, err := sd.Control()
				if err != nil {
					t.Fatal(err)
				}
				if protected := control&windows.SE_DACL_PROTECTED != 0; protected != tc.protected {
					t.Fatalf("DACL protected = %v, want %v", protected, tc.protected)
				}
				_, entries, ok := strings.Cut(sd.String(), "(")
				if !ok || strings.Contains(entries, "ID;") != !tc.protected {
					t.Fatal("missing or unexpected inherited ACE")
				}
				return entries
			}
			want := aces(path)
			stage, err := CreatePrivateStage(dir, "stage-", StagePermissions{Source: path})
			if err != nil {
				t.Fatal(err)
			}
			sd, err := readStageDescriptor(stage, false)
			if err != nil {
				t.Fatal(err)
			}
			policy, err := filePolicy(sd)
			if err != nil || policy.protected != tc.protected {
				t.Fatalf("policy before first write: %v", err)
			}
			if _, err := stage.WriteString("fixture"); err != nil {
				t.Fatal(err)
			}
			if err := stage.Close(); err != nil {
				t.Fatal(err)
			}
			if err := CopyPrivatePermissions(path, stage.Name()); err != nil {
				t.Fatalf("populated stage: %v", err)
			}
			published := filepath.Join(dir, tc.name+"-published")
			if err := os.Rename(stage.Name(), published); err != nil {
				t.Fatal(err)
			}
			if aces(path) != want || aces(published) != want {
				t.Fatal("source or stage ACEs changed at final verification")
			}
		})
	}
}
