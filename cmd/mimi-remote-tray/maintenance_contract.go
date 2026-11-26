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
	"time"
)

const (
	maintenanceReceiptName         = "maintenance-identity.p7m"
	maintenanceReceiptMaxBytes     = 131072
	maintenanceReceiptSchema       = "mimi.windows.maintenance/v1"
	maintenanceBrokerRole          = "agentd.exe"
	maintenanceImageRole           = "Mimi-Remote-Maintenance.exe"
	maintenanceOfficialDownloadURL = onboardingURLDesktop
	maintenanceDefaultTimeout      = 15 * time.Minute
)

var maintenanceModifyArgs = []string{"installer-maintenance", "modify"}

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

// pinnedMaintenanceDir represents an installed directory whose volume root and
// every ancestor directory have been opened without FILE_SHARE_DELETE and
// checked against reparse points until the launch callback returns.
type pinnedMaintenanceDir interface {
	ReadReceipt(name string, maxBytes int64) ([]byte, error)
	VerifyPinnedImage(name string, expectedDigest []byte, expectedPublisher []byte) (string, error)
}

type maintenancePlatformOps struct {
	isElevated        func() (bool, error)
	withPinnedInstall func(installDir string, fn func(pinned pinnedMaintenanceDir) error) error
	verifyCMSReceipt  func(raw []byte, expectedPublisher []byte) ([]byte, error)
	runBroker         func(ctx context.Context, pinnedBrokerPath string, args []string) (stdout []byte, stderr []byte, exitCode int, err error)
	readStatus        func(ctx context.Context) (agentStatus, error)
}

type maintenanceRunner struct {
	installDir      string
	expectedVersion string
	publisherSHA256 string
	ops             maintenancePlatformOps
}

type maintenanceRunOutcome struct {
	Status             agentStatus
	WorkspaceConfirmed bool
	LANEnabled         bool
	LANPolicyOK        bool
}

func (r maintenanceRunner) RunModify(ctx context.Context, requireWorkspaceConfirmed bool) (maintenanceRunOutcome, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	expectedVersion, expectedPublisher, ok := parseTrustedReleaseIdentity(r.expectedVersion, r.publisherSHA256)
	if !ok {
		return maintenanceRunOutcome{}, newMaintenanceError(maintenanceFailureUnsignedBuild)
	}
	if r.ops.isElevated == nil || r.ops.withPinnedInstall == nil ||
		r.ops.verifyCMSReceipt == nil || r.ops.runBroker == nil || r.ops.readStatus == nil {
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
		pinnedBrokerPath, brokerErr := pinned.VerifyPinnedImage(maintenanceBrokerRole, receipt.BrokerDigest, expectedPublisher)
		if brokerErr != nil {
			return ensureMaintenanceError(brokerErr, maintenanceFailureIdentityMismatch)
		}
		args := append([]string(nil), maintenanceModifyArgs...)
		stdout, stderr, exitCode, runErr := r.ops.runBroker(ctx, pinnedBrokerPath, args)
		if runErr != nil || exitCode != 0 {
			return classifyMaintenanceBrokerFailure(stdout, stderr, exitCode, runErr)
		}
		return nil
	})
	if err != nil {
		return maintenanceRunOutcome{}, ensureMaintenanceError(err, maintenanceFailureLaunchFailed)
	}

	status, statusErr := r.ops.readStatus(ctx)
	if statusErr != nil {
		return maintenanceRunOutcome{}, newMaintenanceError(maintenanceFailureStatusReadFailed)
	}
	outcome := maintenanceRunOutcome{
		Status:             status,
		WorkspaceConfirmed: status.workspaceConfirmedKnownTrue(),
		LANEnabled: (status.ModuleStatus != nil && status.ModuleStatus.LANEnabled) ||
			(status.NetworkStatus != nil && status.NetworkStatus.AllowLAN),
		LANPolicyOK: status.NetworkStatus == nil ||
			!status.NetworkStatus.PolicyChecked ||
			status.NetworkStatus.PolicyOK,
	}
	if requireWorkspaceConfirmed && !outcome.WorkspaceConfirmed {
		return outcome, newMaintenanceError(maintenanceFailureStatusStillUnconfirmed)
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
