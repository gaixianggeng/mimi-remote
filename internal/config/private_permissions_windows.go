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

var freeNTName = windows.NewLazySystemDLL("ntdll.dll").NewProc("RtlFreeUnicodeString")

func openPermissionFile(path string, modify bool) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	// CreateFileW can implicitly request SYNCHRONIZE, which even the owner
	// may lack on a noncanonical file. Request just descriptor and stat rights.
	var ntName windows.NTUnicodeString
	if err := windows.RtlDosPathNameToNtPathName(name, &ntName, nil, nil); err != nil {
		return nil, err.(windows.NTStatus).Errno()
	}
	defer freeNTName.Call(uintptr(unsafe.Pointer(&ntName)))
	attrs := windows.OBJECT_ATTRIBUTES{ObjectName: &ntName, Attributes: windows.OBJ_CASE_INSENSITIVE}
	attrs.Length = uint32(unsafe.Sizeof(attrs))
	access := uint32(windows.READ_CONTROL | windows.FILE_READ_ATTRIBUTES)
	if modify {
		access |= windows.WRITE_DAC
	}
	var h windows.Handle
	var status windows.IO_STATUS_BLOCK
	if err := windows.NtCreateFile(&h, access, &attrs, &status, nil, 0, permissionFileShare, windows.FILE_OPEN, windows.FILE_OPEN_REPARSE_POINT, 0, 0); err != nil {
		return nil, err.(windows.NTStatus).Errno()
	}
	return os.NewFile(uintptr(h), path), nil
}

// Capture the file ID on a metadata handle. os.Lstat on Windows can defer
// this lookup until SameFile and require SYNCHRONIZE under a restrictive DACL.
func permissionIdentity(path string) (os.FileInfo, error) {
	file, err := openPermissionFile(path, false)
	if err != nil {
		return nil, &os.PathError{Op: "inspect", Path: path, Err: err}
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

func permissionLinkCount(file *os.File, _ os.FileInfo) (uint64, error) {
	var info windows.ByHandleFileInformation
	err := windows.GetFileInformationByHandle(windows.Handle(file.Fd()), &info)
	return uint64(info.NumberOfLinks), err
}
