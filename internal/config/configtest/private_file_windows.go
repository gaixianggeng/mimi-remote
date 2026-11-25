package configtest

import (
	"os"
	"strings"
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
	sd, err := windows.SecurityDescriptorFromString("O:" + sid + "D:P(A;;FA;;;" + sid + ")")
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

// FileAccess compares the file owner, DACL protection and ordered ACEs.
// Windows may set different automatic-inheritance bookkeeping bits on creation.
func FileAccess(t testing.TB, path string) (access struct {
	Owner     string
	Protected bool
	ACEs      string
}) {
	t.Helper()
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil || sd == nil {
		t.Fatalf("security descriptor: %v", err)
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil {
		t.Fatalf("file owner: %v", err)
	}
	control, _, err := sd.Control()
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil || acl == nil {
		t.Fatalf("file DACL: %v", err)
	}
	sddl := sd.String()
	if sddl == "" {
		t.Fatal("could not encode file security descriptor")
	}
	access.Owner = owner.String()
	access.Protected = control&windows.SE_DACL_PROTECTED != 0
	_, access.ACEs, _ = strings.Cut(sddl, "(")
	return access
}
