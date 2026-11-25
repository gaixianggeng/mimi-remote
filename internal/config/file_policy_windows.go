package config

import (
	"errors"
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Read only the access-governing SACL components. Reading audit entries
// would require SeSecurityPrivilege even for ordinary user-owned files.
const fileSecurity = windows.OWNER_SECURITY_INFORMATION | windows.DACL_SECURITY_INFORMATION |
	windows.LABEL_SECURITY_INFORMATION | windows.ATTRIBUTE_SECURITY_INFORMATION | windows.SCOPE_SECURITY_INFORMATION |
	0x80 | 0x100 // PROCESS_TRUST_LABEL_SECURITY_INFORMATION and ACCESS_FILTER_SECURITY_INFORMATION

func readStageDescriptor(file *os.File, token bool) (*windows.SECURITY_DESCRIPTOR, error) {
	h := windows.Handle(file.Fd())
	var flags uint32
	if err := windows.GetVolumeInformationByHandle(h, nil, 0, nil, nil, &flags, nil, 0); err != nil {
		return nil, err
	}
	if flags&windows.FILE_PERSISTENT_ACLS == 0 {
		return nil, errors.New("文件系统不支持持久访问控制")
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		return nil, err
	}
	if info.FileAttributes&(windows.FILE_ATTRIBUTE_DIRECTORY|windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_ENCRYPTED|windows.FILE_ATTRIBUTE_READONLY) != 0 {
		return nil, errors.New("无法保留文件的保护属性")
	}
	sd, err := fileSecurityDescriptor(file, fileSecurity)
	if err != nil {
		return nil, err
	}
	if err := checkOwnedDescriptor(sd, token); err != nil {
		return nil, err
	}
	return sd, nil
}

func verifyStagePolicy(want fileDACL, file *os.File, policy StagePermissions) error {
	sd, err := readStageDescriptor(file, policy.Token)
	if err != nil {
		return err
	}
	got, err := filePolicy(sd)
	if err != nil {
		return err
	}
	if policy.Source == "" {
		// A new file takes the directory's integrity policy in addition to
		// the required protected owner-only DACL.
		want.systemACEs = got.systemACEs
	}
	if !want.preservedBy(got) {
		return errors.New("暂存文件无法保留原访问权限")
	}
	return nil
}

func filePolicy(sd *windows.SECURITY_DESCRIPTOR) (fileDACL, error) {
	var policy fileDACL
	if sd == nil || !sd.IsValid() {
		return policy, windows.ERROR_INVALID_SECURITY_DESCR
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return policy, err
	}
	if owner == nil || !owner.IsValid() {
		return policy, windows.ERROR_INVALID_OWNER
	}
	policy.owner = string(unsafe.Slice((*byte)(unsafe.Pointer(owner)), owner.Len()))
	control, _, err := sd.Control()
	if err != nil {
		return policy, err
	}
	policy.protected = control&windows.SE_DACL_PROTECTED != 0
	policy.inheritanceControl = uint16(control & (windows.SE_DACL_DEFAULTED | windows.SE_DACL_AUTO_INHERITED | windows.SE_DACL_AUTO_INHERIT_REQ))
	if control&windows.SE_SACL_PRESENT != 0 {
		acl, _, err := sd.SACL()
		if err != nil {
			return policy, err
		}
		if acl != nil {
			for i := uint16(0); i < acl.AceCount; i++ {
				var ace *windows.ACCESS_ALLOWED_ACE
				if err := windows.GetAce(acl, uint32(i), &ace); err != nil {
					return policy, err
				}
				policy.systemACEs = append(policy.systemACEs, encodedACE(ace))
			}
		}
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return policy, err
	}
	if acl == nil {
		return policy, windows.ERROR_INVALID_ACL
	}
	policy.revision = *(*byte)(unsafe.Pointer(acl)) // AclRevision is the first byte of the native ACL header.
	for i := uint16(0); i < acl.AceCount; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, uint32(i), &ace); err != nil {
			return policy, err
		}
		entry := fileACE{encoded: encodedACE(ace), inherited: ace.Header.AceFlags&windows.INHERITED_ACE != 0}
		entry.deny = ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE
		const fileFlags = windows.INHERITED_ACE | windows.OBJECT_INHERIT_ACE | windows.CONTAINER_INHERIT_ACE | windows.NO_PROPAGATE_INHERIT_ACE
		if ace.Header.AceType == windows.ACCESS_ALLOWED_ACE_TYPE && ace.Header.AceFlags&^fileFlags == 0 {
			sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
			if !sid.IsValid() {
				return policy, windows.ERROR_INVALID_SID
			}
			if !sid.IsWellKnown(windows.WinCreatorOwnerRightsSid) {
				entry.allowSID = string(unsafe.Slice((*byte)(unsafe.Pointer(sid)), sid.Len()))
				entry.allowMask = fileRights(uint32(ace.Mask))
			}
		}
		policy.entries = append(policy.entries, entry)
	}
	return policy, nil
}

func encodedACE(ace *windows.ACCESS_ALLOWED_ACE) string {
	return string(unsafe.Slice((*byte)(unsafe.Pointer(ace)), ace.Header.AceSize))
}

func fileRights(mask uint32) uint32 {
	rights := mask &^ (windows.GENERIC_ALL | windows.GENERIC_READ | windows.GENERIC_WRITE | windows.GENERIC_EXECUTE)
	if mask&windows.GENERIC_ALL != 0 {
		rights |= windows.STANDARD_RIGHTS_REQUIRED | windows.SYNCHRONIZE | 0x1ff
	}
	if mask&windows.GENERIC_READ != 0 {
		rights |= windows.FILE_GENERIC_READ
	}
	if mask&windows.GENERIC_WRITE != 0 {
		rights |= windows.FILE_GENERIC_WRITE
	}
	if mask&windows.GENERIC_EXECUTE != 0 {
		rights |= windows.FILE_GENERIC_EXECUTE
	}
	return rights
}

// A regular file's own ACL cannot prevent deletion through its parent.
// Also exclude inheritable security-management grants: data sharing alone
// does not prevent a metadata-only handle from acquiring WRITE_DAC.
func checkStageDirectory(dir *os.File) error {
	info, err := dir.Stat()
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return windows.ERROR_DIRECTORY
	}
	sd, err := fileSecurityDescriptor(dir, ownerDACL)
	if err != nil {
		return err
	}
	current, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	if owner == nil || !privateTrustee(owner, current.User.Sid) {
		return errors.New("配置目录的所有者不受信任")
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	if acl == nil {
		return errPreflightFileNotPrivate
	}
	for i := uint16(0); i < acl.AceCount; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, uint32(i), &ace); err != nil {
			return err
		}
		if ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return windows.ERROR_NOT_SUPPORTED
		}
		principal := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if privateTrustee(principal, current.User.Sid) || principal.IsWellKnown(windows.WinCreatorOwnerSid) {
			continue
		}
		flags, rights := ace.Header.AceFlags, fileRights(uint32(ace.Mask))
		const security = windows.WRITE_DAC | windows.WRITE_OWNER
		const fileDeleteChild = 0x40
		const changeDirectory = security | windows.DELETE | fileDeleteChild | windows.FILE_WRITE_ATTRIBUTES | windows.FILE_WRITE_EA
		if flags&windows.INHERIT_ONLY_ACE == 0 && rights&changeDirectory != 0 ||
			flags&windows.OBJECT_INHERIT_ACE != 0 && rights&security != 0 {
			return errors.New("配置目录允许其他用户更改凭据文件")
		}
	}
	return nil
}
