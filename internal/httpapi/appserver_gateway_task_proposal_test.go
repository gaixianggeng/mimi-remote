package httpapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func newClaudeTaskProposalPolicy(t *testing.T) (*appServerGatewayPolicy, string, string) {
	t.Helper()
	projectDir := t.TempDir()
	nestedDir := filepath.Join(projectDir, "nested")
	if err := os.Mkdir(nestedDir, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "project", Name: "Project", Path: projectDir}})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg: config.Config{}, projects: registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := newAppServerGatewayPolicy(router, appServerRuntimeClaudeID)
	scope, ok := router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("project scope unavailable")
	}
	policy.allowThread(appServerGatewayAllowedThread{
		id: "parent-1", runtimeID: appServerRuntimeClaudeID, cwd: scope.realPath, scopeID: scope.id,
		canAcceptDirectInput: true, directInputKnown: true,
	})
	return policy, projectDir, nestedDir
}

func TestClaudeGatewayForwardsTaskProposalOnlyForAuthorizedExactParentCWD(t *testing.T) {
	policy, projectDir, _ := newClaudeTaskProposalPolicy(t)
	payload := []byte(`{"id":1,"method":"thread/start","params":{"cwd":` + quoteJSON(projectDir) + `,"mimiTaskProposal":{"id":"proposal-1","parentThreadId":"parent-1"}}}`)
	forwarded, policyErr := policy.validateClientFrame(websocket.TextMessage, payload)
	if policyErr != nil {
		t.Fatalf("已授权任务提议应转发：%+v", policyErr)
	}
	var frame struct {
		Params map[string]any `json:"params"`
	}
	if err := json.Unmarshal(forwarded, &frame); err != nil {
		t.Fatal(err)
	}
	proposal, ok := frame.Params["mimiTaskProposal"].(map[string]any)
	if !ok || proposal["id"] != "proposal-1" || proposal["parentThreadId"] != "parent-1" {
		t.Fatalf("提议身份应按精确字段转发：%s", forwarded)
	}
}

func TestClaudeGatewayRejectsUntrustedTaskProposalBindings(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*appServerGatewayPolicy, string, string) map[string]any
		want   string
	}{
		{
			name: "unknown parent",
			mutate: func(_ *appServerGatewayPolicy, projectDir, _ string) map[string]any {
				return map[string]any{"cwd": projectDir, "mimiTaskProposal": map[string]any{"id": "proposal-1", "parentThreadId": "unknown"}}
			},
			want: "未由当前 Claude gateway 连接授权",
		},
		{
			name: "different cwd in same project",
			mutate: func(_ *appServerGatewayPolicy, _, nestedDir string) map[string]any {
				return map[string]any{"cwd": nestedDir, "mimiTaskProposal": map[string]any{"id": "proposal-1", "parentThreadId": "parent-1"}}
			},
			want: "必须精确匹配",
		},
		{
			name: "read only parent",
			mutate: func(policy *appServerGatewayPolicy, projectDir, _ string) map[string]any {
				parent, _ := policy.allowedThread("parent-1")
				parent.readOnly = true
				policy.allowThread(parent)
				return map[string]any{"cwd": projectDir, "mimiTaskProposal": map[string]any{"id": "proposal-1", "parentThreadId": "parent-1"}}
			},
			want: "只读子会话",
		},
		{
			name: "extra fields",
			mutate: func(_ *appServerGatewayPolicy, projectDir, _ string) map[string]any {
				return map[string]any{"cwd": projectDir, "mimiTaskProposal": map[string]any{"id": "proposal-1", "parentThreadId": "parent-1", "cwd": projectDir}}
			},
			want: "只包含 id 与 parentThreadId",
		},
	}

	for index, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			policy, projectDir, nestedDir := newClaudeTaskProposalPolicy(t)
			payload, err := json.Marshal(map[string]any{
				"id": index + 10, "method": "thread/start", "params": tc.mutate(policy, projectDir, nestedDir),
			})
			if err != nil {
				t.Fatal(err)
			}
			if _, policyErr := policy.validateClientFrame(websocket.TextMessage, payload); policyErr == nil || !strings.Contains(policyErr.message, tc.want) {
				t.Fatalf("应拒绝不可信提议，want=%q err=%+v", tc.want, policyErr)
			}
		})
	}
}

func TestCodexGatewayRejectsClaudeTaskProposalParameter(t *testing.T) {
	policy, projectDir, _ := newClaudeTaskProposalPolicy(t)
	policy.runtimeID = appServerRuntimeCodexID
	payload := []byte(`{"id":30,"method":"thread/start","params":{"cwd":` + quoteJSON(projectDir) + `,"mimiTaskProposal":{"id":"proposal-1","parentThreadId":"parent-1"}}}`)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, payload); policyErr == nil || !strings.Contains(policyErr.message, "只允许 Claude") {
		t.Fatalf("Codex 不得透传 Claude 任务提议：%+v", policyErr)
	}
}
