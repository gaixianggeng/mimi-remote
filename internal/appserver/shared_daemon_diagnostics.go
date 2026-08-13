package appserver

import "time"

const sharedDaemonSoftFileLimit = 8192

type SharedDaemonOwnerState string

const (
	SharedDaemonOwnerStateUnknown           SharedDaemonOwnerState = "unknown"
	SharedDaemonOwnerStateExternal          SharedDaemonOwnerState = "external"
	SharedDaemonOwnerStateStable            SharedDaemonOwnerState = "stable"
	SharedDaemonOwnerStateMigrationPending  SharedDaemonOwnerState = "migration_pending"
	SharedDaemonOwnerStateUnavailable       SharedDaemonOwnerState = "owner_unavailable"
	SharedDaemonOwnerStateClaimedUnverified SharedDaemonOwnerState = "owner_claimed_unverified"
	SharedDaemonOwnerStateUnmanagedListener SharedDaemonOwnerState = "unmanaged_listener"
	SharedDaemonOwnerStateListenerMismatch  SharedDaemonOwnerState = "listener_mismatch"
)

type SharedDaemonResourceState string

const (
	SharedDaemonResourceStateUnknown  SharedDaemonResourceState = "unknown"
	SharedDaemonResourceStateHealthy  SharedDaemonResourceState = "healthy"
	SharedDaemonResourceStateDegraded SharedDaemonResourceState = "degraded"
	SharedDaemonResourceStateCritical SharedDaemonResourceState = "critical"
)

// SharedDaemonDiagnostics 只暴露进程资源与 owner 对账所需的脱敏字段。
// 不返回命令行、环境变量或路径，避免 runtime status / doctor 扩大敏感信息范围。
type SharedDaemonDiagnostics struct {
	Supported            bool
	ListenerPID          int
	ListenerStartedAt    time.Time
	OpenFileDescriptors  int
	DirectChildProcesses int
	// OwnerTargetFDSoftLimit 是 stable owner 下一次启动时的目标配置，不代表
	// 当前 listener 已实际继承。只有 EffectiveFDSoftLimit 有可靠取证时，
	// 才能计算百分比并判断阈值，避免把手工启动的低上限进程误报为健康。
	OwnerTargetFDSoftLimit *int
	EffectiveFDSoftLimit   *int
	FDUsagePercent         *float64
	OwnerState             SharedDaemonOwnerState
	ResourceState          SharedDaemonResourceState
}

func applySharedDaemonResourceState(status *SharedDaemonDiagnostics) {
	if status == nil {
		return
	}
	status.ResourceState = SharedDaemonResourceStateUnknown
	status.FDUsagePercent = nil
	if status.EffectiveFDSoftLimit == nil || *status.EffectiveFDSoftLimit <= 0 {
		return
	}
	usage := float64(status.OpenFileDescriptors) * 100 / float64(*status.EffectiveFDSoftLimit)
	status.FDUsagePercent = &usage
	switch {
	case usage >= 90:
		status.ResourceState = SharedDaemonResourceStateCritical
	case usage >= 70:
		status.ResourceState = SharedDaemonResourceStateDegraded
	default:
		status.ResourceState = SharedDaemonResourceStateHealthy
	}
}
