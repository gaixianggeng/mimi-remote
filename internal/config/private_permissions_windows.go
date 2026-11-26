package config

import (
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

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
	h, err := windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE|windows.WRITE_DAC, permissionFileShare, &sa, windows.CREATE_NEW, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

func prepareNewPrivateFile(file *os.File) error { return verifyPrivateFile(file) }

func openPermissionFile(path string, modify bool) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	access := uint32(windows.READ_CONTROL)
	if modify {
		access |= windows.WRITE_DAC
	}
	h, err := windows.CreateFile(name, access, permissionFileShare, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_OVERLAPPED|windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

// Capture the file ID on a metadata handle. os.Lstat on Windows can defer
// this lookup until SameFile and require SYNCHRONIZE under a restrictive DACL.
func permissionIdentity(path string) (os.FileInfo, error) {
	file, err := openPermissionFile(path, false)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return file.Stat()
}

func setPrivateAccess(file *os.File) error {
	sd, err := privateDescriptor()
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
}
