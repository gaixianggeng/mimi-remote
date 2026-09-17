package httpapi

import (
	"reflect"
	"sort"
	"testing"
)

// runtime 登记表必须覆盖全部已登记 ID，并保持稳定顺序。
func TestAppServerRuntimeIDsCoverRegistryInOrder(t *testing.T) {
	ids := appServerRuntimeIDs()
	if len(ids) != len(appServerRuntimeSpecs) {
		t.Fatalf("runtime ID 列表应与登记表一致：ids=%v specs=%d", ids, len(appServerRuntimeSpecs))
	}
	if !sort.StringsAreSorted(ids) {
		t.Fatalf("runtime ID 列表必须有序：%v", ids)
	}
	for _, id := range []string{appServerRuntimeCodexID, appServerRuntimeClaudeID, appServerRuntimeDeepSeekID} {
		spec, ok := appServerRuntimeSpecFor(id)
		if !ok || spec.ID != id {
			t.Fatalf("登记表缺少 runtime：%s", id)
		}
	}
}

// 未登记的 runtime 必须拿不到任何正向方法。改造前这里是回退到 Codex 方法全集，
// 一个拼错的 runtime 参数就能拿到 thread/fork、review/start 等写方法。
func TestAppServerRuntimeAllowlistDeniesUnregisteredRuntime(t *testing.T) {
	for _, runtimeID := range []string{"gemini", "copilot", "deepseek_typo", "harness"} {
		t.Run(runtimeID, func(t *testing.T) {
			if got := appServerAllowedMethodsForRuntime(runtimeID); len(got) != 0 {
				t.Fatalf("未登记 runtime 不应获得任何方法：runtime=%s methods=%d", runtimeID, len(got))
			}
			if got := appServerAllowedMethodListForRuntime(runtimeID); len(got) != 0 {
				t.Fatalf("未登记 runtime 的方法列表应为空：runtime=%s methods=%v", runtimeID, got)
			}
			if appServerRuntimeRegistered(runtimeID) {
				t.Fatalf("未登记 runtime 不应被判定为已登记：%s", runtimeID)
			}
		})
	}
}

// 已登记 runtime 的方法表必须是非空且互不相同的显式声明。
func TestAppServerRuntimeSpecsAreNonEmptyAndDistinct(t *testing.T) {
	if len(appServerRuntimeSpecs) == 0 {
		t.Fatal("runtime 登记表不应为空")
	}
	for id, spec := range appServerRuntimeSpecs {
		if spec.ID != id {
			t.Fatalf("登记表 key 与 spec.ID 不一致：key=%s id=%s", id, spec.ID)
		}
		if len(spec.Methods) == 0 {
			t.Fatalf("已登记 runtime 必须有显式方法表：%s", id)
		}
		if spec.Policy.CWDScope != "agentd_allowlist" {
			t.Fatalf("runtime 必须保留 agentd 工作区授权作用域：%s scope=%s", id, spec.Policy.CWDScope)
		}
	}
	if reflect.DeepEqual(appServerDeepSeekAllowedMethods, appServerAllowedMethods) {
		t.Fatal("new runtime 不能直接复用 Codex 方法表")
	}
}

// Harness 首版只声明 #492 已用隔离实验验证过的方法。把未验证能力写进表就会让
// 移动端出现选得中但用不了的入口，因此逐条断言这些方法不在表内。
func TestAppServerDeepSeekMethodsExcludeUnverifiedCapabilities(t *testing.T) {
	unverified := []string{
		// Harness 没有 resume RPC，冷会话恢复不靠它。
		"thread/resume",
		// steer 与 queue 语义不同且本轮未验证。
		"turn/steer",
		// 首版不开放的会话管理能力。
		"thread/fork",
		"thread/archive",
		"thread/unarchive",
		"thread/compact/start",
		"thread/name/set",
		"thread/settings/update",
		"thread/goal/get",
		"thread/goal/set",
		"thread/goal/clear",
		"review/start",
		// Harness 未暴露速率查询，也未适配技能与插件目录。
		"account/rateLimits/read",
		"account/usage/read",
		"skills/list",
		"plugin/installed",
		"permissionProfile/list",
	}
	for _, method := range unverified {
		if _, ok := appServerDeepSeekAllowedMethods[method]; ok {
			t.Errorf("未验证能力不应出现在 Harness 方法表：%s", method)
		}
	}
	required := []string{
		"thread/list", "thread/search", "thread/start", "thread/read",
		"thread/turns/list", "thread/items/list", "thread/unsubscribe",
		"turn/start", "turn/interrupt", "model/list",
	}
	for _, method := range required {
		if _, ok := appServerDeepSeekAllowedMethods[method]; !ok {
			t.Errorf("已验证能力必须出现在 Harness 方法表：%s", method)
		}
	}
}

