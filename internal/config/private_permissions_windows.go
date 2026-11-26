package config

import (
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

const permissionFileShare = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE

func ownerOnlyDescriptor() (*windows.SECURITY_DESCRIPTOR, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	sid := user.User.Sid.String()
	if sid == "" {
		return nil, windows.ERROR_INVALID_SID
	}
	return windows.SecurityDescriptorFromString("O:" + sid + "D:P(A;;FA;;;" + sid + ")")
}

func CreatePrivateTemp(dir, prefix string) (*os.File, error) {
	return CreatePrivateStage(dir, prefix, StagePermissions{})
}

// CreatePrivateStage requests the original policy at CREATE_NEW. The handle
// excludes other data and delete opens until its caller has finished writing.
// An inheritance mismatch discards the empty object without ever repurposing it.
func CreatePrivateStage(dir, prefix string, policy StagePermissions) (*os.File, error) {
	if prefix == "" || !filepath.IsLocal(prefix) || prefix != filepath.Base(prefix) || strings.Contains(prefix, ":") {
		return nil, errors.New("暂存文件前缀无效")
	}
	parent, err := openSnapshotFile(dir)
	if err != nil {
		return nil, err
	}
	defer parent.Close()
	if err := checkStageDirectory(parent); err != nil {
		return nil, err
	}
	sd, err := ownerOnlyDescriptor()
	if err != nil {
		return nil, err
	}
	if policy.Source != "" {
		original, _, err := openPermissionTarget(policy.Source, false)
		if err != nil {
			return nil, err
		}
		defer original.Close()
		sd, err = readStageDescriptor(original, policy.Token)
		if err != nil {
			return nil, err
		}
	}
	want, err := filePolicy(sd)
	if err != nil {
		return nil, err
	}
	// Keep only explicit DACL entries in the creation request. Windows
	// computes the actual inherited entries from this stage's parent.
	acl, _, err := sd.DACL()
	if err != nil {
		return nil, err
	}
	if !want.protected {
		for i := len(want.entries) - 1; i >= 0; i-- {
			if want.entries[i].inherited {
				if err := removeACE(acl, i); err != nil {
					return nil, err
				}
			}
		}
	}
	// Request only the owner and DACL. The destination supplies its system
	// ACL and inherited entries, which must pass the handle readback.
	if policy.Source != "" {
		owner, _, err := sd.Owner()
		if err != nil {
			return nil, err
		}
		creation, err := windows.NewSecurityDescriptor()
		if err != nil {
			return nil, err
		}
		if err := creation.SetOwner(owner, false); err != nil {
			return nil, err
		}
		if err := creation.SetDACL(acl, true, false); err != nil {
			return nil, err
		}
		if want.protected {
			if err := creation.SetControl(windows.SE_DACL_PROTECTED, windows.SE_DACL_PROTECTED); err != nil {
				return nil, err
			}
		}
		sd, err = creation.ToSelfRelative()
		if err != nil {
			return nil, err
		}
	}
	for {
		base := prefix + rand.Text()
		name, err := windows.NewNTUnicodeString(base)
		if err != nil {
			return nil, err
		}
		attrs := windows.OBJECT_ATTRIBUTES{
			Length:        uint32(unsafe.Sizeof(windows.OBJECT_ATTRIBUTES{})),
			RootDirectory: windows.Handle(parent.Fd()), ObjectName: name,
			Attributes: windows.OBJ_CASE_INSENSITIVE, SecurityDescriptor: sd,
		}
		var h windows.Handle
		var status windows.IO_STATUS_BLOCK
		const access = windows.FILE_GENERIC_READ | windows.FILE_GENERIC_WRITE | windows.DELETE
		const options = windows.FILE_NON_DIRECTORY_FILE | windows.FILE_SYNCHRONOUS_IO_NONALERT
		err = windows.NtCreateFile(&h, access, &attrs, &status, nil, windows.FILE_ATTRIBUTE_NORMAL, 0, windows.FILE_CREATE, options, 0, 0)
		if errors.Is(err, windows.STATUS_OBJECT_NAME_COLLISION) {
			continue
		}
		if err != nil {
			return nil, err
		}
		f := os.NewFile(uintptr(h), filepath.Join(dir, base))
		if err := verifyStagePolicy(want, f, policy); err != nil {
			// Dispose of the rejected object by handle while its name is pinned.
			remove := byte(1)
			cleanupErr := windows.SetFileInformationByHandle(h, windows.FileDispositionInfo, &remove, 1)
			return nil, errors.Join(err, cleanupErr, f.Close())
		}
		return f, nil
	}
}

func openPermissionWriter(path string) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(name, windows.READ_CONTROL|windows.WRITE_DAC|windows.FILE_READ_ATTRIBUTES, permissionFileShare, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

// Repair an existing DACL by subtracting grants. Replacing it with owner
// full control could undo a deny or restore implicit rights to the owner.
func MakeFilePrivate(file *os.File) error {
	sd, err := fileSecurityDescriptor(file, ownerDACL)
	if err != nil {
		return err
	}
	owner, err := currentFileOwner(sd)
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	if acl == nil { // A confirmed NULL DACL grants everyone full control.
		private, err := ownerOnlyDescriptor()
		if err != nil {
			return err
		}
		acl, _, err = private.DACL()
		if err != nil || acl == nil {
			return windows.ERROR_INVALID_ACL
		}
	} else {
		for i := int(acl.AceCount) - 1; i >= 0; i-- {
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
			if !privateTrustee((*windows.SID)(unsafe.Pointer(&ace.SidStart)), owner) {
				if err := removeACE(acl, i); err != nil {
					return err
				}
			}
		}
	}
	return windows.SetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
}

var deleteAce = windows.NewLazySystemDLL("advapi32.dll").NewProc("DeleteAce")

func removeACE(acl *windows.ACL, index int) error {
	r, _, err := deleteAce.Call(uintptr(unsafe.Pointer(acl)), uintptr(index))
	if r == 0 {
		return err
	}
	return nil
}

// Populated Windows stages are only verified. No pathname-based check may
// change their ACL or introduce an access window after the first write.
func copyFileAccess(original, target *os.File, _ os.FileInfo) error {
	sd, err := readStageDescriptor(original, false)
	if err != nil {
		return err
	}
	want, err := filePolicy(sd)
	if err != nil {
		return err
	}
	return verifyStagePolicy(want, target, StagePermissions{Source: original.Name()})
}
