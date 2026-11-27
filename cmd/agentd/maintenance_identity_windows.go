package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	maintenanceImageName = "Mimi-Remote-Maintenance.exe"
	volumeNameNT         = 0x2
)

// The signed agentd binds this exact signed Inno image to the installed release.
var maintenanceImageSHA256 string
var errMaintenanceIdentity = errors.New("无法验证此版本的维护程序，请从官方下载页重新安装已签名的桌面安装包")

type pinnedFileIdentity struct {
	path          string
	nativePath    string
	volumeSerial  uint32
	fileIndexHigh uint32
	fileIndexLow  uint32
}

// ShellExecuteEx accepts a path. Pin its ancestors against replacement and
// use the volume GUID so a remapped drive letter cannot change the target.
func withLockedMaintenance(dir, digest string, verify func(*os.File) error, launch func(string) error) error {
	return withLockedMaintenanceIdentity(dir, digest, verify, func(identity pinnedFileIdentity) error {
		return launch(identity.path)
	})
}

func withLockedMaintenanceIdentity(dir, digest string, verify func(*os.File) error, launch func(pinnedFileIdentity) error) error {
	want, err := hex.DecodeString(digest)
	if err != nil || len(want) != sha256.Size {
		return errMaintenanceIdentity
	}
	path := filepath.Join(dir, maintenanceImageName)
	volume := filepath.VolumeName(path)
	if !filepath.IsAbs(path) {
		return errMaintenanceIdentity
	}
	current, err := maintenanceVolumeRoot(volume)
	if err != nil {
		return errMaintenanceIdentity
	}
	parts := strings.Split(path[len(volume)+1:], "\\")
	for i, part := range parts {
		if part == "" || part == "." || part == ".." || strings.ContainsAny(part, ":/") {
			return errMaintenanceIdentity
		}
		current = strings.TrimSuffix(current, "\\") + "\\" + part
		p, err := windows.UTF16PtrFromString(current)
		if err != nil {
			return errMaintenanceIdentity
		}
		directory := i+1 < len(parts)
		access := uint32(windows.GENERIC_READ)
		flags := uint32(windows.FILE_FLAG_OPEN_REPARSE_POINT)
		if directory {
			access = windows.FILE_LIST_DIRECTORY | windows.FILE_READ_ATTRIBUTES
			flags |= windows.FILE_FLAG_BACKUP_SEMANTICS
		}
		h, err := windows.CreateFile(p, access, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, flags, 0)
		if err != nil {
			return errMaintenanceIdentity
		}
		f := os.NewFile(uintptr(h), current)
		defer f.Close()
		var info windows.ByHandleFileInformation
		if windows.GetFileInformationByHandle(h, &info) != nil ||
			info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DEVICE) != 0 ||
			(info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0) != directory {
			return errMaintenanceIdentity
		}
		if directory {
			continue
		}
		hash := sha256.New()
		if _, err := io.Copy(hash, f); err != nil || !bytes.Equal(hash.Sum(nil), want) {
			return errMaintenanceIdentity
		}
		if _, err := f.Seek(0, io.SeekStart); err != nil || verify(f) != nil {
			return errMaintenanceIdentity
		}
		nativePath, err := finalNativePathByHandle(h)
		if err != nil {
			return errMaintenanceIdentity
		}
		return launch(pinnedFileIdentity{
			path:          current,
			nativePath:    nativePath,
			volumeSerial:  info.VolumeSerialNumber,
			fileIndexHigh: info.FileIndexHigh,
			fileIndexLow:  info.FileIndexLow,
		})
	}
	return errMaintenanceIdentity
}

func finalNativePathByHandle(handle windows.Handle) (string, error) {
	buf := make([]uint16, 4096)
	for {
		n, err := windows.GetFinalPathNameByHandle(handle, &buf[0], uint32(len(buf)), volumeNameNT)
		if err != nil || n == 0 {
			return "", errMaintenanceIdentity
		}
		if int(n) < len(buf) {
			return windows.UTF16ToString(buf[:n]), nil
		}
		if n > 32768 {
			return "", errMaintenanceIdentity
		}
		buf = make([]uint16, n+1)
	}
}

