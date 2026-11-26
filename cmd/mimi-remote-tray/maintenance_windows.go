//go:build windows

package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	cmsgSigned                     = 2
	cmsgTypeParam                  = 1
	cmsgContentParam               = 2
	cmsgSignerCountParam           = 5
	cmsgSignerCertInfoParam        = 7
	cmsgCtrlVerifySignature        = 1
	certChainCacheOnlyURLRetrieval = 0x00000004
	oidCodeSigning                 = "1.3.6.1.5.5.7.3.3"
	errorCancelledExitCode         = 1223
	maintenanceVolumeNameNT        = 0x2
	trayJobMsgActiveProcessZero    = 4
)

type trayJobAssociateCompletionPort struct {
	CompletionKey  uintptr
	CompletionPort windows.Handle
}

var (
	maintCrypt32  = windows.NewLazySystemDLL("crypt32.dll")
	maintWintrust = windows.NewLazySystemDLL("wintrust.dll")

	procCryptMsgOpenToDecode             = maintCrypt32.NewProc("CryptMsgOpenToDecode")
	procCryptMsgUpdate                   = maintCrypt32.NewProc("CryptMsgUpdate")
	procCryptMsgGetParam                 = maintCrypt32.NewProc("CryptMsgGetParam")
	procCryptMsgControl                  = maintCrypt32.NewProc("CryptMsgControl")
	procCryptMsgClose                    = maintCrypt32.NewProc("CryptMsgClose")
	procCertGetSubjectCertificateFromStr = maintCrypt32.NewProc("CertGetSubjectCertificateFromStore")

	procWTHelperProvDataFromStateData  = maintWintrust.NewProc("WTHelperProvDataFromStateData")
	procWTHelperGetProvSignerFromChain = maintWintrust.NewProc("WTHelperGetProvSignerFromChain")
	procWTHelperGetProvCertFromChain   = maintWintrust.NewProc("WTHelperGetProvCertFromChain")
)

type windowsCryptProviderCert struct {
	cbStruct uint32
	pCert    *windows.CertContext
}

// ptrFromWin32Addr converts a Windows C-allocated address returned as uintptr
// by LazyProc.Call into a typed pointer without tripping go vet's unsafeptr check.
func ptrFromWin32Addr[T any](addr uintptr) *T {
	if addr == 0 {
		return nil
	}
	return *(**T)(unsafe.Pointer(&addr))
}

type windowsPinnedDir struct {
	volumeDir string
	handles   []*os.File
}

func (d *windowsPinnedDir) closeAll() {
	for i := len(d.handles) - 1; i >= 0; i-- {
		_ = d.handles[i].Close()
	}
	d.handles = nil
}

