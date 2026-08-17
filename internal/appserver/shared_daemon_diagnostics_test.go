package appserver

import "testing"

func TestApplySharedDaemonResourceStateRequiresEffectiveLimit(t *testing.T) {
	tests := []struct {
		name      string
		openFiles int
		limit     *int
		wantState SharedDaemonResourceState
		wantUsage *float64
	}{
		{name: "limit unknown", openFiles: 200, wantState: SharedDaemonResourceStateUnknown},
		{name: "healthy", openFiles: 4096, limit: intPointer(8192), wantState: SharedDaemonResourceStateHealthy, wantUsage: floatPointer(50)},
		{name: "degraded boundary", openFiles: 5735, limit: intPointer(8192), wantState: SharedDaemonResourceStateDegraded},
		{name: "critical boundary", openFiles: 7373, limit: intPointer(8192), wantState: SharedDaemonResourceStateCritical},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			status := SharedDaemonDiagnostics{
				OpenFileDescriptors:  testCase.openFiles,
				EffectiveFDSoftLimit: testCase.limit,
			}
			applySharedDaemonResourceState(&status)
			if status.ResourceState != testCase.wantState {
				t.Fatalf("资源状态错误：got=%s want=%s", status.ResourceState, testCase.wantState)
			}
			if testCase.wantUsage == nil {
				if status.FDUsagePercent != nil && testCase.limit == nil {
					t.Fatalf("上限未知时不能推测 FD 使用率：%v", *status.FDUsagePercent)
				}
				return
			}
			if status.FDUsagePercent == nil || *status.FDUsagePercent != *testCase.wantUsage {
				t.Fatalf("FD 使用率错误：got=%v want=%v", status.FDUsagePercent, *testCase.wantUsage)
			}
		})
	}
}

func TestApplySharedDaemonResourceStateDoesNotAssumeConfiguredLimitIsEffective(t *testing.T) {
	configured := 8192
	status := SharedDaemonDiagnostics{
		OpenFileDescriptors:    8000,
		OwnerTargetFDSoftLimit: &configured,
	}
	applySharedDaemonResourceState(&status)
	if status.ResourceState != SharedDaemonResourceStateUnknown || status.FDUsagePercent != nil {
		t.Fatalf("仅有 owner 配置时不能推测当前 listener 的资源水位：%+v", status)
	}
}

func intPointer(value int) *int { return &value }

func floatPointer(value float64) *float64 { return &value }
