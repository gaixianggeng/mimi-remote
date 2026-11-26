package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"time"
)

const (
	maintenanceReceiptName         = "maintenance-identity.p7m"
	maintenanceReceiptMaxBytes     = 131072
	maintenanceReceiptSchema       = "mimi.windows.maintenance/v1"
	maintenanceBrokerRole          = "agentd.exe"
	maintenanceImageRole           = "Mimi-Remote-Maintenance.exe"
	maintenanceOfficialDownloadURL = onboardingURLDesktop
	maintenanceStatusReadTimeout   = 45 * time.Second
)

var (
	maintenanceModifyArgs = []string{"installer-maintenance", "modify"}
	maintenanceStatusArgs = []string{"status", "--json", "--runtime", "--network-policy"}
)

type maintenancePurpose string

const (
	maintenancePurposeConfirmWorkspace maintenancePurpose = "confirm_workspace"
	maintenancePurposeLANFirewall      maintenancePurpose = "lan_firewall"
)

type maintenanceFailureKind string

const (
	maintenanceFailureNone                   maintenanceFailureKind = ""
	maintenanceFailureUnsignedBuild          maintenanceFailureKind = "unsigned_build"
	maintenanceFailureElevatedSession        maintenanceFailureKind = "elevated_session"
	maintenanceFailureReceiptMissing         maintenanceFailureKind = "receipt_missing"
	maintenanceFailureIdentityMismatch       maintenanceFailureKind = "identity_mismatch"
	maintenanceFailureReparsePoint           maintenanceFailureKind = "reparse_point"
	maintenanceFailureImageMissing           maintenanceFailureKind = "maintenance_image_missing"
	maintenanceFailureDigestMismatch         maintenanceFailureKind = "digest_mismatch"
	maintenanceFailureAuthenticodeFailed     maintenanceFailureKind = "authenticode_failed"
	maintenanceFailureOldHostUnsupported     maintenanceFailureKind = "old_host_unsupported"
	maintenanceFailureUACCancelled           maintenanceFailureKind = "uac_cancelled"
	maintenanceFailureLaunchFailed           maintenanceFailureKind = "launch_failed"
	maintenanceFailureStatusStillUnconfirmed maintenanceFailureKind = "status_still_unconfirmed"
	maintenanceFailureLANStillDisabled       maintenanceFailureKind = "lan_still_disabled"
	maintenanceFailureStatusReadFailed       maintenanceFailureKind = "status_read_failed"
)

type maintenanceError struct {
	Kind               maintenanceFailureKind
	FallbackToDownload bool
	DownloadURL        string
	Message            string
}

func (e *maintenanceError) Error() string {
	if e == nil {
		return ""
	}
	return e.Message
}

func newMaintenanceError(kind maintenanceFailureKind) *maintenanceError {
	download := func(prefix string) *maintenanceError {
		return &maintenanceError{
			Kind:               kind,
			FallbackToDownload: true,
			DownloadURL:        maintenanceOfficialDownloadURL,
			Message:            prefix + "请前往桌面端正式下载页获取已签名的安装包：" + maintenanceOfficialDownloadURL,
		}
	}
	switch kind {
	case maintenanceFailureUnsignedBuild:
		return download("当前为未签名或开发构建，无法调用受信维护入口。")
	case maintenanceFailureElevatedSession:
		return &maintenanceError{
			Kind:    kind,
			Message: "请以当前普通桌面用户身份运行托盘后再启动维护向导，不要以管理员身份启动。",
		}
	case maintenanceFailureReceiptMissing:
		return download("安装目录缺少已签名的维护身份凭据（maintenance-identity.p7m），无法安全启动维护向导。")
	case maintenanceFailureIdentityMismatch:
		return download("无法验证此版本的维护身份凭据（发布者、证书链、版本或角色不匹配），已拒绝启动。")
	case maintenanceFailureReparsePoint:
		return download("检测到安装路径或程序文件存在不安全的符号链接或重解析点，已拒绝启动维护向导。")
	case maintenanceFailureImageMissing:
		return download("安装目录缺少维护程序（Mimi-Remote-Maintenance.exe）或核心代理（agentd.exe）。")
	case maintenanceFailureDigestMismatch:
		return download("核心代理或维护程序的文件摘要与签名凭据不一致，已拒绝启动。")
	case maintenanceFailureAuthenticodeFailed:
		return download("核心代理或维护程序未通过 Windows Authenticode 发布者签名校验，已拒绝启动。")
	case maintenanceFailureOldHostUnsupported:
		return download("当前已安装的桌面端版本较旧，不支持受信维护入口。")
	case maintenanceFailureUACCancelled:
		return download("管理员授权已取消，专用网络防火墙规则未修改（同一局域网保持关闭）。如需重新配置，可重试或")
	case maintenanceFailureLaunchFailed:
		return download("维护向导未能正常完成。")
	case maintenanceFailureStatusStillUnconfirmed:
		return &maintenanceError{
			Kind:    kind,
			Message: "维护向导已退出，但代码目录仍处于待确认状态。请再次点击“完成首次设置…”确认代码目录，或刷新状态检查。",
		}
	case maintenanceFailureLANStillDisabled:
		return &maintenanceError{
			Kind:    kind,
			Message: "维护向导已退出，但同一局域网仍未开启或专用网络防火墙策略未生效。请确认当前为专用网络后重试。",
		}
	case maintenanceFailureStatusReadFailed:
		return &maintenanceError{
			Kind:    kind,
			Message: "维护向导已退出，但暂时无法读取最新服务状态。请点击“刷新状态”确认结果。",
		}
	default:
		return download("无法安全调用维护入口。")
	}
}

