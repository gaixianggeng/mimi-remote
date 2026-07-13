//go:build ipadwsprobe

package main

import (
	"encoding/json"
	"path/filepath"
	"reflect"
	"testing"
)

func TestResolveDefaultAgentDConfigPath(t *testing.T) {
	configDir := filepath.Join(string(filepath.Separator), "tmp", "Library", "Application Support")
	current := filepath.Join(configDir, "mimi-remote", "config.json")
	legacy := filepath.Join(configDir, "codex-ipad-agent", "config.json")

	t.Run("new install uses current path", func(t *testing.T) {
		got := resolveDefaultAgentDConfigPath(configDir, func(string) bool { return false })
		if got != current {
			t.Fatalf("默认配置路径 = %q, want %q", got, current)
		}
	})

	t.Run("legacy install remains readable", func(t *testing.T) {
		got := resolveDefaultAgentDConfigPath(configDir, func(path string) bool { return path == legacy })
		if got != legacy {
			t.Fatalf("旧配置回退路径 = %q, want %q", got, legacy)
		}
	})

	t.Run("current path wins when both exist", func(t *testing.T) {
		got := resolveDefaultAgentDConfigPath(configDir, func(string) bool { return true })
		if got != current {
			t.Fatalf("新配置路径 = %q, want %q", got, current)
		}
	})
}

func TestParseListedModelsAcceptsAppServerShapes(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want []listedModel
	}{
		{
			name: "models wrapper prefers model field",
			raw:  `{"models":[{"model":"gpt-alpha","provider":"openai","isDefault":true},{"id":"gpt-beta","modelProvider":"openai"}]}`,
			want: []listedModel{
				{Model: "gpt-alpha", Provider: "openai", IsDefault: true},
				{Model: "gpt-beta", Provider: "openai"},
			},
		},
		{
			name: "data wrapper accepts id and snake case provider",
			raw:  `{"data":[{"id":"gpt-data","model_provider":"openai","is_default":true}]}`,
			want: []listedModel{{Model: "gpt-data", Provider: "openai", IsDefault: true}},
		},
		{
			name: "top level array ignores duplicates and malformed items",
			raw:  `[{"name":"gpt-array","default":true},{"id":"gpt-array","provider":"duplicate"},42,{"provider":"missing-model"}]`,
			want: []listedModel{{Model: "gpt-array", IsDefault: true}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseListedModels(json.RawMessage(tt.raw))
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("parseListedModels() = %#v, want %#v", got, tt.want)
			}
		})
	}
}

