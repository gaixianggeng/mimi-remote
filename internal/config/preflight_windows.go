//go:build windows

package config

import (
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

func openSnapshotFile(path string) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

func checkPreflightFileAccess(file *os.File, _ os.FileInfo) error {
	descriptor, err := windows.GetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := descriptor.Owner()
	if err != nil {
		return err
	}
	current, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	if owner == nil || !owner.Equals(current.User.Sid) {
		return errFileNotOwned
	}
	control, _, err := descriptor.Control()
	if err != nil {
		return err
	}
	if control&windows.SE_DACL_PROTECTED == 0 {
		return errPreflightFileNotPrivate
	}
	acl, _, err := descriptor.DACL()
	if err != nil || !privatePreflightDACL(acl, owner) {
		return errPreflightFileNotPrivate
	}
	return nil
}

func privatePreflightDACL(acl *windows.ACL, owner *windows.SID) bool {
	// A NULL or absent DACL grants every principal full access.
	if acl == nil {
		return false
	}
	// FA in file SDDL is STANDARD_RIGHTS_REQUIRED | SYNCHRONIZE | 0x1ff.
	const fileAllAccess = 0x001f01ff
	expected := map[string]bool{owner.String(): true, "S-1-5-18": true, "S-1-5-32-544": true}
	if int(acl.AceCount) != len(expected) {
		return false
	}
	for i := uint16(0); i < acl.AceCount; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if windows.GetAce(acl, uint32(i), &ace) != nil || ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Header.AceFlags != 0 || ace.Mask != fileAllAccess {
			return false
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		if !expected[sid] {
			return false
		}
		delete(expected, sid)
	}
	return true
}

func directoryAccessible(path string, _ os.FileInfo, write bool) bool {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return false
	}
	access := uint32(windows.FILE_LIST_DIRECTORY | windows.FILE_TRAVERSE)
	if write {
		access = windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_TRAVERSE
	}
	h, err := windows.CreateFile(name, access, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return false
	}
	windows.CloseHandle(h)
	return true
}
