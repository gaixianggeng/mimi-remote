package privatefile

import (
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestWindowsRefusesExtraGrant(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identity")
	if err := Write(path, []byte("original")); err != nil {
		t.Fatal(err)
	}
	sd, err := privateDescriptor()
	if err != nil {
		t.Fatal(err)
	}
	// Add a read grant for Everyone to an otherwise canonical descriptor.
	sd, err = windows.SecurityDescriptorFromString(sd.String() + "(A;;FR;;;WD)")
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
	assertRefusesNoncanonicalFile(t, path)
}
