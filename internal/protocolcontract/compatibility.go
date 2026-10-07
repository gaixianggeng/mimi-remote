package protocolcontract

import (
	"fmt"
	"runtime"
)

// VersionResponse 是 agentd /api/version 的稳定线协议。
// 新字段只能以向后兼容方式增加；现有 JSON 名称和语义由共享 golden fixture 锁定。
type VersionResponse struct {
	Name                          string             `json:"name"`
	Version                       string             `json:"version"`
	InstallationID                string             `json:"installation_id"`
	Platform                      string             `json:"platform"`
	ProtocolRevision              int                `json:"protocol_revision"`
	MinimumClientProtocolRevision int                `json:"minimum_client_protocol_revision"`
	Capabilities                  []string           `json:"capabilities"`
	CapabilityStatuses            []CapabilityStatus `json:"capability_statuses"`
	TailscaleDNSName              string             `json:"tailscale_dns_name,omitempty"`
	TailscaleDeviceName           string             `json:"tailscale_device_name,omitempty"`
	// DeviceName 是宿主设备名（macOS 优先系统「电脑名称」，否则主机名）。它只作为
	// 客户端展示默认名的来源，不参与身份、路由或鉴权；纯加法字段，旧客户端直接忽略。
	DeviceName string `json:"device_name,omitempty"`
}

// CapabilityStatus 解释某个已知能力为什么被声明或被服务端关闭。
// state/reason 是稳定机器码；人类诊断文案由 agentd doctor 和客户端本地化负责。
type CapabilityStatus struct {
	Name   string `json:"name"`
	State  string `json:"state"`
	Reason string `json:"reason"`
}

func CurrentVersionResponse(
	version string,
	installationID string,
	capabilities []string,
	statuses []CapabilityStatus,
) VersionResponse {
	return VersionResponse{
		Name:                          "agentd",
		Version:                       version,
		InstallationID:                installationID,
		Platform:                      runtime.GOOS,
		ProtocolRevision:              CurrentRevision,
		MinimumClientProtocolRevision: MinimumSupportedClientRevision,
		Capabilities:                  append([]string(nil), capabilities...),
		CapabilityStatuses:            append([]CapabilityStatus(nil), statuses...),
	}
}

func CurrentVersionResponseWithTailscale(
	version string,
	installationID string,
	dnsName string,
	deviceName string,
	capabilities []string,
	statuses []CapabilityStatus,
) VersionResponse {
	response := CurrentVersionResponse(version, installationID, capabilities, statuses)
	response.TailscaleDNSName = dnsName
	response.TailscaleDeviceName = deviceName
	return response
}

type ClientMetadata struct {
	ProtocolRevision              int
	MinimumServerProtocolRevision int
}

type CompatibilityError struct {
	Code                          string
	Message                       string
	ClientProtocolRevision        int
	MinimumServerProtocolRevision int
	ServerProtocolRevision        int
	MinimumClientProtocolRevision int
}

// CheckClient 只判断双方声明的最低要求，不因客户端修订号更高就拒绝。
// 这样纯加法的新客户端仍可连接旧服务；若它依赖新语义，必须提高 minimum server revision。
func CheckClient(metadata ClientMetadata) *CompatibilityError {
	if metadata.ProtocolRevision < MinimumSupportedClientRevision {
		return &CompatibilityError{
			Code:                          "protocol_incompatible",
			Message:                       fmt.Sprintf("客户端协议修订 %d 低于 agentd 最低兼容修订 %d；请升级 Mimi Remote", metadata.ProtocolRevision, MinimumSupportedClientRevision),
			ClientProtocolRevision:        metadata.ProtocolRevision,
			MinimumServerProtocolRevision: metadata.MinimumServerProtocolRevision,
			ServerProtocolRevision:        CurrentRevision,
			MinimumClientProtocolRevision: MinimumSupportedClientRevision,
		}
	}
	if metadata.MinimumServerProtocolRevision > CurrentRevision {
		return &CompatibilityError{
			Code:                          "protocol_incompatible",
			Message:                       fmt.Sprintf("客户端要求 agentd 协议至少为 %d，当前为 %d；请升级 agentd", metadata.MinimumServerProtocolRevision, CurrentRevision),
			ClientProtocolRevision:        metadata.ProtocolRevision,
			MinimumServerProtocolRevision: metadata.MinimumServerProtocolRevision,
			ServerProtocolRevision:        CurrentRevision,
			MinimumClientProtocolRevision: MinimumSupportedClientRevision,
		}
	}
	return nil
}
