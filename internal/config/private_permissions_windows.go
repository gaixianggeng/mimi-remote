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
	return applyFileDACL(file, sd)
}

func copyFileAccess(original, target *os.File, _ os.FileInfo) error {
	sd, err := windows.GetSecurityInfo(windows.Handle(original.Fd()), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	current := func() (string, error) {
		effective, err := windows.GetSecurityInfo(windows.Handle(target.Fd()), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			return "", err
		}
		return effective.String(), nil
	}
	want := sd.String()
	if want == "" {
		return errors.New("无法验证原文件 DACL")
	}
	got, err := current()
	if err != nil || got == want {
		return err
	}
	control, _, err := sd.Control()
	if err != nil {
		return err
	}
	if control&windows.SE_DACL_PROTECTED == 0 {
		// Unprotecting merges inheritable ACEs from the destination directory.
		// Establish and verify the exact policy while the stage is still empty.
		info, err := target.Stat()
		if err != nil {
			return err
		}
		if info.Size() != 0 {
			return errors.New("凭据暂存文件的继承权限已变更")
		}
	}
	if err = applyFileDACL(target, sd); err != nil {
		return err
	}
	got, err = current()
	if err == nil && got != want {
		err = errors.New("暂存文件无法保留原访问权限")
	}
	return err
}

func applyFileDACL(file *os.File, sd *windows.SECURITY_DESCRIPTOR) error {
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	if acl == nil {
		return errors.New("无法验证文件 DACL")
	}
	control, _, err := sd.Control()
	if err != nil {
		return err
	}
	info := windows.SECURITY_INFORMATION(windows.DACL_SECURITY_INFORMATION | windows.UNPROTECTED_DACL_SECURITY_INFORMATION)
	if control&windows.SE_DACL_PROTECTED != 0 {
		info = windows.DACL_SECURITY_INFORMATION | windows.PROTECTED_DACL_SECURITY_INFORMATION
	}
	return windows.SetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, info, nil, nil, acl, nil)
}
