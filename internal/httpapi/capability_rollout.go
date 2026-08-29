package httpapi

import (
	"log"
	"net/http"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/protocolcontract"
)

const (
	fileUploadCapability            = "file_upload_v1"
	codexRemoteFullAccessCapability = "codex_remote_full_access_v1"

	capabilityStateEnabled               = "enabled"
	capabilityStateLocallyDisabled       = "locally_disabled"
	capabilityStateDependencyUnavailable = "dependency_unavailable"

	capabilityReasonAvailable             = "available"
	capabilityReasonDisabledByLocalConfig = "disabled_by_local_config"
	capabilityReasonStorageUnavailable    = "storage_unavailable"
)

type capabilityRegistry struct {
	ordered []protocolcontract.CapabilityStatus
	byName  map[string]protocolcontract.CapabilityStatus
}

func newCapabilityRegistry(cfg config.Config, fileUploads *fileUploadStore) capabilityRegistry {
	fileUpload := protocolcontract.CapabilityStatus{
		Name:   fileUploadCapability,
		State:  capabilityStateEnabled,
		Reason: capabilityReasonAvailable,
	}
	switch {
	case cfg.Capabilities.IsDisabled(fileUploadCapability):
		fileUpload.State = capabilityStateLocallyDisabled
		fileUpload.Reason = capabilityReasonDisabledByLocalConfig
	case fileUploads == nil || fileUploads.probe() != nil:
		// 依赖检查只输出稳定原因码，避免把本机缓存路径或权限细节带入远端响应和日志。
		fileUpload.State = capabilityStateDependencyUnavailable
		fileUpload.Reason = capabilityReasonStorageUnavailable
	}
	codexRemoteFullAccess := protocolcontract.CapabilityStatus{
		Name:   codexRemoteFullAccessCapability,
		State:  capabilityStateEnabled,
		Reason: capabilityReasonAvailable,
	}
	if cfg.Capabilities.IsDisabled(codexRemoteFullAccessCapability) {
		codexRemoteFullAccess.State = capabilityStateLocallyDisabled
		codexRemoteFullAccess.Reason = capabilityReasonDisabledByLocalConfig
	}

	statuses := []protocolcontract.CapabilityStatus{fileUpload, codexRemoteFullAccess}
	for _, status := range statuses {
		log.Printf(
			"capability decision name=%s state=%s reason=%s",
			status.Name,
			status.State,
			status.Reason,
		)
	}
	return capabilityRegistry{
		ordered: statuses,
		byName: map[string]protocolcontract.CapabilityStatus{
			fileUpload.Name:            fileUpload,
			codexRemoteFullAccess.Name: codexRemoteFullAccess,
		},
	}
}

func (r capabilityRegistry) enabled(name string) bool {
	status, ok := r.byName[name]
	return ok && status.State == capabilityStateEnabled
}

func (r capabilityRegistry) enabledNames() []string {
	names := make([]string, 0, len(r.ordered))
	for _, status := range r.ordered {
		if status.State == capabilityStateEnabled {
			names = append(names, status.Name)
		}
	}
	return names
}

func (r capabilityRegistry) statuses() []protocolcontract.CapabilityStatus {
	return append([]protocolcontract.CapabilityStatus(nil), r.ordered...)
}

func (r capabilityRegistry) status(name string) protocolcontract.CapabilityStatus {
	return r.byName[name]
}

func (r capabilityRegistry) appendDoctorCheck(results doctor.Results) doctor.Results {
	status := r.status(fileUploadCapability)
	check := doctor.Check{
		Name:       "capability-file-upload-v1",
		OK:         status.State == capabilityStateEnabled,
		Level:      "ok",
		Capability: status.Name,
		State:      status.State,
		Reason:     status.Reason,
	}
	switch status.State {
	case capabilityStateEnabled:
		check.Message = "file_upload_v1 已启用，文件缓存依赖可用"
	case capabilityStateLocallyDisabled:
		check.Level = "warning"
		check.Message = "file_upload_v1 已被当前 Mac 的本地配置禁用"
		check.Fix = "从 config.json 的 capabilities.disabled 移除 file_upload_v1，然后重启 agentd"
	default:
		check.Level = "warning"
		check.Message = "file_upload_v1 因本地文件缓存不可用而安全关闭"
		check.Fix = "检查当前服务账户的缓存目录写权限，然后重启 agentd"
	}
	results.Checks = append(results.Checks, check)
	return results
}

func (r capabilityRegistry) writeUnavailable(w http.ResponseWriter, name string) {
	status := r.status(name)
	code := "capability_unavailable"
	message := "当前 agentd 未启用该能力"
	switch status.State {
	case capabilityStateLocallyDisabled:
		code = "capability_locally_disabled"
		message = "当前 Mac 已通过本地配置禁用该能力"
	case capabilityStateDependencyUnavailable:
		code = "capability_dependency_unavailable"
		message = "该能力的本地依赖暂不可用"
	}
	writeJSON(w, http.StatusServiceUnavailable, map[string]string{
		"error":      message,
		"code":       code,
		"capability": name,
		"state":      status.State,
	})
}
