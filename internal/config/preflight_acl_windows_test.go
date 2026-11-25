package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestReadPrivatePreflightFileChecksWindowsDACL(t *testing.T) {
	token, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	sid := token.User.Sid.String()
	path := filepath.Join(t.TempDir(), "fixture.json")
	if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, extra string
		private     bool
	}{
		{"owner, administrators and SYSTEM", "(A;;FA;;;BA)(A;;FA;;;SY)", true},
		{"everyone can read", "(A;;FR;;;WD)", false},
		{"authenticated users can replace", "(A;;FW;;;AU)", false},
		{"Users only see metadata", "(A;;0x80;;;BU)", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;" + sid + ")" + tc.extra)
			if err != nil {
				t.Fatal(err)
			}
			acl, _, err := sd.DACL()
			if err != nil {
				t.Fatal(err)
			}
			if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION|windows.OWNER_SECURITY_INFORMATION, token.User.Sid, nil, acl, nil); err != nil {
				t.Fatal(err)
			}
			b, err := ReadPrivatePreflightFile(path, 100)
			if tc.private && (err != nil || string(b) != "fixture") {
				t.Fatalf("read private fixture: %v", err)
			}
			if !tc.private && (!errors.Is(err, errPreflightFileNotPrivate) || len(b) != 0) {
				t.Fatalf("broad DACL: bytes=%d err=%v", len(b), err)
			}
		})
	}
	if privatePreflightDACL(nil, token.User.Sid) {
		t.Error("accepted a NULL DACL")
	}
}
