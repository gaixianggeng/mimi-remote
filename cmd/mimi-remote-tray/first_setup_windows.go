//go:build windows

package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	innoUninstallRegistryKey = `Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D413E71-19C5-4F02-8AFC-437E1B8019FD}_is1`
	cmsgSignerInfoParam      = 6
)

var (
	firstSetupCrypt32    = syscall.NewLazyDLL("crypt32.dll")
	procCryptMsgGetParam = firstSetupCrypt32.NewProc("CryptMsgGetParam")
	procCryptMsgClose    = firstSetupCrypt32.NewProc("CryptMsgClose")
)

type cmsgSignerInfoHeader struct {
	Version      uint32
	Issuer       windows.CertNameBlob
	SerialNumber windows.CryptIntegerBlob
}

type innoModifyTarget struct {
	Executable string
	Args       []string
}

// firstSetupModifyError distinguishes missing/unverified installer maintenance
// entries so the UI can safely direct the user to the official DESKTOP release
// page instead of executing an untrusted binary.
type firstSetupModifyError struct {
	Message        string
	RecoverViaLink bool
}

func (e *firstSetupModifyError) Error() string {
	return e.Message
}

func isFirstSetupRecoverableViaDesktop(err error) bool {
	var target *firstSetupModifyError
	return errors.As(err, &target) && target.RecoverViaLink
}

func readInnoModifyPathFromRegistry() (string, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, innoUninstallRegistryKey, registry.QUERY_VALUE)
	if err != nil {
		return "", err
	}
	defer key.Close()
	value, _, err := key.GetStringValue("ModifyPath")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(value), nil
}

// parseAndValidateInnoModifyTarget parses ModifyPath strictly into an .exe path
// inside installDir plus fixed allow-listed Inno Modify arguments. Arbitrary
// arguments, scripts, symlinks/reparse points, and executables outside the
// installation directory are rejected.
func parseAndValidateInnoModifyTarget(rawModifyPath string, installDir string) (innoModifyTarget, error) {
	raw := strings.TrimSpace(rawModifyPath)
	if raw == "" {
		return innoModifyTarget{}, &firstSetupModifyError{
			Message:        "未找到 Mimi Remote 安装维护入口。请重新下载并运行官方安装包以完成首次设置。",
			RecoverViaLink: true,
		}
	}
	if strings.ContainsAny(raw, "\r\n|&;<>`") {
		return innoModifyTarget{}, &firstSetupModifyError{
			Message:        "安装维护入口配置异常，已拒绝执行。请重新下载官方安装包。",
			RecoverViaLink: true,
		}
	}

	exeRaw, rest, ok := splitModifyCommandLine(raw)
	if !ok || strings.TrimSpace(exeRaw) == "" {
		return innoModifyTarget{}, &firstSetupModifyError{
			Message:        "安装维护入口格式无效，已拒绝执行。请重新下载官方安装包。",
			RecoverViaLink: true,
		}
	}

	args, err := validateInnoModifyArgs(rest)
	if err != nil {
		return innoModifyTarget{}, err
	}

	cleanedExe := filepath.Clean(exeRaw)
	if !filepath.IsAbs(cleanedExe) || !strings.EqualFold(filepath.Ext(cleanedExe), ".exe") {
		return innoModifyTarget{}, &firstSetupModifyError{
			Message:        "安装维护程序必须是受信任目录中的可执行文件。请重新下载官方安装包。",
			RecoverViaLink: true,
		}
	}

	cleanedInstallDir := filepath.Clean(strings.TrimSpace(installDir))
	if cleanedInstallDir == "" || !filepath.IsAbs(cleanedInstallDir) || !isPathWithinDirCaseInsensitive(cleanedExe, cleanedInstallDir) {
		return innoModifyTarget{}, &firstSetupModifyError{
			Message:        "安装维护程序不在当前安装目录内，已拒绝执行。请重新下载官方安装包。",
			RecoverViaLink: true,
		}
	}

	info, err := os.Lstat(cleanedExe)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return innoModifyTarget{}, &firstSetupModifyError{
			Message:        "安装维护程序缺失或不可信。请重新下载官方安装包以完成首次设置。",
			RecoverViaLink: true,
		}
	}
	if isWindowsReparsePoint(cleanedExe) {
		return innoModifyTarget{}, &firstSetupModifyError{
			Message:        "安装维护程序路径包含不受支持的链接，已拒绝执行。请重新下载官方安装包。",
			RecoverViaLink: true,
		}
	}

	return innoModifyTarget{Executable: cleanedExe, Args: args}, nil
}

