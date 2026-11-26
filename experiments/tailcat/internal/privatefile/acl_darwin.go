package privatefile

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Darwin ACLs are independent of mode bits. Inspect kauth_filesec on the open
// descriptor with fgetattrlist, including in the shipped CGO_ENABLED=0 binary.
const (
	fileSecHeader = 44
	aceSize       = 24
	maxEntries    = 128
	fileSecMagic  = 0x012cc16d
	noACL         = 0xffffffff
)

func checkPermissionVolume(file *os.File) error {
	var fs unix.Statfs_t
	if err := unix.Fstatfs(int(file.Fd()), &fs); err != nil {
		return err
	}
	kind := unix.ByteSliceToString(fs.Fstypename[:])
	if (kind != "apfs" && kind != "hfs") || fs.Flags&unix.MNT_IGNORE_OWNERSHIP != 0 || fs.Flags&unix.MNT_LOCAL == 0 {
		return fmt.Errorf("%w：无法验证文件系统的访问控制", errNotPrivate)
	}
	return nil
}

func checkExtendedACL(file *os.File) error {
	// uint32 length, attrreference (offset and size), then kauth_filesec.
	buf := make([]byte, 12+fileSecHeader+maxEntries*aceSize)
	attr := unix.Attrlist{Bitmapcount: unix.ATTR_BIT_MAP_COUNT, Commonattr: unix.ATTR_CMN_EXTENDED_SECURITY}
	_, _, errno := syscall.Syscall6(unix.SYS_FGETATTRLIST, file.Fd(), uintptr(unsafe.Pointer(&attr)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0)
	runtime.KeepAlive(file)
	if errors.Is(errno, os.ErrPermission) {
		// A deny-readsecurity ACE can hide its own ACL from the owner.
		return errNotPrivate
	}
	if errno != 0 {
		return errno
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
	return errNotPrivate
}

const defaultID = ^uint32(0) - 100 // KAUTH_UID_NONE / KAUTH_GID_NONE

func noInheritACL() []byte {
	security := make([]byte, fileSecHeader)
	binary.NativeEndian.PutUint32(security, fileSecMagic)
	binary.NativeEndian.PutUint32(security[36:], noACL)
	binary.NativeEndian.PutUint32(security[40:], 1<<17) // KAUTH_ACL_NO_INHERIT
	return security
}

// Supply KAUTH_FILESEC_NOACL with KAUTH_ACL_NO_INHERIT at creation. A
// descriptor granted by an inherited ACE could survive a subsequent ACL repair.
func createPrivateNew(path string) (*os.File, error) {
	name, err := unix.BytePtrFromString(path)
	if err != nil {
		return nil, err
	}
	security := noInheritACL()
	flags := unix.O_RDWR | unix.O_CREAT | unix.O_EXCL | unix.O_CLOEXEC
	fd, _, errno := syscall.Syscall6(unix.SYS_OPEN_EXTENDED, uintptr(unsafe.Pointer(name)), uintptr(flags), uintptr(defaultID), uintptr(defaultID), 0600, uintptr(unsafe.Pointer(&security[0])))
	if errno != 0 {
		return nil, errno
	}
	return os.NewFile(fd, path), nil
}

func prepareStage(file *os.File) error {
	if err := checkExtendedACL(file); err != nil {
		return err
	}
	return file.Chmod(0600) // Normalize an owner umask on the empty stage.
}
