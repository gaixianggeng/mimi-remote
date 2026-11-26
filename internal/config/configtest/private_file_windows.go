package configtest

import (
	"os"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func createPrivateFile(path string) (*os.File, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	// The token's default owner can be a group. Specify the user as owner
	// and protect the DACL from permissions inherited from the temp directory.
	sid := user.User.Sid.String()
	grants := "(A;;FA;;;SY)(A;;FA;;;BA)"
	if !user.User.Sid.IsWellKnown(windows.WinLocalSystemSid) && !user.User.Sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) {
		grants += "(A;;FA;;;" + sid + ")"
	}
	sd, err := windows.SecurityDescriptorFromString("O:" + sid + "D:P" + grants)
	if err != nil {
		return nil, err
	}
	attrs := windows.SecurityAttributes{SecurityDescriptor: sd}
	attrs.Length = uint32(unsafe.Sizeof(attrs))
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(name, windows.GENERIC_WRITE, 0, &attrs, windows.CREATE_NEW, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

// SetNoncanonicalPermissions makes an existing owned fixture broader or narrower.
func SetNoncanonicalPermissions(t testing.TB, path string, narrow bool) {
	t.Helper()
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	grants := "(A;;FA;;;" + user.User.Sid.String() + ")(A;;FA;;;SY)"
	if !narrow {
		grants += "(A;;FA;;;BA)(A;;FR;;;WD)"
	}
	sd, err := windows.SecurityDescriptorFromString("D:P" + grants)
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
		t.Fatal(err)
	}
}