func splitModifyCommandLine(raw string) (string, string, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", "", false
	}
	if strings.HasPrefix(trimmed, `"`) {
		end := strings.IndexByte(trimmed[1:], '"')
		if end <= 0 {
			return "", "", false
		}
		exe := trimmed[1 : end+1]
		rest := strings.TrimSpace(trimmed[end+2:])
		return exe, rest, true
	}
	if idx := strings.IndexAny(trimmed, " \t"); idx > 0 {
		return trimmed[:idx], strings.TrimSpace(trimmed[idx+1:]), true
	}
	return trimmed, "", true
}

func validateInnoModifyArgs(rawArgs string) ([]string, error) {
	trimmed := strings.TrimSpace(rawArgs)
	if trimmed == "" {
		return []string{"/MODIFY"}, nil
	}
	tokens := strings.Fields(trimmed)
	args := make([]string, 0, len(tokens))
	for _, token := range tokens {
		switch strings.ToUpper(token) {
		case "/MODIFY":
			args = append(args, "/MODIFY")
		case "/FIRSTSETUP":
			args = append(args, "/FIRSTSETUP")
		default:
			return nil, &firstSetupModifyError{
				Message:        "安装维护参数不受支持，已拒绝执行。请重新下载官方安装包。",
				RecoverViaLink: true,
			}
		}
	}
	if len(args) == 0 {
		return []string{"/MODIFY"}, nil
	}
	return args, nil
}

func isPathWithinDirCaseInsensitive(candidate, dir string) bool {
	rel, err := filepath.Rel(strings.ToLower(filepath.Clean(dir)), strings.ToLower(filepath.Clean(candidate)))
	if err != nil {
		return false
	}
	if rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return false
	}
	return !filepath.IsAbs(rel)
}

func isWindowsReparsePoint(path string) bool {
	encoded, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return true
	}
	attrs, err := windows.GetFileAttributes(encoded)
	if err != nil {
		return true
	}
	return attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0
}

// verifyExecutablePublisherMatches enforces Authenticode trust on both the
// running tray binary and the Inno Modify executable and confirms identical
// publisher certificates. Unsigned previews fail closed.
func verifyExecutablePublisherMatches(candidatePath, currentExecutable string) error {
	if err := verifyAuthenticodeFile(currentExecutable); err != nil {
		return &firstSetupModifyError{
			Message:        "当前客户端未通过发布者签名校验，已阻止自动启动安装维护。请从官方发布页重新安装正式版。",
			RecoverViaLink: true,
		}
	}
	if err := verifyAuthenticodeFile(candidatePath); err != nil {
		return &firstSetupModifyError{
			Message:        "安装维护程序签名校验未通过，已拒绝运行。请从官方发布页重新下载正式版。",
			RecoverViaLink: true,
		}
	}
	currentCert, err := extractSignerCertificateBytes(currentExecutable)
	if err != nil {
		return &firstSetupModifyError{
			Message:        "无法读取当前客户端发布者证书，已阻止启动安装维护。请从官方发布页手动核实。",
			RecoverViaLink: true,
		}
	}
	candidateCert, err := extractSignerCertificateBytes(candidatePath)
	if err != nil {
		return &firstSetupModifyError{
			Message:        "无法读取安装维护程序发布者证书，已拒绝运行。请从官方发布页重新下载正式版。",
			RecoverViaLink: true,
		}
	}
	currentHash := sha256.Sum256(currentCert)
	candidateHash := sha256.Sum256(candidateCert)
	if subtle.ConstantTimeCompare(currentHash[:], candidateHash[:]) != 1 {
		return &firstSetupModifyError{
			Message:        "安装维护程序发布者证书与当前客户端不一致，已拒绝运行。请从官方发布页手动核实。",
			RecoverViaLink: true,
		}
	}
	return nil
}

func verifyAuthenticodeFile(path string) error {
	encoded, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	fileInfo := &windows.WinTrustFileInfo{
		Size:     uint32(unsafe.Sizeof(windows.WinTrustFileInfo{})),
		FilePath: encoded,
	}
	data := &windows.WinTrustData{
		Size:                            uint32(unsafe.Sizeof(windows.WinTrustData{})),
		UIChoice:                        windows.WTD_UI_NONE,
		RevocationChecks:                windows.WTD_REVOKE_WHOLECHAIN,
		UnionChoice:                     windows.WTD_CHOICE_FILE,
		FileOrCatalogOrBlobOrSgnrOrCert: unsafe.Pointer(fileInfo),
		StateAction:                     windows.WTD_STATEACTION_VERIFY,
		ProvFlags:                       windows.WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT,
	}
	action := windows.WINTRUST_ACTION_GENERIC_VERIFY_V2
	verifyErr := windows.WinVerifyTrustEx(windows.InvalidHWND, &action, data)
	data.StateAction = windows.WTD_STATEACTION_CLOSE
	_ = windows.WinVerifyTrustEx(windows.InvalidHWND, &action, data)
	return verifyErr
}