func TestDefaultModelFromListPrefersDefaultThenFirst(t *testing.T) {
	selected, err := defaultModelFromList(json.RawMessage(`{"models":[{"id":"gpt-first","provider":"openai"},{"id":"gpt-default","provider":"openai","isDefault":true}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if selected.Model != "gpt-default" {
		t.Fatalf("应优先使用 model/list 标记的默认模型：%#v", selected)
	}

	selected, err = defaultModelFromList(json.RawMessage(`{"models":[{"id":"gpt-first","provider":"openai"},{"id":"gpt-second","provider":"other"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if selected.Model != "gpt-first" {
		t.Fatalf("没有默认标记时应回退第一项：%#v", selected)
	}

	if _, err := defaultModelFromList(json.RawMessage(`{"models":[]}`)); err == nil {
		t.Fatal("空 model/list 必须返回错误，避免 probe 发空 model")
	}
}

func TestProbeThreadParamsCarryExplicitModelAndProvider(t *testing.T) {
	params := safeThreadParams("/tmp/mimi", "gpt-default", "openai")
	if params["model"] != "gpt-default" || params["modelProvider"] != "openai" {
		t.Fatalf("thread/start 必须显式携带 model 和 provider：%v", params)
	}
	if params["approvalPolicy"] != "on-request" || params["approvalsReviewer"] != "user" || params["sandbox"] != "workspace-write" {
		t.Fatalf("probe 只能使用安全默认权限：%v", params)
	}

	resume := withThreadID(params, "thread-1")
	if resume["threadId"] != "thread-1" || resume["excludeTurns"] != true {
		t.Fatalf("thread/resume 必须补 threadId/excludeTurns：%v", resume)
	}
	if resume["model"] != "gpt-default" || resume["modelProvider"] != "openai" {
		t.Fatalf("thread/resume 也必须保留显式 model，避免恢复旧会话时 rollout 缺失：%v", resume)
	}
	if _, ok := resume["ephemeral"]; ok {
		t.Fatalf("thread/resume 不应带 ephemeral：%v", resume)
	}
}

func TestProbeThreadParamsOmitBlankProvider(t *testing.T) {
	params := safeThreadParams("/tmp/mimi", "gpt-default", "  ")
	if params["model"] != "gpt-default" {
		t.Fatalf("显式 model 必须保留：%v", params)
	}
	if _, ok := params["modelProvider"]; ok {
		t.Fatalf("空 provider 不应发送给 app-server：%v", params)
	}
}

func TestThreadListParamsUseIndexedFastPath(t *testing.T) {
	params := threadListParams(project{Path: "/tmp/mimi"}, 20, true)
	if params["cwd"] != "/tmp/mimi" || params["limit"] != 20 {
		t.Fatalf("thread/list 必须保留工作区和小页参数：%v", params)
	}
	if params["sortKey"] != "updated_at" || params["sortDirection"] != "desc" {
		t.Fatalf("thread/list 必须按最近更新时间倒序：%v", params)
	}
	if params["useStateDbOnly"] != true {
		t.Fatalf("日常探针必须覆盖 Codex 状态库快路径：%v", params)
	}
}

func TestProbeEventObservationRejectsClaudeAuthenticationFailure(t *testing.T) {
	event := rpcFrame{
		Method: "item/completed",
		Params: map[string]any{
			"item": map[string]any{
				"type":              "agentMessage",
				"text":              "Failed to authenticate. API Error: 401 Invalid authentication credentials",
				"isApiErrorMessage": true,
				"error":             "authentication_failed",
			},
		},
	}

	text, failure := probeEventObservation(event)
	if text == "" {
		t.Fatal("探针必须识别 completed agentMessage，避免把真实回复漏掉")
	}
	if failure == "" {
		t.Fatal("Claude 401 不能因为收到 turn/completed 就被误判为成功")
	}
}

func TestProbeEventObservationExtractsAssistantDelta(t *testing.T) {
	event := rpcFrame{
		Method: "item/agentMessage/delta",
		Params: map[string]any{"threadId": "thread-1", "delta": "ok"},
	}

	text, failure := probeEventObservation(event)
	if text != "ok" || failure != "" {
		t.Fatalf("正常 assistant delta 应被视为有效回复：text=%q failure=%q", text, failure)
	}
}

func TestCompletedTurnFailureRequiresAssistantOutput(t *testing.T) {
	completed := rpcFrame{Method: "turn/completed", Params: map[string]any{
		"turn": map[string]any{"id": "turn-1", "status": "completed"},
	}}
	if failure := completedTurnFailure(false, completed); failure == "" {
		t.Fatal("没有任何 assistant 输出的 completed turn 必须判失败")
	}
	if failure := completedTurnFailure(true, completed); failure != "" {
		t.Fatalf("有正常 assistant 输出的 completed turn 不应失败：%s", failure)
	}

	failed := rpcFrame{Method: "turn/completed", Params: map[string]any{
		"turn": map[string]any{
			"id":     "turn-2",
			"status": "failed",
			"error":  map[string]any{"message": "runtime unavailable"},
		},
	}}
	if failure := completedTurnFailure(true, failed); failure == "" {
		t.Fatal("turn.status=failed 即使曾有 delta 也必须判失败")
	}
}