func (d *windowsPinnedDir) openPinnedFile(name string, missingKind maintenanceFailureKind) (*os.File, string, windows.ByHandleFileInformation, error) {
	var zero windows.ByHandleFileInformation
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `\/:`) {
		return nil, "", zero, newMaintenanceError(maintenanceFailureReparsePoint)
	}
	fullPath := strings.TrimSuffix(d.volumeDir, `\`) + `\` + name
	p, err := windows.UTF16PtrFromString(fullPath)
	if err != nil {
		return nil, "", zero, newMaintenanceError(maintenanceFailureReparsePoint)
	}
	h, err := windows.CreateFile(
		p,
		windows.GENERIC_READ,
		windows.FILE_SHARE_READ,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_OPEN_REPARSE_POINT,
		0,
	)
	if err != nil {
		if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, windows.ERROR_PATH_NOT_FOUND) {
			return nil, "", zero, newMaintenanceError(missingKind)
		}
		return nil, "", zero, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	f := os.NewFile(uintptr(h), fullPath)
	var info windows.ByHandleFileInformation
	if windows.GetFileInformationByHandle(h, &info) != nil ||
		info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DEVICE|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		_ = f.Close()
		return nil, "", zero, newMaintenanceError(maintenanceFailureReparsePoint)
	}
	d.handles = append(d.handles, f)
	return f, fullPath, info, nil
}

func (d *windowsPinnedDir) ReadReceipt(name string, maxBytes int64) ([]byte, error) {
	f, _, _, err := d.openPinnedFile(name, maintenanceFailureReceiptMissing)
	if err != nil {
		return nil, err
	}
	limited := io.LimitReader(f, maxBytes+1)
	raw, err := io.ReadAll(limited)
	if err != nil || int64(len(raw)) > maxBytes || len(raw) == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	return raw, nil
}

func (d *windowsPinnedDir) VerifyPinnedImage(name string, expectedDigest []byte, expectedPublisher []byte) (pinnedBrokerImage, error) {
	f, fullPath, info, err := d.openPinnedFile(name, maintenanceFailureImageMissing)
	if err != nil {
		return pinnedBrokerImage{}, err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, f); err != nil {
		return pinnedBrokerImage{}, newMaintenanceError(maintenanceFailureDigestMismatch)
	}
	if subtle.ConstantTimeCompare(hash.Sum(nil), expectedDigest) != 1 {
		return pinnedBrokerImage{}, newMaintenanceError(maintenanceFailureDigestMismatch)
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return pinnedBrokerImage{}, newMaintenanceError(maintenanceFailureAuthenticodeFailed)
	}
	if err := verifyAuthenticodeOnHandle(f, expectedPublisher); err != nil {
		return pinnedBrokerImage{}, err
	}
	nativePath, err := trayFinalNativePathByHandle(windows.Handle(f.Fd()))
	if err != nil {
		return pinnedBrokerImage{}, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	return pinnedBrokerImage{
		Path:            fullPath,
		NativeImagePath: nativePath,
		VolumeSerial:    info.VolumeSerialNumber,
		FileIndexHigh:   info.FileIndexHigh,
		FileIndexLow:    info.FileIndexLow,
	}, nil
}

func defaultWindowsMaintenanceOps() maintenancePlatformOps {
	return maintenancePlatformOps{
		isElevated:        windowsProcessIsElevated,
		withPinnedInstall: windowsWithPinnedInstall,
		verifyCMSReceipt:  windowsVerifyCMSReceipt,
		runBroker:         windowsRunMaintenanceBroker,
	}
}

func windowsProcessIsElevated() (bool, error) {
	var elevated, size uint32
	err := windows.GetTokenInformation(
		windows.GetCurrentProcessToken(),
		windows.TokenElevation,
		(*byte)(unsafe.Pointer(&elevated)),
		uint32(unsafe.Sizeof(elevated)),
		&size,
	)
	if err != nil {
		return false, err
	}
	return elevated != 0, nil
}

func windowsWithPinnedInstall(installDir string, fn func(pinned pinnedMaintenanceDir) error) error {
	cleaned := filepath.Clean(installDir)
	volume := filepath.VolumeName(cleaned)
	if !filepath.IsAbs(cleaned) || volume == "" || strings.HasPrefix(cleaned, `\\`) && !strings.HasPrefix(cleaned, `\\?\Volume{`) {
		return newMaintenanceError(maintenanceFailureReparsePoint)
	}
	current, err := resolveMaintenanceVolumeRoot(volume)
	if err != nil {
		return newMaintenanceError(maintenanceFailureReparsePoint)
	}
	remainder := strings.TrimPrefix(cleaned[len(volume):], `\`)
	if remainder == "" {
		return newMaintenanceError(maintenanceFailureReparsePoint)
	}
	parts := strings.Split(remainder, `\`)
	pinned := &windowsPinnedDir{}
	defer pinned.closeAll()

	for _, part := range parts {
		if part == "" || part == "." || part == ".." || strings.ContainsAny(part, ":/") {
			return newMaintenanceError(maintenanceFailureReparsePoint)
		}
		current = strings.TrimSuffix(current, `\`) + `\` + part
		p, err := windows.UTF16PtrFromString(current)
		if err != nil {
			return newMaintenanceError(maintenanceFailureReparsePoint)
		}
		h, err := windows.CreateFile(
			p,
			windows.FILE_LIST_DIRECTORY|windows.FILE_READ_ATTRIBUTES,
			windows.FILE_SHARE_READ,
			nil,
			windows.OPEN_EXISTING,
			windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS,
			0,
		)
		if err != nil {
			if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, windows.ERROR_PATH_NOT_FOUND) {
				return newMaintenanceError(maintenanceFailureReceiptMissing)
			}
			return newMaintenanceError(maintenanceFailureReparsePoint)
		}
		f := os.NewFile(uintptr(h), current)
		pinned.handles = append(pinned.handles, f)
		var info windows.ByHandleFileInformation
		if windows.GetFileInformationByHandle(h, &info) != nil ||
			info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DEVICE) != 0 ||
			info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
			return newMaintenanceError(maintenanceFailureReparsePoint)
		}
	}
	pinned.volumeDir = current
	return fn(pinned)
}

func resolveMaintenanceVolumeRoot(volume string) (string, error) {
	name := strings.TrimPrefix(volume, `\\?\`)
	if len(name) == len("Volume{00000000-0000-0000-0000-000000000000}") && strings.EqualFold(name[:6], "Volume") {
		if _, err := windows.GUIDFromString(name[6:]); err != nil || name == volume {
			return "", newMaintenanceError(maintenanceFailureReparsePoint)
		}
		return volume, nil
	}
	if len(name) != 2 || name[1] != ':' {
		return "", newMaintenanceError(maintenanceFailureReparsePoint)
	}
	root, err := windows.UTF16PtrFromString(name + `\`)
	if err != nil {
		return "", newMaintenanceError(maintenanceFailureReparsePoint)
	}
	var guid [64]uint16
	if err := windows.GetVolumeNameForVolumeMountPoint(root, &guid[0], uint32(len(guid))); err != nil {
		return "", newMaintenanceError(maintenanceFailureReparsePoint)
	}
	return windows.UTF16ToString(guid[:]), nil
}

func verifyAuthenticodeOnHandle(file *os.File, expectedPublisher []byte) error {
	p, err := windows.UTF16PtrFromString(file.Name())
	if err != nil {
		return newMaintenanceError(maintenanceFailureAuthenticodeFailed)
	}
	info := windows.WinTrustFileInfo{
		Size:     uint32(unsafe.Sizeof(windows.WinTrustFileInfo{})),
		FilePath: p,
		File:     windows.Handle(file.Fd()),
	}
	data := windows.WinTrustData{
		Size:                            uint32(unsafe.Sizeof(windows.WinTrustData{})),
		UIChoice:                        windows.WTD_UI_NONE,
		RevocationChecks:                windows.WTD_REVOKE_NONE,
		UnionChoice:                     windows.WTD_CHOICE_FILE,
		FileOrCatalogOrBlobOrSgnrOrCert: unsafe.Pointer(&info),
		StateAction:                     windows.WTD_STATEACTION_VERIFY,
		ProvFlags:                       windows.WTD_CACHE_ONLY_URL_RETRIEVAL,
	}
	verifyErr := windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	publisherOK := false
	if verifyErr == nil && data.StateData != 0 {
		publisherOK = verifyWinTrustStatePublisher(data.StateData, expectedPublisher)
	}
	data.StateAction = windows.WTD_STATEACTION_CLOSE
	closeErr := windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	if verifyErr != nil || closeErr != nil || !publisherOK {
		return newMaintenanceError(maintenanceFailureAuthenticodeFailed)
	}
	return nil
}

func verifyWinTrustStatePublisher(stateData windows.Handle, expectedPublisher []byte) bool {
	provData, _, _ := procWTHelperProvDataFromStateData.Call(uintptr(stateData))
	if provData == 0 {
		return false
	}
	signer, _, _ := procWTHelperGetProvSignerFromChain.Call(provData, 0, 0, 0)
	if signer == 0 {
		return false
	}
	certPtr, _, _ := procWTHelperGetProvCertFromChain.Call(signer, 0)
	if certPtr == 0 {
		return false
	}
	provCert := ptrFromWin32Addr[windowsCryptProviderCert](certPtr)
	if provCert == nil || provCert.pCert == nil || provCert.pCert.EncodedCert == nil || provCert.pCert.Length == 0 {
		return false
	}
	der := unsafe.Slice(provCert.pCert.EncodedCert, provCert.pCert.Length)
	sum := sha256.Sum256(der)
	return subtle.ConstantTimeCompare(sum[:], expectedPublisher) == 1
}

func windowsVerifyCMSReceipt(raw []byte, expectedPublisher []byte) ([]byte, error) {
	if len(raw) == 0 || len(raw) > maintenanceReceiptMaxBytes || len(expectedPublisher) != sha256.Size {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	const encoding = windows.X509_ASN_ENCODING | windows.PKCS_7_ASN_ENCODING
	hMsg, _, _ := procCryptMsgOpenToDecode.Call(uintptr(encoding), 0, 0, 0, 0, 0)
	if hMsg == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	defer procCryptMsgClose.Call(hMsg)

	updated, _, _ := procCryptMsgUpdate.Call(hMsg, uintptr(unsafe.Pointer(&raw[0])), uintptr(len(raw)), 1)
	if updated == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}

	var msgType uint32
	msgTypeSize := uint32(unsafe.Sizeof(msgType))
	ok, _, _ := procCryptMsgGetParam.Call(hMsg, cmsgTypeParam, 0, uintptr(unsafe.Pointer(&msgType)), uintptr(unsafe.Pointer(&msgTypeSize)))
	if ok == 0 || msgType != cmsgSigned {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}

	var signerCount uint32
	signerCountSize := uint32(unsafe.Sizeof(signerCount))
	ok, _, _ = procCryptMsgGetParam.Call(hMsg, cmsgSignerCountParam, 0, uintptr(unsafe.Pointer(&signerCount)), uintptr(unsafe.Pointer(&signerCountSize)))
	if ok == 0 || signerCount != 1 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}

	content, err := cryptMsgGetBytesParam(hMsg, cmsgContentParam, 0, maintenanceReceiptMaxBytes)
	if err != nil || len(content) == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}

	// Keep the signer-info buffer pinned from before CryptMsgGetParam writes
	// internal pointers into it through CertGetSubjectCertificateFromStore.
	var signerInfoSize uint32
	ok, _, _ = procCryptMsgGetParam.Call(hMsg, cmsgSignerCertInfoParam, 0, 0, uintptr(unsafe.Pointer(&signerInfoSize)))
	if ok == 0 || signerInfoSize == 0 || int(signerInfoSize) > 64*1024 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	signerInfoBytes := make([]byte, signerInfoSize)
	var signerInfoPinner runtime.Pinner
	signerInfoPinner.Pin(&signerInfoBytes[0])
	defer signerInfoPinner.Unpin()
	ok, _, _ = procCryptMsgGetParam.Call(hMsg, cmsgSignerCertInfoParam, 0, uintptr(unsafe.Pointer(&signerInfoBytes[0])), uintptr(unsafe.Pointer(&signerInfoSize)))
	if ok == 0 || signerInfoSize == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}

	store, err := windows.CertOpenStore(windows.CERT_STORE_PROV_MSG, encoding, 0, 0, hMsg)
	if err != nil || store == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	defer windows.CertCloseStore(store, 0)

	certPtr, _, _ := procCertGetSubjectCertificateFromStr.Call(
		uintptr(store),
		uintptr(encoding),
		uintptr(unsafe.Pointer(&signerInfoBytes[0])),
	)
	runtime.KeepAlive(signerInfoBytes)
	if certPtr == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	signerCert := ptrFromWin32Addr[windows.CertContext](certPtr)
	if signerCert == nil {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	defer windows.CertFreeCertificateContext(signerCert)

	if signerCert.CertInfo == nil || signerCert.EncodedCert == nil || signerCert.Length == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	verified, _, _ := procCryptMsgControl.Call(hMsg, 0, cmsgCtrlVerifySignature, uintptr(unsafe.Pointer(signerCert.CertInfo)))
	if verified == 0 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}

	der := unsafe.Slice(signerCert.EncodedCert, signerCert.Length)
	sum := sha256.Sum256(der)
	if subtle.ConstantTimeCompare(sum[:], expectedPublisher) != 1 {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}

	if err := verifyCodeSigningChain(signerCert, store); err != nil {
		return nil, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	return content, nil
}

func cryptMsgGetBytesParam(hMsg uintptr, paramType uint32, index uint32, maxSize int) ([]byte, error) {
	var size uint32
	ok, _, _ := procCryptMsgGetParam.Call(hMsg, uintptr(paramType), uintptr(index), 0, uintptr(unsafe.Pointer(&size)))
	if ok == 0 || size == 0 || int(size) > maxSize {
		return nil, errors.New("invalid cms parameter size")
	}
	buf := make([]byte, size)
	ok, _, _ = procCryptMsgGetParam.Call(hMsg, uintptr(paramType), uintptr(index), uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)))
	if ok == 0 {
		return nil, errors.New("failed to read cms parameter")
	}
	return buf[:size], nil
}

func verifyCodeSigningChain(cert *windows.CertContext, additionalStore windows.Handle) error {
	eku := append([]byte(oidCodeSigning), 0)
	ekuPtr := &eku[0]
	para := windows.CertChainPara{
		Size: uint32(unsafe.Sizeof(windows.CertChainPara{})),
		RequestedUsage: windows.CertUsageMatch{
			Type: windows.USAGE_MATCH_TYPE_AND,
			Usage: windows.CertEnhKeyUsage{
				Length:           1,
				UsageIdentifiers: &ekuPtr,
			},
		},
	}
	var chain *windows.CertChainContext
	if err := windows.CertGetCertificateChain(0, cert, nil, additionalStore, &para, certChainCacheOnlyURLRetrieval, 0, &chain); err != nil || chain == nil {
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	defer windows.CertFreeCertificateChain(chain)
	if chain.TrustStatus.ErrorStatus != 0 {
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	policyPara := windows.CertChainPolicyPara{Size: uint32(unsafe.Sizeof(windows.CertChainPolicyPara{}))}
	var policyStatus windows.CertChainPolicyStatus
	policyStatus.Size = uint32(unsafe.Sizeof(policyStatus))
	if err := windows.CertVerifyCertificateChainPolicy(windows.CERT_CHAIN_POLICY_AUTHENTICODE, chain, &policyPara, &policyStatus); err != nil || policyStatus.Error != 0 {
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	return nil
}

func windowsRunMaintenanceBroker(ctx context.Context, broker pinnedBrokerImage, args []string) ([]byte, []byte, int, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	systemDir, err := windows.GetSystemDirectory()
	if err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	return runBoundTrayProcess(ctx, broker, args, systemDir, 256*1024, 64*1024)
}

func trayFinalNativePathByHandle(handle windows.Handle) (string, error) {
	buf := make([]uint16, 4096)
	for {
		n, err := windows.GetFinalPathNameByHandle(handle, &buf[0], uint32(len(buf)), maintenanceVolumeNameNT)
		if err != nil || n == 0 {
			return "", newMaintenanceError(maintenanceFailureIdentityMismatch)
		}
		if int(n) < len(buf) {
			return windows.UTF16ToString(buf[:n]), nil
		}
		if n > 32768 {
			return "", newMaintenanceError(maintenanceFailureIdentityMismatch)
		}
		buf = make([]uint16, n+1)
	}
}

func queryTrayProcessImagePath(proc windows.Handle, flags uint32) (string, error) {
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

func verifyTrayPathMatchesIdentity(path string, broker pinnedBrokerImage) error {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
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
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	defer windows.CloseHandle(h)
	var info windows.ByHandleFileInformation
	if windows.GetFileInformationByHandle(h, &info) != nil ||
		info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DEVICE|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	if info.VolumeSerialNumber != broker.VolumeSerial ||
		info.FileIndexHigh != broker.FileIndexHigh ||
		info.FileIndexLow != broker.FileIndexLow {
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	return nil
}

func verifyTrayProcessMatchesIdentity(proc windows.Handle, broker pinnedBrokerImage) error {
	nativePath, err := queryTrayProcessImagePath(proc, windows.PROCESS_NAME_NATIVE)
	if err != nil || broker.NativeImagePath == "" || !strings.EqualFold(nativePath, broker.NativeImagePath) {
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	if err := verifyTrayPathMatchesIdentity(broker.Path, broker); err != nil {
		return err
	}
	if win32Path, err := queryTrayProcessImagePath(proc, 0); err == nil && win32Path != "" {
		if err := verifyTrayPathMatchesIdentity(win32Path, broker); err != nil {
			return err
		}
	}
	return nil
}

func waitForTrayJobZeroProcesses(iocp windows.Handle, expectedKey uintptr) {
	for {
		var msg uint32
		var key uintptr
		var overlapped *windows.Overlapped
		if err := windows.GetQueuedCompletionStatus(iocp, &msg, &key, &overlapped, windows.INFINITE); err != nil {
			return
		}
		if key == expectedKey && msg == trayJobMsgActiveProcessZero {
			return
		}
	}
}

func buildWindowsCommandLine(appPath string, args []string) string {
	parts := make([]string, 0, len(args)+1)
	parts = append(parts, windows.EscapeArg(appPath))
	for _, arg := range args {
		parts = append(parts, windows.EscapeArg(arg))
	}
	return strings.Join(parts, " ")
}

func runBoundTrayProcess(ctx context.Context, broker pinnedBrokerImage, args []string, workDir string, stdoutLimit, stderrLimit int) ([]byte, []byte, int, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	defer windows.CloseHandle(job)

	var limits windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&limits)),
		uint32(unsafe.Sizeof(limits)),
	); err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}

	iocp, err := windows.CreateIoCompletionPort(windows.InvalidHandle, 0, 0, 1)
	if err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	defer windows.CloseHandle(iocp)

	const completionKey uintptr = 1
	assoc := trayJobAssociateCompletionPort{
		CompletionKey:  completionKey,
		CompletionPort: iocp,
	}
	if _, err := windows.SetInformationJobObject(
		job,
		windows.JobObjectAssociateCompletionPortInformation,
		uintptr(unsafe.Pointer(&assoc)),
		uint32(unsafe.Sizeof(assoc)),
	); err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}

	inheritSA := windows.SecurityAttributes{
		Length:        uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		InheritHandle: 1,
	}
	var stdoutRead, stdoutWrite, stderrRead, stderrWrite windows.Handle
	if err := windows.CreatePipe(&stdoutRead, &stdoutWrite, &inheritSA, 0); err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	if err := windows.SetHandleInformation(stdoutRead, windows.HANDLE_FLAG_INHERIT, 0); err != nil {
		_ = windows.CloseHandle(stdoutRead)
		_ = windows.CloseHandle(stdoutWrite)
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	if err := windows.CreatePipe(&stderrRead, &stderrWrite, &inheritSA, 0); err != nil {
		_ = windows.CloseHandle(stdoutRead)
		_ = windows.CloseHandle(stdoutWrite)
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	if err := windows.SetHandleInformation(stderrRead, windows.HANDLE_FLAG_INHERIT, 0); err != nil {
		_ = windows.CloseHandle(stdoutRead)
		_ = windows.CloseHandle(stdoutWrite)
		_ = windows.CloseHandle(stderrRead)
		_ = windows.CloseHandle(stderrWrite)
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	nulName, _ := windows.UTF16PtrFromString("NUL")
	nulStdin, err := windows.CreateFile(
		nulName,
		windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		&inheritSA,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		_ = windows.CloseHandle(stdoutRead)
		_ = windows.CloseHandle(stdoutWrite)
		_ = windows.CloseHandle(stderrRead)
		_ = windows.CloseHandle(stderrWrite)
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}

	closeChildEnds := func() {
		if nulStdin != 0 {
			_ = windows.CloseHandle(nulStdin)
			nulStdin = 0
		}
		if stdoutWrite != 0 {
			_ = windows.CloseHandle(stdoutWrite)
			stdoutWrite = 0
		}
		if stderrWrite != 0 {
			_ = windows.CloseHandle(stderrWrite)
			stderrWrite = 0
		}
	}
	defer closeChildEnds()

	stdoutFile := os.NewFile(uintptr(stdoutRead), "broker-stdout")
	stderrFile := os.NewFile(uintptr(stderrRead), "broker-stderr")
	defer stdoutFile.Close()
	defer stderrFile.Close()

	attrList, err := windows.NewProcThreadAttributeList(1)
	if err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	defer attrList.Delete()

	inheritedHandles := [3]windows.Handle{nulStdin, stdoutWrite, stderrWrite}
	if err := attrList.Update(
		windows.PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
		unsafe.Pointer(&inheritedHandles[0]),
		uintptr(len(inheritedHandles))*unsafe.Sizeof(inheritedHandles[0]),
	); err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}

	appName, err := windows.UTF16PtrFromString(broker.Path)
	if err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	cmdLine, err := windows.UTF16FromString(buildWindowsCommandLine(broker.Path, args))
	if err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	cwd, err := windows.UTF16PtrFromString(workDir)
	if err != nil {
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}

	var si windows.StartupInfoEx
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Flags = windows.STARTF_USESTDHANDLES
	si.StdInput = nulStdin
	si.StdOutput = stdoutWrite
	si.StdErr = stderrWrite
	si.ProcThreadAttributeList = attrList.List()

	var pi windows.ProcessInformation
	createErr := windows.CreateProcess(
		appName,
		&cmdLine[0],
		nil,
		nil,
		true,
		windows.EXTENDED_STARTUPINFO_PRESENT|windows.CREATE_SUSPENDED|windows.CREATE_NO_WINDOW,
		nil,
		cwd,
		&si.StartupInfo,
		&pi,
	)
	runtime.KeepAlive(inheritedHandles)
	closeChildEnds()
	if createErr != nil {
		if errors.Is(createErr, windows.ERROR_CANCELLED) {
			return nil, nil, errorCancelledExitCode, createErr
		}
		return nil, nil, -1, createErr
	}
	defer windows.CloseHandle(pi.Thread)
	defer windows.CloseHandle(pi.Process)

	if err := verifyTrayProcessMatchesIdentity(pi.Process, broker); err != nil {
		_ = windows.TerminateProcess(pi.Process, 1)
		_, _ = windows.WaitForSingleObject(pi.Process, 5000)
		return nil, nil, -1, err
	}
	if err := windows.AssignProcessToJobObject(job, pi.Process); err != nil {
		_ = windows.TerminateProcess(pi.Process, 1)
		_, _ = windows.WaitForSingleObject(pi.Process, 5000)
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}
	if _, err := windows.ResumeThread(pi.Thread); err != nil {
		_ = windows.TerminateJobObject(job, 1)
		waitForTrayJobZeroProcesses(iocp, completionKey)
		return nil, nil, -1, newMaintenanceError(maintenanceFailureLaunchFailed)
	}

	outBuf := &boundedTrayOutput{remaining: stdoutLimit}
	errBuf := &boundedTrayOutput{remaining: stderrLimit}
	var readWG sync.WaitGroup
	readWG.Add(2)
	go func() {
		defer readWG.Done()
		_, _ = io.Copy(outBuf, stdoutFile)
	}()
	go func() {
		defer readWG.Done()
		_, _ = io.Copy(errBuf, stderrFile)
	}()

	jobDone := make(chan struct{})
	go func() {
		waitForTrayJobZeroProcesses(iocp, completionKey)
		close(jobDone)
	}()

	procDone := make(chan struct{})
	var exitCode uint32
	var procErr error
	go func() {
		res, waitErr := windows.WaitForSingleObject(pi.Process, windows.INFINITE)
		if waitErr != nil || res != windows.WAIT_OBJECT_0 {
			procErr = errors.New("broker process wait failed")
		} else if codeErr := windows.GetExitCodeProcess(pi.Process, &exitCode); codeErr != nil {
			procErr = codeErr
		}
		close(procDone)
	}()

	var ctxErr error
	select {
	case <-procDone:
		select {
		case <-jobDone:
		case <-ctx.Done():
			ctxErr = ctx.Err()
			_ = windows.TerminateJobObject(job, 1)
			<-jobDone
		}
	case <-ctx.Done():
		ctxErr = ctx.Err()
		_ = windows.TerminateJobObject(job, 1)
		<-procDone
		<-jobDone
	}

	readWG.Wait()
	if ctxErr != nil {
		return outBuf.Bytes(), errBuf.Bytes(), -1, ctxErr
	}
	if procErr != nil {
		return outBuf.Bytes(), errBuf.Bytes(), -1, procErr
	}
	if exitCode != 0 {
		return outBuf.Bytes(), errBuf.Bytes(), int(exitCode), errors.New("broker exited non-zero")
	}
	return outBuf.Bytes(), errBuf.Bytes(), 0, nil
}
