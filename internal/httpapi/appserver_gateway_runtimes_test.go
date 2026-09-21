package httpapi

import (
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
	for _, id := range []string{appServerRuntimeCodexID, appServerRuntimeClaudeID} {
		spec, ok := appServerRuntimeSpecFor(id)
		if !ok || spec.ID != id {
			t.Fatalf("登记表缺少 runtime：%s", id)
		}
	}
}

// 未登记的 runtime 必须拿不到任何正向方法。改造前这里是回退到 Codex 方法全集，
// 一个拼错的 runtime 参数就能拿到 thread/fork、review/start 等写方法。
//
// `deepseek` 自原生通道承接后不再登记为 app-server runtime，因此它现在也必须
// 走"未登记"这条路径，而不是拿到旧的适配层方法表。
func TestAppServerRuntimeAllowlistDeniesUnregisteredRuntime(t *testing.T) {
	for _, runtimeID := range []string{"gemini", "copilot", "deepseek_typo", "harness", "deepseek", "dsh"} {
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
		// 原生通道承接 deepseek 后，旧的 harness 别名一律不再改写：
		// 把它映射回一个已登记的 app-server runtime 就等于恢复一条已删除的转发面。
		{"harness alias is not remapped", "DeepSeek_Harness", "deepseek_harness"},
		{"harness cli alias is not remapped", "dsh", "dsh"},
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

// codex/claude 继续沿用共享反向白名单，不能因为曾经新增过独立反向集合的 runtime
// 而被改成各自维护的窄集合。
func TestAppServerExistingRuntimesKeepSharedServerRequestAllowlist(t *testing.T) {
	for _, id := range []string{appServerRuntimeCodexID, appServerRuntimeClaudeID} {
		other, ok := appServerRuntimeSpecFor(id)
		if !ok {
			t.Fatalf("登记表缺少 runtime：%s", id)
		}
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
	}
	for _, tc := range cases {
		t.Run(tc.runtimeID+"/"+tc.method, func(t *testing.T) {
			if got := appServerServerRequestAllowed(tc.runtimeID, tc.method); got != tc.want {
				t.Fatalf("反向请求边界不符：runtime=%s method=%s got=%t want=%t", tc.runtimeID, tc.method, got, tc.want)
			}
		})
	}
}

// 已登记的 runtime 必须显式纳入下行门禁，不能靠 share 白名单顺带生效。
func TestAppServerInboundGateCoversRegisteredRuntimes(t *testing.T) {
	for _, runtimeID := range []string{appServerRuntimeCodexID, appServerRuntimeClaudeID} {
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
