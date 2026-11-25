package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"golang.org/x/sys/windows"
)

func TestWindowsNativeACEComparison(t *testing.T) {
	parse := func(aces string) fileDACL {
		t.Helper()
		sd, err := windows.SecurityDescriptorFromString("O:SYD:" + aces)
		if err != nil {
			t.Fatal(err)
		}
		policy, err := filePolicy(sd)
		if err != nil {
			t.Fatal(err)
		}
		return policy
	}
	for _, tc := range []struct {
		name, original, stage string
		want                  bool
	}{
		{"generic read maps to file read", "(A;ID;GR;;;BU)", "(A;ID;FR;;;BU)", true},
		{"generic write maps to file write", "(A;ID;GW;;;BU)", "(A;ID;FW;;;BU)", true},
		{"generic all includes file read", "(A;ID;GA;;;SY)", "(A;ID;FR;;;SY)", true},
		{"new write for same SID", "(A;ID;GR;;;BU)", "(A;ID;GRGW;;;BU)", false},
		{"everyone is a different trustee", "(A;ID;GR;;;AU)", "(A;ID;GR;;;WD)", false},
		{"administrators is a different trustee", "(A;ID;GR;;;BU)", "(A;ID;GR;;;BA)", false},
		{"creator owner is a different trustee", "(A;ID;GR;;;CO)", "(A;ID;GR;;;SY)", false},
		{"owner rights cannot disappear", "(A;ID;FR;;;OW)", "", false},
		{"inherit only cannot become effective", "(A;OIIOID;GR;;;BU)", "(A;ID;FR;;;BU)", false},
		{"file propagation flags", "(A;OICINPID;GR;;;BU)", "(A;ID;FR;;;BU)", true},
		{"removed deny", "(D;;FW;;;BU)(A;ID;FA;;;BU)", "(A;ID;FA;;;BU)", false},
		{"reordered deny", "(D;;FW;;;BU)(A;ID;FA;;;BU)", "(A;ID;FA;;;BU)(D;;FW;;;BU)", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := parse(tc.original).preservedBy(parse(tc.stage)); got != tc.want {
				t.Fatalf("preservedBy = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestWindowsTokenStageAndRepairPreserveOwnerRestrictions(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "token")
	configtest.CreatePrivateFile(t, path, []byte("fixture"))
	// OWNER RIGHTS suppresses implicit owner grants. Repair may remove the
	// Users grant, but must retain the owner deny and the explicit grants.
	prefix := "D:P(D;;0x2;;;OW)(A;;FR;;;OW)(A;;FA;;;" + user.User.Sid.String() + ")(A;;FR;;;SY)"
	sd, err := windows.SecurityDescriptorFromString(prefix + "(A;;0x80;;;BU)")
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
	if f, err := CreatePrivateStage(dir, "token-", StagePermissions{Source: path, Token: true}); !errors.Is(err, errPreflightFileNotPrivate) {
		if f != nil {
			f.Close()
		}
		t.Fatalf("token stage accepted a foreign grant or returned unexpected error: %v", err)
	}
	if changed, err := RepairPrivateTokenPermissions(path); err != nil || !changed {
		t.Fatalf("repair changed=%t err=%v", changed, err)
	}
	want, err := windows.SecurityDescriptorFromString("O:" + user.User.Sid.String() + prefix)
	if err != nil {
		t.Fatal(err)
	}
	expected, err := filePolicy(want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	actual, err := filePolicy(got)
	if err != nil || !expected.preservedBy(actual) {
		t.Fatalf("repair lost an owner restriction: %v", err)
	}
	f, err := CreatePrivateStage(dir, "token-", StagePermissions{Source: path, Token: true})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if other, err := os.Open(f.Name()); err == nil {
		other.Close()
		t.Fatal("staging handle allowed another data open before publication")
	}
}

func TestWindowsSourceWithNullDACLCannotBeStaged(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "source")
	configtest.CreatePrivateFile(t, path, nil)
	if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	if f, err := CreatePrivateStage(dir, "stage-", StagePermissions{Source: path}); err == nil {
		f.Close()
		t.Fatal("stage accepted a NULL DACL")
	}
	files, err := os.ReadDir(dir)
	if err != nil || len(files) != 1 {
		t.Fatalf("unexpected staging files: %v", err)
	}
}
