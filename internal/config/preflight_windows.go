//go:build windows

package config

import (
	"errors"
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

func openSnapshotFile(path string) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
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
		return errors.New("文件不属于当前用户")
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
	const sensitive = windows.GENERIC_ALL | windows.GENERIC_READ | windows.GENERIC_WRITE |
		windows.FILE_READ_DATA | windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_WRITE_ATTRIBUTES |
		windows.FILE_WRITE_EA | windows.DELETE | windows.WRITE_DAC | windows.WRITE_OWNER
	for i := uint16(0); i < acl.AceCount; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, uint32(i), &ace); err != nil {
			return false
		}
		if ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 || ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		// Object/callback ACEs have a different SID layout; keep the file
		// in recovery if its access cannot be established.
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return false
		}
		if ace.Mask&sensitive == 0 {
			continue
		}
		principal := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !principal.Equals(owner) && !principal.IsWellKnown(windows.WinLocalSystemSid) &&
			!principal.IsWellKnown(windows.WinBuiltinAdministratorsSid) && !principal.IsWellKnown(windows.WinCreatorOwnerRightsSid) {
			return false
		}
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
