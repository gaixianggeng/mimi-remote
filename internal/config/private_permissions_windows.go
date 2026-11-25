package config

import (
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
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
	return windows.SecurityDescriptorFromString("O:" + sid + "D:P(A;;FA;;;" + sid + ")")
}

// CreatePrivateTemp supplies an owner DACL at CREATE_NEW so an inherited ACE can
// never give another process a handle to the staged credentials.
func CreatePrivateTemp(dir, prefix string) (*os.File, error) {
	if prefix == "" || prefix != filepath.Base(prefix) {
		return nil, errors.New("暂存文件前缀无效")
	}
	sd, err := ownerOnlyDescriptor()
	if err != nil {
		return nil, err
	}
	var sa windows.SecurityAttributes
	sa.Length = uint32(unsafe.Sizeof(sa))
	sa.SecurityDescriptor = sd
	for {
		path := filepath.Join(dir, prefix+rand.Text())
		name, err := windows.UTF16PtrFromString(path)
		if err != nil {
			return nil, err
		}
		h, err := windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE|windows.WRITE_DAC, permissionFileShare, &sa, windows.CREATE_NEW, windows.FILE_ATTRIBUTE_NORMAL, 0)
		if errors.Is(err, windows.ERROR_FILE_EXISTS) || errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
			continue
		}
		if err != nil {
			return nil, err
		}
		return os.NewFile(uintptr(h), path), nil
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

func MakeFilePrivate(file *os.File) error {
	sd, err := ownerOnlyDescriptor()
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return setFileDACL(file, acl, windows.PROTECTED_DACL_SECURITY_INFORMATION)
}

func copyFileAccess(original, target *os.File, _ os.FileInfo) error {
	sourceACL, source, err := readFileDACL(original)
	if err != nil {
		return err
	}
	_, stage, err := readFileDACL(target)
	if err != nil || source.preservedBy(stage) {
		return err
	}
	protection := windows.SECURITY_INFORMATION(windows.PROTECTED_DACL_SECURITY_INFORMATION)
	if !source.protected {
		// Unprotecting may add access from the destination directory. Verify
		// the result while the stage is empty, before anyone can read secrets.
		info, err := target.Stat()
		if err != nil {
			return err
		}
		if info.Size() != 0 {
			return errors.New("凭据暂存文件的继承权限已变更")
		}
		protection = windows.UNPROTECTED_DACL_SECURITY_INFORMATION
		// Only edit the local ACL returned by GetSecurityInfo. Windows will
		// supply the inherited entries from the stage's own parent.
		for i := len(source.entries) - 1; i >= 0; i-- {
			if source.entries[i].inherited {
				r, _, err := deleteAce.Call(uintptr(unsafe.Pointer(sourceACL)), uintptr(i))
				if r == 0 {
					return err
				}
			}
		}
	}
	if err := setFileDACL(target, sourceACL, protection); err != nil {
		return err
	}
	_, stage, err = readFileDACL(target)
	if err != nil {
		return err
	}
	if !source.preservedBy(stage) {
		return errors.New("暂存文件无法保留原访问权限")
	}
	return nil
}

var deleteAce = windows.NewLazySystemDLL("advapi32.dll").NewProc("DeleteAce")

func setFileDACL(file *os.File, acl *windows.ACL, protection windows.SECURITY_INFORMATION) error {
	if acl == nil {
		return errors.New("无法验证文件 DACL")
	}
	return windows.SetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|protection, nil, nil, acl, nil)
}

func readFileDACL(file *os.File) (*windows.ACL, fileDACL, error) {
	sd, err := windows.GetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return nil, fileDACL{}, err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return nil, fileDACL{}, err
	}
	if acl == nil {
		return nil, fileDACL{}, errors.New("无法验证文件 DACL")
	}
	control, _, err := sd.Control()
	if err != nil {
		return nil, fileDACL{}, err
	}
	policy := fileDACL{protected: control&windows.SE_DACL_PROTECTED != 0}
	for i := uint16(0); i < acl.AceCount; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, uint32(i), &ace); err != nil {
			return nil, fileDACL{}, err
		}
		entry := fileACE{
			encoded:   string(unsafe.Slice((*byte)(unsafe.Pointer(ace)), ace.Header.AceSize)),
			inherited: ace.Header.AceFlags&windows.INHERITED_ACE != 0,
		}
		const fileFlags = windows.INHERITED_ACE | windows.OBJECT_INHERIT_ACE | windows.CONTAINER_INHERIT_ACE | windows.NO_PROPAGATE_INHERIT_ACE
		if ace.Header.AceType == windows.ACCESS_ALLOWED_ACE_TYPE && ace.Header.AceFlags&^fileFlags == 0 {
			sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
			// Removing an OWNER RIGHTS ACE can restore implicit owner access.
			if !sid.IsWellKnown(windows.WinCreatorOwnerRightsSid) {
				entry.allowSID = sid.String()
				entry.allowMask = uint32(ace.Mask)
			}
		}
		policy.entries = append(policy.entries, entry)
	}
	return acl, policy, nil
}