// 别名必须收敛到同一个 runtime，否则网关 ?runtime= 参数会因为写法不同而拿到不同边界。
func TestAppServerRuntimeAliasesResolveToSameSpec(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{"empty defaults to codex", "", appServerRuntimeCodexID},
		{"trimmed and lowercased", "  CoDeX  ", appServerRuntimeCodexID},
		{"codex type alias", "codex_app_server", appServerRuntimeCodexID},
		{"claude bridge alias", "claude-code-bridge", appServerRuntimeClaudeID},
		{"provider alias", "anthropic", appServerRuntimeClaudeID},
		{"harness alias", "DeepSeek_Harness", appServerRuntimeDeepSeekID},
		{"harness service alias", "deepseek-harness-service", appServerRuntimeDeepSeekID},
		{"harness cli alias", "dsh", appServerRuntimeDeepSeekID},
		// 未登记的值只做规范化，不改写成已登记 runtime。
		{"unknown stays as is", "gemini", "gemini"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := normalizeAppServerRuntimeID(tc.raw); got != tc.want {
				t.Fatalf("runtime 规范化结果不符：raw=%q got=%q want=%q", tc.raw, got, tc.want)
			}
		})
	}
	harness, ok := appServerRuntimeSpecFor("DSH")
	if !ok || harness.ID != appServerRuntimeDeepSeekID {
		t.Fatalf("别名应解析到 Harness 登记项：ok=%t spec=%+v", ok, harness)
	}
}

// 方法列表要稳定排序，客户端与服务端比对时不能因 map 迭代顺序抖动。
func TestAppServerRuntimeMethodListIsSorted(t *testing.T) {
	for id := range appServerRuntimeSpecs {
		methods := appServerAllowedMethodListForRuntime(id)
		if !sort.StringsAreSorted(methods) {
			t.Fatalf("runtime 方法列表必须有序：%s %v", id, methods)
		}
		if want := len(appServerRuntimeSpecs[id].Methods); len(methods) != want {
			t.Fatalf("runtime 方法列表长度应与登记表一致：%s got=%d want=%d", id, len(methods), want)
		}
	}
}

// Harness 的反向交互只经审批与结构化追问两条 waterfall，不能继承共享白名单里的
// MCP elicitation、动态工具调用等未适配入口。共享白名单本身保持不变。
func TestAppServerDeepSeekServerRequestsAreNarrowerThanSharedAllowlist(t *testing.T) {
	spec, ok := appServerRuntimeSpecFor(appServerRuntimeDeepSeekID)
	if !ok || spec.ServerRequestMethods == nil {
		t.Fatal("Harness 必须声明自己的反向 RPC 集合")
	}
	for method := range spec.ServerRequestMethods {
		if _, shared := appServerAllowedServerRequestMethods[method]; !shared {
			t.Errorf("Harness 反向集合不应超出移动端已实现的方法：%s", method)
		}
	}
	for _, method := range []string{"mcpServer/elicitation/request", "item/tool/call"} {
		if _, ok := spec.ServerRequestMethods[method]; ok {
			t.Errorf("未适配的反向入口不应声明给 Harness：%s", method)
		}
	}
	for _, method := range []string{"item/commandExecution/requestApproval", "item/tool/requestUserInput"} {
		if _, ok := spec.ServerRequestMethods[method]; !ok {
			t.Errorf("审批与结构化追问必须声明给 Harness：%s", method)
		}
	}
	// codex/claude 继续沿用共享白名单，不能因为新增 runtime 而收窄既有边界。
	for _, id := range []string{appServerRuntimeCodexID, appServerRuntimeClaudeID} {
		other, _ := appServerRuntimeSpecFor(id)
		if other.ServerRequestMethods != nil {
			t.Fatalf("既有 runtime 不应被改成独立反向集合：%s", id)
		}
	}
}

func TestAppServerServerRequestAllowedPrefersRuntimeSpec(t *testing.T) {
	cases := []struct {
		runtimeID string
		method    string
		want      bool
	}{
		{appServerRuntimeCodexID, "applyPatchApproval", true},
		{appServerRuntimeCodexID, "item/tool/call", true},
		{appServerRuntimeClaudeID, "item/tool/call", false},
		{appServerRuntimeDeepSeekID, "item/tool/requestUserInput", true},
		{appServerRuntimeDeepSeekID, "mcpServer/elicitation/request", false},
		{appServerRuntimeDeepSeekID, "item/tool/call", false},
		{appServerRuntimeDeepSeekID, "approval/unknown", false},
	}
	for _, tc := range cases {
		t.Run(tc.runtimeID+"/"+tc.method, func(t *testing.T) {
			if got := appServerServerRequestAllowed(tc.runtimeID, tc.method); got != tc.want {
				t.Fatalf("反向请求边界不符：runtime=%s method=%s got=%t want=%t", tc.runtimeID, tc.method, got, tc.want)
			}
		})
	}
}

// 新接入的 runtime 必须显式纳入下行门禁，不能靠 share 白名单顺带生效。
func TestAppServerInboundGateCoversHarnessExplicitly(t *testing.T) {
	for _, runtimeID := range []string{appServerRuntimeCodexID, appServerRuntimeClaudeID, appServerRuntimeDeepSeekID} {
		policy := &appServerGatewayPolicy{runtimeID: runtimeID}
		if !policy.enforcesInboundThreadAuthorization() {
			t.Errorf("已登记 runtime 必须按 thread 授权：%s", runtimeID)
		}
		if !appServerRuntimeRedactsInlineImages(runtimeID) {
			t.Errorf("已登记 runtime 必须改写真播内联图：%s", runtimeID)
		}
	}
	// 未知 runtime 保持既有透传语义，这是独立的产品决定。
	policy := &appServerGatewayPolicy{runtimeID: "gemini"}
	if policy.enforcesInboundThreadAuthorization() {
		t.Fatal("未知 runtime 不应改变既有透传语义")
	}
	if appServerRuntimeRedactsInlineImages("gemini") {
		t.Fatal("未知 runtime 不应改变既有透传语义")
	}
}
