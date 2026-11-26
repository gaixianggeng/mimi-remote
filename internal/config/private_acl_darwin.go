package config

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Darwin ACLs are independent of mode bits. Use the descriptor versions of
// getattrlist / setattrlist so checking and stripping ACLs also works in the
// shipped CGO_ENABLED=0 binary. The layout is kauth_filesec from sys/kauth.h.
const (
	fileSecHeader = 44
	aceSize       = 24
	maxEntries    = 128
	fileSecMagic  = 0x012cc16d
	noACL         = 0xffffffff
)

func fileACLAttr(fd uintptr, trap uintptr, attrs uint32, buf []byte) error {
	attr := unix.Attrlist{Bitmapcount: unix.ATTR_BIT_MAP_COUNT, Commonattr: attrs}
	_, _, err := syscall.Syscall6(trap, fd, uintptr(unsafe.Pointer(&attr)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0)
	if err != 0 {
		return err
	}
	return nil
}

func checkExtendedACL(file *os.File) error {
	// uint32 length, attrreference (offset and size), then kauth_filesec.
	buf := make([]byte, 12+fileSecHeader+maxEntries*aceSize)
	err := fileACLAttr(file.Fd(), unix.SYS_FGETATTRLIST, unix.ATTR_CMN_EXTENDED_SECURITY, buf)
	runtime.KeepAlive(file)
	if err != nil {
		return err
	}
	le := binary.NativeEndian
	total := int(le.Uint32(buf))
	start := 4 + int(le.Uint32(buf[4:]))
	size := int(le.Uint32(buf[8:]))
	if total < 12 || total > len(buf) || start < 12 || start+size > total {
		return errors.New("无效的文件 ACL 记录")
	}
	if size == 0 {
		return nil
	}
	if size < fileSecHeader || le.Uint32(buf[start:]) != fileSecMagic {
		return errors.New("无效的文件 ACL")
	}
	if size == fileSecHeader && le.Uint32(buf[start+36:]) == noACL {
		return nil
	}
	return errPreflightFileNotPrivate
}

func emptyACLAttribute() []byte {
	// attrreference followed by kauth_filesec with KAUTH_FILESEC_NOACL.
	buf := make([]byte, 8+fileSecHeader)
	binary.NativeEndian.PutUint32(buf, 8)
	binary.NativeEndian.PutUint32(buf[4:], fileSecHeader)
	binary.NativeEndian.PutUint32(buf[8:], fileSecMagic)
	binary.NativeEndian.PutUint32(buf[8+36:], noACL)
	return buf
}

func repairExtendedACL(file *os.File) error {
	if err := checkExtendedACL(file); err != errPreflightFileNotPrivate {
		return err
	}
	err := fileACLAttr(file.Fd(), unix.SYS_FSETATTRLIST, unix.ATTR_CMN_EXTENDED_SECURITY, emptyACLAttribute())
	runtime.KeepAlive(file)
	return err
}

// Supply KAUTH_FILESEC_NOACL with KAUTH_ACL_NO_INHERIT at creation. A
// descriptor granted by an inherited ACE could survive a subsequent ACL repair.
func createPrivateNew(path string) (*os.File, error) {
	name, err := unix.BytePtrFromString(path)
	if err != nil {
		return nil, err
	}
	security := emptyACLAttribute()[8:]
	binary.NativeEndian.PutUint32(security[40:], 1<<17)
	const defaultID = ^uint32(0) - 100 // KAUTH_UID_NONE / KAUTH_GID_NONE
	flags := unix.O_RDWR | unix.O_CREAT | unix.O_EXCL | unix.O_CLOEXEC
	fd, _, errno := syscall.Syscall6(unix.SYS_OPEN_EXTENDED, uintptr(unsafe.Pointer(name)), uintptr(flags), uintptr(defaultID), uintptr(defaultID), 0600, uintptr(unsafe.Pointer(&security[0])))
	if errno != 0 {
		return nil, errno
	}
	return os.NewFile(fd, path), nil
}

func prepareNewPrivateFile(file *os.File) error {
	if err := checkExtendedACL(file); err != nil {
		return err
	}
	return MakeFilePrivate(file) // An owner umask may need normalizing.
}

func openPermissionFile(path string, _ bool) (*os.File, error) {
	file, err := openSnapshotFile(path)
	if errors.Is(err, os.ErrPermission) {
		return os.OpenFile(path, os.O_WRONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	}
	return file, err
}

func setPrivateMode(file *os.File) error { return file.Chmod(0600) }

// Darwin lacks an unprivileged metadata-only open for an inode denying both
// reads and writes. During explicit repair, pin it under a private directory
// descriptor and check its identity and owner before changing its attributes.
func repairInaccessibleFile(path string, openErr error) (bool, error) {
	if !errors.Is(openErr, os.ErrPermission) {
		return false, openErr
	}
	expected, err := os.Lstat(path)
	if err != nil {
		return false, err
	}
	stat := expected.Sys().(*syscall.Stat_t)
	if !expected.Mode().IsRegular() || stat.Uid != uint32(os.Geteuid()) {
		return false, errFileNotOwned
	}

	dir, err := os.MkdirTemp(filepath.Dir(path), ".permission-repair-")
	if err != nil {
		return false, err
	}
	defer os.Remove(dir)
	parent, err := os.OpenFile(dir, unix.O_NOFOLLOW|unix.O_DIRECTORY, 0)
	if err != nil {
		return false, err
	}
	defer parent.Close()
	info, err := parent.Stat()
	if err != nil {
		return false, err
	}
	if info.Mode() != os.ModeDir|0700 || info.Sys().(*syscall.Stat_t).Uid != stat.Uid {
		return false, errPreflightFileNotPrivate
	}
	if err := repairExtendedACL(parent); err != nil {
		return false, err
	}
	fd := int(parent.Fd())
	const alias = "original"
	if err := unix.Linkat(unix.AT_FDCWD, path, fd, alias, 0); err != nil {
		return false, err
	}
	defer unix.Unlinkat(fd, alias, 0)
	var pinned unix.Stat_t
	if err := unix.Fstatat(fd, alias, &pinned, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return false, err
	}
	if pinned.Dev != stat.Dev || pinned.Ino != stat.Ino || pinned.Uid != stat.Uid || pinned.Mode&unix.S_IFMT != unix.S_IFREG {
		return false, errors.New("文件已被替换")
	}

	// Apply the mode and empty ACL together, relative to the pinned directory.
	attrs := unix.Attrlist{Bitmapcount: unix.ATTR_BIT_MAP_COUNT, Commonattr: unix.ATTR_CMN_ACCESSMASK | unix.ATTR_CMN_EXTENDED_SECURITY}
	buf := append(make([]byte, 4), emptyACLAttribute()...)
	binary.NativeEndian.PutUint32(buf, 0600)
	name, _ := unix.BytePtrFromString(alias)
	_, _, errno := syscall.Syscall6(unix.SYS_SETATTRLISTAT, uintptr(fd), uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(&attrs)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), unix.FSOPT_NOFOLLOW)
	if errno != 0 {
		return false, errno
	}
	file, info, err := openPermissionTarget(path, false)
	if err != nil {
		return false, err
	}
	defer file.Close()
	if !os.SameFile(expected, info) {
		return false, errors.New("文件已被替换")
	}
	if err := checkPreflightFileAccess(file, info); err != nil {
		return false, err
	}
	return true, nil
}
