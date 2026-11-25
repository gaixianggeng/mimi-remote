package config

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

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
	dacl := func(path string) string {
		t.Helper()
		sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		return sd.String()
	}
	setACL(source, "(A;;FR;;;SY)(A;;0x80;;;BU)")
	expected := dacl(source)
	stage, err := CreatePrivateTemp(dir, "transaction-")
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
	if dacl(stage.Name()) != expected || dacl(source) != expected {
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
