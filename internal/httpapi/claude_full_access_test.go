package httpapi

import (
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"strings"
	"testing"
)

func TestClaudePermissionPresetsRequireExplicitFullAccess(t *testing.T) {
	for _, tc := range []struct{ sandbox, policy, reviewer string }{
		{"readOnly", "on-request", "user"},
		{"workspaceWrite", "on-request", "user"},
		{"workspaceWrite", "on-request", "auto_review"},
		{"dangerFullAccess", "never", "user"},
	} {
		params := map[string]any{"approvalPolicy": tc.policy, "approvalsReviewer": tc.reviewer,
			"sandboxPolicy": map[string]any{"type": tc.sandbox}}
		got := sanitizedGatewayTurnParams("claude", params, "/tmp/workspace")
		if got["approvalPolicy"] != tc.policy || got["approvalsReviewer"] != tc.reviewer || got["sandboxPolicy"].(map[string]any)["type"] != tc.sandbox {
			t.Fatalf("权限档位被改写：%+v => %+v", tc, got)
		}
		if gatewayAllowsNoApproval("claude", "turn/start", params) != (tc.sandbox == "dangerFullAccess") {
			t.Fatalf("只有显式完全访问可关闭审批：%+v", tc)
		}
	}
	for _, params := range []map[string]any{
		{}, {"permissions": ":danger-full-access"}, {"config": map[string]any{"sandbox": "danger-full-access"}},
	} {
		if gatewayAllowsNoApproval("claude", "turn/start", params) {
			t.Fatalf("隐藏参数不能授权完全访问：%v", params)
		}
	}
}

func TestClaudeFullAccessRejectsOldBridgeWithUpgradeHint(t *testing.T) {
	router := &Router{cfg: config.Config{Claude: config.ClaudeConfig{
		Enabled: true, BridgeBin: writeTestBridgeWithVersion(t, "0.2.12"),
	}}}
	_, err := router.validateGatewayPolicyParams("claude", "thread/start", map[string]any{
		"approvalPolicy": "never", "sandbox": "danger-full-access",
	})
	if err == nil || !strings.Contains(err.Error(), "0.2.13") {
		t.Fatalf("旧 bridge 必须明确提示升级：%v", err)
	}
}

func TestOldClaudeBridgeAcceptsPassiveResumeAndOrdinaryTurns(t *testing.T) {
	cfg, registry, _, _, cwd := appServerGatewayBaseFixture(t)
	cfg.Claude = config.ClaudeConfig{Enabled: true, BridgeBin: writeTestBridgeWithVersion(t, "0.2.12")}
	router := &Router{cfg: cfg, projects: registry}
	_, err := router.validateGatewayPolicyParams("claude", "thread/resume", map[string]any{
		"threadId": "test-thread", "cwd": cwd, "approvalPolicy": "on-request", "sandbox": "workspace-write",
	})
	if err != nil {
		t.Fatalf("旧 bridge 应允许普通被动恢复：%v", err)
	}
	for _, sandbox := range []string{"readOnly", "workspaceWrite", "dangerFullAccess"} {
		policy := "on-request"
		if sandbox == "dangerFullAccess" {
			policy = "never"
		}
		_, err := router.validateGatewayPolicyParams("claude", "turn/start", map[string]any{
			"threadId": "test-thread", "cwd": cwd, "approvalPolicy": policy,
			"sandboxPolicy": map[string]any{"type": sandbox},
		})
		if sandbox == "dangerFullAccess" {
			if err == nil || !strings.Contains(err.Error(), "0.2.13") {
				t.Fatalf("显式完全访问仍应要求升级：%v", err)
			}
		} else if err != nil {
			t.Fatalf("普通权限 %s 不应要求升级：%v", sandbox, err)
		}
	}
}
