package config

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Darwin ACLs are independent of mode bits. Use the descriptor versions of
// getattrlist / setattrlist so checking and copying ACLs also works in the
// shipped CGO_ENABLED=0 binary. The layout is kauth_filesec from sys/kauth.h.
const (
	fileSecHeader = 44
	aceSize       = 24
	maxEntries    = 128
	fileSecMagic  = 0x012cc16d
	noACL         = 0xffffffff
)

type darwinFileACL struct {
	data  []byte
	owner [16]byte
}

func fileACLAttr(fd uintptr, trap uintptr, attrs uint32, buf []byte) error {
	attr := unix.Attrlist{Bitmapcount: unix.ATTR_BIT_MAP_COUNT, Commonattr: attrs}
	_, _, err := syscall.Syscall6(trap, fd, uintptr(unsafe.Pointer(&attr)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0)
	if err != 0 {
		return err
	}
	return nil
}

func readFileACL(file *os.File) (darwinFileACL, error) {
	var acl darwinFileACL
	// uint32 length, attrreference (offset and size), owner UUID, then ACL data.
	buf := make([]byte, 28+fileSecHeader+maxEntries*aceSize)
	err := fileACLAttr(file.Fd(), unix.SYS_FGETATTRLIST, unix.ATTR_CMN_EXTENDED_SECURITY|unix.ATTR_CMN_UUID, buf)
	runtime.KeepAlive(file)
	if err != nil {
		return acl, err
	}
	le := binary.NativeEndian
	total := int(le.Uint32(buf))
	start := 4 + int(le.Uint32(buf[4:]))
	size := int(le.Uint32(buf[8:]))
	if total < 28 || total > len(buf) || start < 28 || start+size > total {
		return acl, errors.New("无效的文件 ACL 记录")
	}
	copy(acl.owner[:], buf[12:28])
	if size == 0 {
		return acl, nil
	}
	acl.data = buf[start : start+size]
	if size < fileSecHeader || le.Uint32(acl.data) != fileSecMagic {
		return acl, errors.New("无效的文件 ACL")
	}
	count := le.Uint32(acl.data[36:])
	if count == noACL && size == fileSecHeader {
		acl.data = nil
		return acl, nil
	}
	if count > maxEntries || size != fileSecHeader+int(count)*aceSize {
		return acl, errors.New("文件 ACL 条目数无效")
	}
	return acl, nil
}

func setFileACL(file *os.File, data []byte) error {
	if len(data) == 0 {
		data = make([]byte, fileSecHeader)
		binary.NativeEndian.PutUint32(data, fileSecMagic)
		binary.NativeEndian.PutUint32(data[36:], noACL)
	}
	// setattrlist consumes the attrreference and data without a leading length.
	buf := make([]byte, 8+len(data))
	binary.NativeEndian.PutUint32(buf, 8)
	binary.NativeEndian.PutUint32(buf[4:], uint32(len(data)))
	copy(buf[8:], data)
	err := fileACLAttr(file.Fd(), unix.SYS_FSETATTRLIST, unix.ATTR_CMN_EXTENDED_SECURITY, buf)
	runtime.KeepAlive(file)
	return err
}

func (a darwinFileACL) unsafeGrant(entry []byte) bool {
	flags := binary.NativeEndian.Uint32(entry[16:])
	rights := binary.NativeEndian.Uint32(entry[20:])
	// acl.h rights to read/write content, delete, change attributes or security,
	// take ownership, or grant any generic access. Metadata reads are harmless.
	const sensitive = (1 << 1) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 8) | (1 << 10) | (1 << 12) | (1 << 13) | (0xf << 21)
	if flags&0xf == 2 || flags&(1<<8) != 0 || rights&sensitive == 0 {
		return false
	}
	return a.owner == [16]byte{} || !bytes.Equal(a.owner[:], entry[:16])
}

func (a darwinFileACL) private() bool {
	for i := fileSecHeader; i < len(a.data); i += aceSize {
		if a.unsafeGrant(a.data[i : i+aceSize]) {
			return false
		}
	}
	return true
}

func checkExtendedACL(file *os.File) error {
	acl, err := readFileACL(file)
	if err != nil {
		return err
	}
	if !acl.private() {
		return errPreflightFileNotPrivate
	}
	return nil
}

func repairExtendedACL(file *os.File) error {
	acl, err := readFileACL(file)
	if err != nil || acl.private() {
		return err
	}
	data := append([]byte(nil), acl.data[:fileSecHeader]...)
	for i := fileSecHeader; i < len(acl.data); i += aceSize {
		entry := acl.data[i : i+aceSize]
		if !acl.unsafeGrant(entry) {
			data = append(data, entry...)
		}
	}
	binary.NativeEndian.PutUint32(data[36:], uint32((len(data)-fileSecHeader)/aceSize))
	return setFileACL(file, data)
}

func copyExtendedACL(source, target *os.File) error {
	src, err := readFileACL(source)
	if err != nil {
		return err
	}
	if !src.private() {
		return errPreflightFileNotPrivate
	}
	dst, err := readFileACL(target)
	if err != nil {
		return err
	}
	if bytes.Equal(src.data, dst.data) {
		return nil
	}
	return setFileACL(target, src.data)
}
