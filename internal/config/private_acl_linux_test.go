package config

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestLinuxRejectsAndRemovesMaskedNamedACL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "existing")
	if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	// Linux POSIX ACL xattr v2. The named user has no effective access
	// because its group mask is zero, so the reported mode is still 0600.
	acl := binary.LittleEndian.AppendUint32(nil, 2)
	for _, entry := range []struct {
		tag, perm uint16
		id        uint32
	}{
		{1, 6, ^uint32(0)}, {2, 4, uint32(os.Geteuid() + 1)}, {4, 0, ^uint32(0)}, {16, 0, ^uint32(0)}, {32, 0, ^uint32(0)},
	} {
		acl = binary.LittleEndian.AppendUint16(acl, entry.tag)
		acl = binary.LittleEndian.AppendUint16(acl, entry.perm)
		acl = binary.LittleEndian.AppendUint32(acl, entry.id)
	}
	if err := unix.Setxattr(path, accessACL, acl, 0); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode() != 0600 {
		t.Fatal("invalid masked ACL fixture")
	}
	if err := CheckPrivatePermissions(path); !errors.Is(err, errPreflightFileNotPrivate) {
		t.Fatalf("accepted named ACL: %v", err)
	}
	if changed, err := RepairPrivatePermissions(path); !changed || err != nil {
		t.Fatalf("repair changed=%v err=%v", changed, err)
	}
	if _, err := unix.Getxattr(path, accessACL, nil); !errors.Is(err, unix.ENODATA) {
		t.Fatalf("ACL still present: %v", err)
	}
	if raw, err := ReadPrivatePreflightFile(path, 100); err != nil || string(raw) != "fixture" {
		t.Fatalf("repaired file: %v", err)
	}
}
