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
	h, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

func checkPreflightFileAccess(file *os.File, _ os.FileInfo) error {
	return checkFilePrivacy(file, false)
}

func checkTokenFileAccess(file *os.File, _ os.FileInfo) error {
	return checkFilePrivacy(file, true)
}

func fileSecurityDescriptor(file *os.File, fields windows.SECURITY_INFORMATION) (*windows.SECURITY_DESCRIPTOR, error) {
	sd, err := windows.GetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, fields)
	if err != nil {
		return nil, err
	}
	if sd == nil || !sd.IsValid() {
		return nil, windows.ERROR_INVALID_SECURITY_DESCR
	}
	return sd, nil
}

const ownerDACL = windows.OWNER_SECURITY_INFORMATION | windows.DACL_SECURITY_INFORMATION

func checkFilePrivacy(file *os.File, token bool) error {
	sd, err := fileSecurityDescriptor(file, ownerDACL)
	if err != nil {
		return err
	}
	return checkOwnedDescriptor(sd, token)
}

func currentFileOwner(descriptor *windows.SECURITY_DESCRIPTOR) (*windows.SID, error) {
	owner, _, err := descriptor.Owner()
	if err != nil {
		return nil, err
	}
	current, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	if owner == nil || !owner.Equals(current.User.Sid) {
		return nil, errors.New("文件不属于当前用户")
	}
	return owner, nil
}

func checkOwnedDescriptor(descriptor *windows.SECURITY_DESCRIPTOR, token bool) error {
	owner, err := currentFileOwner(descriptor)
	if err != nil {
		return err
	}
	acl, _, err := descriptor.DACL()
	if err != nil {
		return err
	}
	return checkPrivateDACL(acl, owner, token)
}

func privateTrustee(sid, owner *windows.SID) bool {
	return sid.Equals(owner) || sid.IsWellKnown(windows.WinLocalSystemSid) ||
		sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) || sid.IsWellKnown(windows.WinCreatorOwnerRightsSid)
}

func checkPrivateDACL(acl *windows.ACL, owner *windows.SID, token bool) error {
	if acl == nil {
		return errPreflightFileNotPrivate
	}
	const metadata = windows.FILE_READ_ATTRIBUTES | windows.FILE_READ_EA | windows.READ_CONTROL | windows.SYNCHRONIZE | windows.FILE_EXECUTE
	for i := uint16(0); i < acl.AceCount; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, uint32(i), &ace); err != nil {
			return err
		}
		if ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 || ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return windows.ERROR_NOT_SUPPORTED
		}
		if !token && fileRights(uint32(ace.Mask))&^metadata == 0 {
			continue
		}
		if !privateTrustee((*windows.SID)(unsafe.Pointer(&ace.SidStart)), owner) {
			return errPreflightFileNotPrivate
		}
	}
	return nil
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