type maintenanceIdentityReceipt struct {
	Schema            string `json:"schema"`
	Version           string `json:"version"`
	Broker            string `json:"broker"`
	BrokerSHA256      string `json:"broker_sha256"`
	Maintenance       string `json:"maintenance"`
	MaintenanceSHA256 string `json:"maintenance_sha256"`
}

type validatedMaintenanceReceipt struct {
	Version           string
	BrokerDigest      []byte
	MaintenanceDigest []byte
}

func parseTrustedReleaseIdentity(version, publisherHex string) (string, []byte, bool) {
	trimmedVersion := strings.TrimSpace(version)
	if trimmedVersion == "" ||
		strings.EqualFold(trimmedVersion, "dev") ||
		strings.HasPrefix(strings.ToLower(trimmedVersion), "devel") {
		return "", nil, false
	}
	trimmedPublisher := strings.TrimSpace(publisherHex)
	if len(trimmedPublisher) != sha256.Size*2 {
		return "", nil, false
	}
	publisherDigest, err := hex.DecodeString(trimmedPublisher)
	if err != nil || len(publisherDigest) != sha256.Size {
		return "", nil, false
	}
	return trimmedVersion, publisherDigest, true
}

func validateMaintenanceReceiptJSON(payload []byte, expectedVersion string) (validatedMaintenanceReceipt, error) {
	if len(payload) == 0 || len(payload) > maintenanceReceiptMaxBytes {
		return validatedMaintenanceReceipt{}, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	var receipt maintenanceIdentityReceipt
	decoder := json.NewDecoder(bytes.NewReader(payload))
	if err := decoder.Decode(&receipt); err != nil {
		return validatedMaintenanceReceipt{}, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return validatedMaintenanceReceipt{}, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	if receipt.Schema != maintenanceReceiptSchema ||
		receipt.Version != expectedVersion ||
		receipt.Broker != maintenanceBrokerRole ||
		receipt.Maintenance != maintenanceImageRole {
		return validatedMaintenanceReceipt{}, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	brokerDigest, err := decodeSHA256Hex(receipt.BrokerSHA256)
	if err != nil {
		return validatedMaintenanceReceipt{}, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	maintenanceDigest, err := decodeSHA256Hex(receipt.MaintenanceSHA256)
	if err != nil {
		return validatedMaintenanceReceipt{}, newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	return validatedMaintenanceReceipt{
		Version:           receipt.Version,
		BrokerDigest:      brokerDigest,
		MaintenanceDigest: maintenanceDigest,
	}, nil
}

func decodeSHA256Hex(value string) ([]byte, error) {
	if len(value) != sha256.Size*2 {
		return nil, errors.New("invalid sha256 length")
	}
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) != sha256.Size {
		return nil, errors.New("invalid sha256 hex")
	}
	return decoded, nil
}

type pinnedBrokerImage struct {
	Path            string
	NativeImagePath string
	VolumeSerial    uint32
	FileIndexHigh   uint32
	FileIndexLow    uint32
}

// pinnedMaintenanceDir represents an installed directory whose volume root and
// every ancestor directory have been opened without FILE_SHARE_DELETE and
// checked against reparse points until the launch callback returns.
type pinnedMaintenanceDir interface {
	ReadReceipt(name string, maxBytes int64) ([]byte, error)
	VerifyPinnedImage(name string, expectedDigest []byte, expectedPublisher []byte) (pinnedBrokerImage, error)
}

type maintenancePlatformOps struct {
	isElevated        func() (bool, error)
	withPinnedInstall func(installDir string, fn func(pinned pinnedMaintenanceDir) error) error
	verifyCMSReceipt  func(raw []byte, expectedPublisher []byte) ([]byte, error)
	runBroker         func(ctx context.Context, broker pinnedBrokerImage, args []string) (stdout []byte, stderr []byte, exitCode int, err error)
}

type maintenanceRunner struct {
	installDir      string
	expectedVersion string
	publisherSHA256 string
	ops             maintenancePlatformOps
}

type maintenanceRunOutcome struct {
	BrokerVerified     bool
	Status             agentStatus
	WorkspaceConfirmed bool
	LANEnabled         bool
	LANPolicyOK        bool
}

func isMaintenanceIdentityRejection(kind maintenanceFailureKind) bool {
	switch kind {
	case maintenanceFailureUnsignedBuild,
		maintenanceFailureElevatedSession,
		maintenanceFailureReceiptMissing,
		maintenanceFailureIdentityMismatch,
		maintenanceFailureReparsePoint,
		maintenanceFailureImageMissing,
		maintenanceFailureDigestMismatch,
		maintenanceFailureAuthenticodeFailed:
		return true
	default:
		return false
	}
}

func isTerminalMaintenanceImageRejection(kind maintenanceFailureKind) bool {
	return isMaintenanceIdentityRejection(kind) && kind != maintenanceFailureElevatedSession
}

// maintenanceRejectionLatch is the single authoritative rejection latch shared
// by the tray UI and agentController process-launch boundary. Once latched,
// rejection stays terminal across ordinary refreshes and queued commands until
// a fresh verified maintenance run succeeds or the app restarts.
type maintenanceRejectionLatch struct {
	mu       sync.RWMutex
	rejected bool
	kind     maintenanceFailureKind
}

func (l *maintenanceRejectionLatch) IsRejected() bool {
	if l == nil {
		return false
	}
	l.mu.RLock()
	rejected := l.rejected
	l.mu.RUnlock()
	return rejected
}

func (l *maintenanceRejectionLatch) FailureKind() maintenanceFailureKind {
	if l == nil {
		return maintenanceFailureNone
	}
	l.mu.RLock()
	rejected := l.rejected
	kind := l.kind
	l.mu.RUnlock()
	if !rejected {
		return maintenanceFailureNone
	}
	if !isTerminalMaintenanceImageRejection(kind) {
		return maintenanceFailureIdentityMismatch
	}
	return kind
}

func (l *maintenanceRejectionLatch) Latch(kind maintenanceFailureKind) {
	if l == nil {
		return
	}
	if !isTerminalMaintenanceImageRejection(kind) {
		kind = maintenanceFailureIdentityMismatch
	}
	l.mu.Lock()
	l.rejected = true
	l.kind = kind
	l.mu.Unlock()
}

func (l *maintenanceRejectionLatch) Clear() {
	if l == nil {
		return
	}
	l.mu.Lock()
	l.rejected = false
	l.kind = maintenanceFailureNone
	l.mu.Unlock()
}

func (l *maintenanceRejectionLatch) Error() *maintenanceError {
	kind := l.FailureKind()
	if kind == maintenanceFailureNone {
		return nil
	}
	return newMaintenanceError(kind)
}

func (l *maintenanceRejectionLatch) ApplyOutcome(outcome maintenanceRunOutcome, err error) bool {
	var maintErr *maintenanceError
	if err != nil && errors.As(err, &maintErr) && isTerminalMaintenanceImageRejection(maintErr.Kind) {
		l.Latch(maintErr.Kind)
		return true
	}
	if outcome.BrokerVerified {
		l.Clear()
		return false
	}
	return l.IsRejected()
}

func isAffirmativeLANPolicyOK(status agentStatus) bool {
	return status.NetworkStatus != nil &&
		status.NetworkStatus.PolicyChecked &&
		status.NetworkStatus.PolicyOK &&
		status.NetworkStatus.FirewallValid &&
		!status.NetworkStatus.PolicyInspectionErr &&
		status.NetworkStatus.UnsafeRuleCount == 0
}

func buildMaintenanceOutcome(status agentStatus, brokerVerified bool) maintenanceRunOutcome {
	return maintenanceRunOutcome{
		BrokerVerified:     brokerVerified,
		Status:             status,
		WorkspaceConfirmed: status.workspaceConfirmedKnownTrue(),
		LANEnabled: (status.ModuleStatus != nil && status.ModuleStatus.LANEnabled) ||
			(status.NetworkStatus != nil && status.NetworkStatus.AllowLAN),
		LANPolicyOK: isAffirmativeLANPolicyOK(status),
	}
}

func (r maintenanceRunner) RunModify(ctx context.Context, requireWorkspaceConfirmed bool) (maintenanceRunOutcome, error) {
	purpose := maintenancePurposeLANFirewall
	if requireWorkspaceConfirmed {
		purpose = maintenancePurposeConfirmWorkspace
	}
	return r.RunModifyForPurpose(ctx, purpose)
}

func (r maintenanceRunner) RunModifyForPurpose(ctx context.Context, purpose maintenancePurpose) (maintenanceRunOutcome, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	expectedVersion, expectedPublisher, ok := parseTrustedReleaseIdentity(r.expectedVersion, r.publisherSHA256)
	if !ok {
		return maintenanceRunOutcome{}, newMaintenanceError(maintenanceFailureUnsignedBuild)
	}
	if r.ops.isElevated == nil || r.ops.withPinnedInstall == nil ||
		r.ops.verifyCMSReceipt == nil || r.ops.runBroker == nil {
		return maintenanceRunOutcome{}, newMaintenanceError(maintenanceFailureUnsignedBuild)
	}
	elevated, err := r.ops.isElevated()
	if err != nil || elevated {
		return maintenanceRunOutcome{}, newMaintenanceError(maintenanceFailureElevatedSession)
	}
	installDir := strings.TrimSpace(r.installDir)
	if installDir == "" {
		return maintenanceRunOutcome{}, newMaintenanceError(maintenanceFailureReparsePoint)
	}

	var outcome maintenanceRunOutcome
	err = r.ops.withPinnedInstall(installDir, func(pinned pinnedMaintenanceDir) error {
		rawReceipt, readErr := pinned.ReadReceipt(maintenanceReceiptName, maintenanceReceiptMaxBytes)
		if readErr != nil {
			return ensureMaintenanceError(readErr, maintenanceFailureReceiptMissing)
		}
		content, cmsErr := r.ops.verifyCMSReceipt(rawReceipt, expectedPublisher)
		if cmsErr != nil {
			return ensureMaintenanceError(cmsErr, maintenanceFailureIdentityMismatch)
		}
		receipt, receiptErr := validateMaintenanceReceiptJSON(content, expectedVersion)
		if receiptErr != nil {
			return receiptErr
		}
		if _, imgErr := pinned.VerifyPinnedImage(maintenanceImageRole, receipt.MaintenanceDigest, expectedPublisher); imgErr != nil {
			return ensureMaintenanceError(imgErr, maintenanceFailureIdentityMismatch)
		}
		pinnedBroker, brokerErr := pinned.VerifyPinnedImage(maintenanceBrokerRole, receipt.BrokerDigest, expectedPublisher)
		if brokerErr != nil {
			return ensureMaintenanceError(brokerErr, maintenanceFailureIdentityMismatch)
		}
		args := append([]string(nil), maintenanceModifyArgs...)
		stdout, stderr, exitCode, runErr := r.ops.runBroker(ctx, pinnedBroker, args)
		var modifyErr *maintenanceError
		if runErr != nil || exitCode != 0 {
			modifyErr = classifyMaintenanceBrokerFailure(stdout, stderr, exitCode, runErr)
		}
		if modifyErr != nil && isMaintenanceIdentityRejection(modifyErr.Kind) {
			outcome = maintenanceRunOutcome{}
			return modifyErr
		}

		outcome.BrokerVerified = true
		if modifyErr != nil && modifyErr.Kind == maintenanceFailureOldHostUnsupported {
			return modifyErr
		}

		// Re-read status through the SAME verified pinned broker while all
		// directory and binary pins remain active. Also re-read after any
		// launched wizard exits nonzero (e.g. UAC cancellation) so partial
		// changes such as workspace confirmation are observed.
		if ctx.Err() == nil {
			statusCtx, stopStatus := context.WithTimeout(ctx, maintenanceStatusReadTimeout)
			statusArgs := append([]string(nil), maintenanceStatusArgs...)
			statusOut, statusErrOut, statusExit, statusRunErr := r.ops.runBroker(statusCtx, pinnedBroker, statusArgs)
			stopStatus()
			if statusRunErr == nil && statusExit == 0 {
				if parsed, parseErr := parseAgentStatus(statusOut); parseErr == nil {
					outcome = buildMaintenanceOutcome(parsed, true)
				} else if modifyErr == nil {
					return newMaintenanceError(maintenanceFailureStatusReadFailed)
				}
			} else {
				statusMaintErr := classifyMaintenanceBrokerFailure(statusOut, statusErrOut, statusExit, statusRunErr)
				if statusMaintErr != nil && isMaintenanceIdentityRejection(statusMaintErr.Kind) {
					outcome = maintenanceRunOutcome{}
					return statusMaintErr
				}
				if modifyErr == nil {
					return newMaintenanceError(maintenanceFailureStatusReadFailed)
				}
			}
		} else if modifyErr == nil {
			return newMaintenanceError(maintenanceFailureStatusReadFailed)
		}

		if modifyErr != nil {
			return modifyErr
		}
		return nil
	})
	if err != nil {
		resolvedErr := ensureMaintenanceError(err, maintenanceFailureLaunchFailed)
		if isMaintenanceIdentityRejection(resolvedErr.Kind) {
			outcome = maintenanceRunOutcome{}
		}
		return outcome, resolvedErr
	}

	if purpose == maintenancePurposeConfirmWorkspace && !outcome.WorkspaceConfirmed {
		return outcome, newMaintenanceError(maintenanceFailureStatusStillUnconfirmed)
	}
	if purpose == maintenancePurposeLANFirewall && (!outcome.LANEnabled || !outcome.LANPolicyOK) {
		return outcome, newMaintenanceError(maintenanceFailureLANStillDisabled)
	}
	return outcome, nil
}

func ensureMaintenanceError(err error, fallback maintenanceFailureKind) *maintenanceError {
	if err == nil {
		return nil
	}
	var maintErr *maintenanceError
	if errors.As(err, &maintErr) {
		return maintErr
	}
	return newMaintenanceError(fallback)
}

func classifyMaintenanceBrokerFailure(stdout, stderr []byte, exitCode int, err error) *maintenanceError {
	var maintErr *maintenanceError
	if errors.As(err, &maintErr) {
		return maintErr
	}
	if exitCode == 1223 {
		return newMaintenanceError(maintenanceFailureUACCancelled)
	}
	combined := strings.ToLower(string(stdout) + "\n" + string(stderr))
	if strings.Contains(combined, "installer-maintenance") &&
		(strings.Contains(combined, "未知命令") || strings.Contains(combined, "unknown command")) {
		return newMaintenanceError(maintenanceFailureOldHostUnsupported)
	}
	if strings.Contains(combined, "lan_firewall_blocked") ||
		strings.Contains(combined, "管理员授权已取消") ||
		strings.Contains(combined, "error_cancelled") {
		return newMaintenanceError(maintenanceFailureUACCancelled)
	}
	if strings.Contains(combined, "无法验证此版本的维护程序") {
		return newMaintenanceError(maintenanceFailureIdentityMismatch)
	}
	if strings.Contains(combined, "普通桌面会话") {
		return newMaintenanceError(maintenanceFailureElevatedSession)
	}
	return newMaintenanceError(maintenanceFailureLaunchFailed)
}
