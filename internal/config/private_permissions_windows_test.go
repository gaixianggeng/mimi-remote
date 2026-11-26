package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"golang.org/x/sys/windows"
)

func TestWindowsRepairRejectsAndReplacesNoncanonicalDACLInPlace(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	owner := "(A;;FA;;;" + user.User.Sid.String() + ")"
	withoutSystem := owner + "(A;;FA;;;BA)"
	system := "(A;;FA;;;SY)"
	if user.User.Sid.IsWellKnown(windows.WinLocalSystemSid) {
		system = ""
		withoutSystem = "(A;;FA;;;BA)"
	}
	all := owner + system + "(A;;FA;;;BA)"
	for _, tc := range []struct {
		name, grants string
		inherited    bool
	}{
		{"unprotected", all, true},
		{"empty", "", false},
		{"missing administrators", owner + system, false},
		{"missing SYSTEM", withoutSystem, false},
		{"deny read", "(D;;FR;;;WD)" + all, false},
		{"metadata only extra grant", all + "(A;;0x80;;;BU)", false},
		{"restricted SYSTEM", withoutSystem + "(A;;FR;;;SY)", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "existing")
			configtest.CreatePrivateFile(t, path, []byte("fixture"))
			before, err := FileIdentity(path)
			if err != nil {
				t.Fatal(err)
			}
			sd, err := windows.SecurityDescriptorFromString("D:" + tc.grants)
			if err != nil {
				t.Fatal(err)
			}
			acl, _, err := sd.DACL()
			if err != nil {
				t.Fatal(err)
			}
			protection := windows.SECURITY_INFORMATION(windows.PROTECTED_DACL_SECURITY_INFORMATION)
			if tc.inherited {
				protection = windows.UNPROTECTED_DACL_SECURITY_INFORMATION
			}
			if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|protection, nil, nil, acl, nil); err != nil {
				t.Fatal(err)
			}
			if raw, err := ReadPrivatePreflightFile(path, 100); len(raw) != 0 || !errors.Is(err, errPreflightFileNotPrivate) {
				t.Fatalf("read noncanonical: %v", err)
			}
			if changed, err := RepairPrivatePermissions(path); !changed || err != nil {
				t.Fatalf("repair changed=%v err=%v", changed, err)
			}
			after, err := FileIdentity(path)
			if err != nil || !os.SameFile(before, after) {
				t.Fatal("changed identity")
			}
			if raw, err := ReadPrivatePreflightFile(path, 100); string(raw) != "fixture" || err != nil {
				t.Fatalf("repaired file: %v", err)
			}
			if changed, err := RepairPrivatePermissions(path); changed || err != nil {
				t.Fatalf("repeat changed=%v err=%v", changed, err)
			}
		})
	}
}

// NTFS may normalize duplicate grants and strip inheritance flags on an
// ordinary file. Verify the exact input descriptor before it reaches NTFS.
func TestWindowsRejectsDuplicateAndFlaggedACEs(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	for _, flag := range []uint8{windows.INHERITED_ACE, windows.OBJECT_INHERIT_ACE, windows.CONTAINER_INHERIT_ACE} {
		sd, err := privateDescriptor()
		if err != nil {
			t.Fatal(err)
		}
		acl, _, err := sd.DACL()
		if err != nil {
			t.Fatal(err)
		}
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, 0, &ace); err != nil {
			t.Fatal(err)
		}
		ace.Header.AceFlags = flag
		if privatePreflightDACL(acl, user.User.Sid) {
			t.Errorf("accepted flags %#x", flag)
		}
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;SY)(A;;FA;;;SY)(A;;FA;;;BA)")
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if privatePreflightDACL(acl, user.User.Sid) {
		t.Error("accepted duplicate SID")
	}
}

func TestWindowsRejectsForeignOwnerDespiteMatchingGrants(t *testing.T) {
	sd, err := privateDescriptor()
	if err != nil {
		t.Fatal(err)
	}
	foreign, err := windows.CreateWellKnownSid(windows.WinWorldSid)
	if err != nil {
		t.Fatal(err)
	}
	if err := checkPrivateDescriptor(sd, foreign); !errors.Is(err, errFileNotOwned) {
		t.Fatalf("owner check: %v", err)
	}
}
