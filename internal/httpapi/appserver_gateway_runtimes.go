package httpapi

import (
	"sort"
	"strings"
)

// 本文件是 agentd 对 app-server runtime 的显式能力登记表，是方法白名单与权限声明的唯一来源。
//
// 设计约束：runtime 的方法边界必须逐条声明，不允许因为“认不出来”而继承 Codex 的方法全集。
// 改造前 appServerAllowedMethodsForRuntime 对未知 runtime 返回 Codex 方法表，任何拼错或伪造的
// runtime 参数都能直接拿到 Codex 的全部写方法；现在未登记的 runtime 一律拒绝，
// 新增 runtime 必须显式登记，否则拿不到任何正向方法。
//
// 边界之外的入站语义（appServerGatewayPolicy.enforcesInboundThreadAuthorization、内联图片改写、
// 反向 RPC 白名单 appServerAllowedServerRequestMethods）是各自独立的产品决定，不由本表隐式改变。
// 新增 runtime 时仍必须在那些位置显式登记，见各处的说明注释。

const (
	appServerRuntimeCodexID    = "codex"
	appServerRuntimeClaudeID   = "claude"
	appServerRuntimeDeepSeekID = "deepseek"
)

// appServerRuntimeSpec 描述一条 runtime 的能力边界。
type appServerRuntimeSpec struct {
	// ID 是规范化后的标识，同时也是网关 ?runtime= 查询参数使用的取值。
	ID string
	// Aliases 是除 ID 外还能被接受的原始写法，全部小写。
	Aliases []string
	// Methods 是允许移动端发起的正向方法集合。未登记的方法一律拒绝。
	Methods map[string]struct{}
	// ServerRequestMethods 是该 runtime 允许回流的反向 RPC 集合。
	// 为 nil 表示沿用共享白名单 appServerAllowedServerRequestMethods（codex/claude 现状）；
	// 非 nil 表示该 runtime 用更窄的集合，不能继承共享白名单里的其它入口。
	ServerRequestMethods map[string]struct{}
	// Capabilities 是该 runtime 对外声明的基础能力，调用方仍可按实际探测结果下调。
	Capabilities appServerChannelCapability
	// Policy 是该 runtime 的权限语义声明。
	Policy appServerChannelPolicy
	// Experimental 标记尚未承诺稳定兼容的 runtime。
	Experimental bool
}

// appServerRuntimeSpecs 按规范化 ID 登记所有可用 runtime。
var appServerRuntimeSpecs = map[string]appServerRuntimeSpec{
	appServerRuntimeCodexID: {
		ID:      appServerRuntimeCodexID,
		Aliases: []string{"openai", "codex_app_server", "codex-app-server"},
		Methods: appServerAllowedMethods,
		Capabilities: appServerChannelCapability{
			Streaming:        true,
			History:          true,
			ApprovalRequests: true,
			FileDiffs:        true,
			Goals:            true,
			Archive:          true,
			Fork:             true,
			Rename:           true,
			Compact:          true,
			Review:           true,
			RateLimits:       true,
		},
		Policy: appServerChannelPolicy{
			ApprovalPolicies: []string{"on-request"},
			SandboxModes:     []string{"read-only", "workspace-write", "danger-full-access"},
			NetworkAccess:    false,
			CWDScope:         "agentd_allowlist",
		},
	},
	appServerRuntimeClaudeID: {
		ID:      appServerRuntimeClaudeID,
		Aliases: []string{"anthropic", "claude_code", "claude-code", "claude_code_bridge", "claude-code-bridge"},
		Methods: appServerClaudeAllowedMethods,
		Capabilities: appServerChannelCapability{
			Streaming:        true,
			History:          true,
			ApprovalRequests: true,
			FileDiffs:        true,
			// RateLimits 由 bridge 探测结果决定，这里只是默认关闭的基线。
			RateLimits: false,
		},
		Policy: appServerChannelPolicy{
			ApprovalPolicies: []string{"on-request"},
			SandboxModes:     []string{"read-only", "workspace-write"},
			NetworkAccess:    false,
			CWDScope:         "agentd_allowlist",
		},
		Experimental: true,
	},
	// DeepSeek Harness（#498）：方法边界取自 #492 已实测的控制面能力，网关装配见
	// deepseek_gateway.go。channel 只在 deepseek.enabled 时声明，未启用时不会出现在
	// GET app-server config 的 channels 里。
	appServerRuntimeDeepSeekID: {
		ID: appServerRuntimeDeepSeekID,
		Aliases: []string{
			"deepseek_harness", "deepseek-harness", "deepseek_harness_service", "deepseek-harness-service", "dsh",
		},
		Methods: appServerDeepSeekAllowedMethods,
		ServerRequestMethods: map[string]struct{}{
			"applyPatchApproval":                    {},
			"execCommandApproval":                   {},
			"item/commandExecution/requestApproval": {},
			"item/fileChange/requestApproval":       {},
			"item/fileRead/requestApproval":         {},
			"item/permissions/requestApproval":      {},
			"item/tool/requestUserInput":            {},
		},
		Capabilities: appServerChannelCapability{
			Streaming:        true,
			History:          true,
			ApprovalRequests: true,
		},
		Policy: appServerChannelPolicy{
			ApprovalPolicies: []string{"on-request"},
			SandboxModes:     []string{"read-only", "workspace-write"},
			NetworkAccess:    false,
			CWDScope:         "agentd_allowlist",
		},
		Experimental: true,
	},
}

func appServerRuntimeSpecFor(runtimeID string) (appServerRuntimeSpec, bool) {
	spec, ok := appServerRuntimeSpecs[normalizeAppServerRuntimeID(runtimeID)]
	return spec, ok
}

// appServerRuntimeRegistered 供配置校验与诊断复用，避免各处重复维护 runtime 名称表。
func appServerRuntimeRegistered(runtimeID string) bool {
	_, ok := appServerRuntimeSpecFor(runtimeID)
	return ok
}

func appServerRuntimeIDs() []string {
	ids := make([]string, 0, len(appServerRuntimeSpecs))
	for id := range appServerRuntimeSpecs {
		ids = append(ids, id)
	}
	// 保持稳定顺序，便于配置报错与日志比对。
	sort.Strings(ids)
	return ids
}

func normalizeAppServerRuntimeID(raw string) string {
	value := strings.TrimSpace(strings.ToLower(raw))
	switch value {
	case "", appServerRuntimeCodexID, "openai", "codex_app_server", "codex-app-server":
		return appServerRuntimeCodexID
	case appServerRuntimeClaudeID, "anthropic", "claude_code", "claude-code", "claude_code_bridge", "claude-code-bridge":
		return appServerRuntimeClaudeID
	case appServerRuntimeDeepSeekID, "deepseek_harness", "deepseek-harness",
		"deepseek_harness_service", "deepseek-harness-service", "dsh":
		return appServerRuntimeDeepSeekID
	default:
		return value
	}
}