func extractSignerCertificateBytes(path string) ([]byte, error) {
	encoded, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	var encoding, contentType, formatType uint32
	var store, msg windows.Handle
	err = windows.CryptQueryObject(
		windows.CERT_QUERY_OBJECT_FILE,
		unsafe.Pointer(encoded),
		windows.CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
		windows.CERT_QUERY_FORMAT_FLAG_BINARY,
		0,
		&encoding,
		&contentType,
		&formatType,
		&store,
		&msg,
		nil,
	)
	if err != nil {
		return nil, err
	}
	defer func() {
		if store != 0 {
			_ = windows.CertCloseStore(store, 0)
		}
		if msg != 0 {
			procCryptMsgClose.Call(uintptr(msg))
		}
	}()

	var size uint32
	r1, _, callErr := procCryptMsgGetParam.Call(
		uintptr(msg),
		cmsgSignerInfoParam,
		0,
		0,
		uintptr(unsafe.Pointer(&size)),
	)
	if r1 == 0 || size < uint32(unsafe.Sizeof(cmsgSignerInfoHeader{})) {
		return nil, fmt.Errorf("read signer info size failed: %v", callErr)
	}
	buf := make([]byte, size)
	r1, _, callErr = procCryptMsgGetParam.Call(
		uintptr(msg),
		cmsgSignerInfoParam,
		0,
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(unsafe.Pointer(&size)),
	)
	if r1 == 0 {
		return nil, fmt.Errorf("read signer info failed: %v", callErr)
	}

	header := (*cmsgSignerInfoHeader)(unsafe.Pointer(&buf[0]))
	certQuery := windows.CertInfo{
		Issuer:       header.Issuer,
		SerialNumber: header.SerialNumber,
	}
	cert, err := windows.CertFindCertificateInStore(
		store,
		encoding,
		0,
		windows.CERT_FIND_SUBJECT_CERT,
		unsafe.Pointer(&certQuery),
		nil,
	)
	if err != nil || cert == nil || cert.EncodedCert == nil || cert.Length == 0 {
		return nil, errors.New("signer certificate not found")
	}
	defer windows.CertFreeCertificateContext(cert)
	raw := unsafe.Slice(cert.EncodedCert, cert.Length)
	copied := make([]byte, len(raw))
	copy(copied, raw)
	return copied, nil
}

func (c *agentController) launchFirstSetup(ctx context.Context) error {
	currentExe := strings.TrimSpace(c.trayPath)
	if currentExe == "" {
		exe, err := os.Executable()
		if err != nil {
			return &firstSetupModifyError{
				Message:        "无法定位当前托盘程序路径，请重新下载官方安装包。",
				RecoverViaLink: true,
			}
		}
		currentExe = exe
	}
	installDir := filepath.Dir(currentExe)

	resolver := c.modifyResolver
	if resolver == nil {
		resolver = func() (innoModifyTarget, error) {
			rawPath, err := readInnoModifyPathFromRegistry()
			if err != nil {
				return innoModifyTarget{}, &firstSetupModifyError{
					Message:        "未找到 Mimi Remote 安装维护入口。请重新下载并运行官方安装包以完成首次设置。",
					RecoverViaLink: true,
				}
			}
			return parseAndValidateInnoModifyTarget(rawPath, installDir)
		}
	}
	target, err := resolver()
	if err != nil {
		return err
	}

	verifier := c.modifyVerifier
	if verifier == nil {
		verifier = verifyExecutablePublisherMatches
	}
	if err := verifier(target.Executable, currentExe); err != nil {
		return err
	}

	runner := c.modifyRunner
	if runner == nil {
		runner = func(runCtx context.Context, exe string, args []string) error {
			if runCtx == nil {
				runCtx = context.Background()
			}
			cmd := exec.CommandContext(runCtx, exe, args...)
			cmd.Dir = filepath.Dir(exe)
			if err := cmd.Run(); err != nil {
				return errors.New("首次设置未完成或已取消，可点击“完成首次设置…”重试。")
			}
			return nil
		}
	}
	return runner(ctx, target.Executable, target.Args)
}

func openApprovedOnboardingURLWindows(rawURL string) error {
	if !isAllowedOnboardingURL(rawURL) {
		return errors.New("链接不在允许列表中")
	}
	if err := exec.Command("rundll32", "url.dll,FileProtocolHandler", rawURL).Start(); err != nil {
		return errors.New("无法打开浏览器，请访问：" + rawURL)
	}
	return nil
}