func verifyProcessMatchesIdentity(proc windows.Handle, identity pinnedFileIdentity) error {
	nativePath, err := queryProcessImagePath(proc, windows.PROCESS_NAME_NATIVE)
	if err != nil || !strings.EqualFold(nativePath, identity.nativePath) {
		return errMaintenanceIdentity
	}
	if err := verifyPathMatchesIdentity(identity.path, identity); err != nil {
		return err
	}
	if win32Path, err := queryProcessImagePath(proc, 0); err == nil && win32Path != "" {
		if err := verifyPathMatchesIdentity(win32Path, identity); err != nil {
			return err
		}
	}
	return nil
}

func queryProcessImagePath(proc windows.Handle, flags uint32) (string, error) {
	buf := make([]uint16, 4096)
	for {
		size := uint32(len(buf))
		err := windows.QueryFullProcessImageName(proc, flags, &buf[0], &size)
		if err == nil {
			return windows.UTF16ToString(buf[:size]), nil
		}
		if !errors.Is(err, windows.ERROR_INSUFFICIENT_BUFFER) || len(buf) >= 32768 {
			return "", err
		}
		buf = make([]uint16, len(buf)*2)
	}
}

func verifyPathMatchesIdentity(path string, identity pinnedFileIdentity) error {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return errMaintenanceIdentity
	}
	h, err := windows.CreateFile(
		p,
		windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_OPEN_REPARSE_POINT,
		0,
	)
	if err != nil {
		return errMaintenanceIdentity
	}
	defer windows.CloseHandle(h)
	var info windows.ByHandleFileInformation
	if windows.GetFileInformationByHandle(h, &info) != nil ||
		info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DEVICE|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		return errMaintenanceIdentity
	}
	if info.VolumeSerialNumber != identity.volumeSerial ||
		info.FileIndexHigh != identity.fileIndexHigh ||
		info.FileIndexLow != identity.fileIndexLow {
		return errMaintenanceIdentity
	}
	return nil
}

// A UI that pins the broker may itself start agentd by volume GUID.
func maintenanceVolumeRoot(volume string) (string, error) {
	name := strings.TrimPrefix(volume, `\\?\`)
	if len(name) == len("Volume{00000000-0000-0000-0000-000000000000}") && strings.EqualFold(name[:6], "Volume") {
		if _, err := windows.GUIDFromString(name[6:]); err != nil || name == volume {
			return "", errMaintenanceIdentity
		}
		return volume, nil
	}
	if len(name) != 2 || name[1] != ':' {
		return "", errMaintenanceIdentity
	}
	root, err := windows.UTF16PtrFromString(name + `\`)
	if err != nil {
		return "", err
	}
	var guid [64]uint16
	if err := windows.GetVolumeNameForVolumeMountPoint(root, &guid[0], uint32(len(guid))); err != nil {
		return "", err
	}
	return windows.UTF16ToString(guid[:]), nil
}

func verifyMaintenancePublisher(file *os.File) error {
	p, err := windows.UTF16PtrFromString(file.Name())
	if err != nil {
		return errMaintenanceIdentity
	}
	info := windows.WinTrustFileInfo{Size: uint32(unsafe.Sizeof(windows.WinTrustFileInfo{})), FilePath: p, File: windows.Handle(file.Fd())}
	data := windows.WinTrustData{
		Size: uint32(unsafe.Sizeof(windows.WinTrustData{})), UIChoice: windows.WTD_UI_NONE,
		UnionChoice: windows.WTD_CHOICE_FILE, FileOrCatalogOrBlobOrSgnrOrCert: unsafe.Pointer(&info),
		StateAction: windows.WTD_STATEACTION_VERIFY, ProvFlags: windows.WTD_CACHE_ONLY_URL_RETRIEVAL,
		RevocationChecks: windows.WTD_REVOKE_NONE,
	}
	err = windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	data.StateAction = windows.WTD_STATEACTION_CLOSE
	closeErr := windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	if err != nil || closeErr != nil {
		return errMaintenanceIdentity
	}
	return nil
}
