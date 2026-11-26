//go:build windows

package privatefile

import (
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

func openNoFollow(path string) (*os.File, error) {
	return openExisting(path, windows.GENERIC_READ)
}

func openExisting(path string, access uint32) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(name, access, permissionFileShare, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

func checkAccess(file *os.File, _ os.FileInfo) error {
	descriptor, err := windows.GetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	current, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	return checkPrivateDescriptor(descriptor, current.User.Sid)
}

func checkPrivateDescriptor(descriptor *windows.SECURITY_DESCRIPTOR, user *windows.SID) error {
	owner, _, err := descriptor.Owner()
	if err != nil {
		return err
	}
	if owner == nil || !owner.Equals(user) {
		return errNotPrivate
	}
	control, _, err := descriptor.Control()
	if err != nil {
		return err
	}
	if control&windows.SE_DACL_PROTECTED == 0 {
		return errNotPrivate
	}
	acl, _, err := descriptor.DACL()
	if err != nil || !privatePreflightDACL(acl, owner) {
		return errNotPrivate
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

const permissionFileShare = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE

func privateDescriptor() (*windows.SECURITY_DESCRIPTOR, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	sid := user.User.Sid.String()
	dacl := "D:P(A;;FA;;;SY)(A;;FA;;;BA)"
	if !user.User.Sid.IsWellKnown(windows.WinLocalSystemSid) && !user.User.Sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) {
		dacl += "(A;;FA;;;" + sid + ")"
	}
	return windows.SecurityDescriptorFromString("O:" + sid + dacl)
}

// Supply the protected DACL at CREATE_NEW, before any handle can observe the file.
func createPrivateNew(path string) (*os.File, error) {
	sd, err := privateDescriptor()
	if err != nil {
		return nil, err
	}
	var sa windows.SecurityAttributes
	sa.Length = uint32(unsafe.Sizeof(sa))
	sa.SecurityDescriptor = sd
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE, permissionFileShare, &sa, windows.CREATE_NEW, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

// Stat the no-follow handle so SameFile uses a captured Windows file ID.
func identity(path string) (os.FileInfo, error) {
	file, err := openExisting(path, windows.FILE_READ_ATTRIBUTES)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return file.Stat()
}

// CREATE_NEW installs the complete protected DACL.
func prepareStage(*os.File) error { return nil }
