package httpapi

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件覆盖 DeepSeek Harness 的权限档位。
//
// Harness 自己维护会话权限：session/list 的 projections.permissions 只是一份只读投影，
// 协议里既没有设置入口，session/create 也没有对应字段。因此 agentd 既不能施加只读，
// 也不能施加工作区写限制——能如实兑现的只有完全访问。
//
// 与 claude_full_access_test.go 同形，都在 router 层断言"这一帧能不能过"。

// 回归：移动端"完全访问"档位发出的真实载荷必须被接受。
//
// 这就是日常路径——完全访问是 App 的默认权限档。载荷里有两个不显眼的字段：
// thread/start 的 sandbox=danger-full-access 与 turn/start 同时发送的
// approvalPolicy=never。后者原先只对 codex/claude 放行，默认档因此在网关第一步
// 就被拒，用户看到的是"发出去就没反应"。
func TestDeepSeekAcceptsFullAccessPermissionRequest(t *testing.T) {
	cfg, registry, _, _, cwd := appServerGatewayBaseFixture(t)
	cfg.DeepSeek = config.DeepSeekConfig{Enabled: true}
	router := &Router{cfg: cfg, projects: registry}

	for _, tc := range []struct {
		method string
		params map[string]any
	}{
		{"thread/start", map[string]any{
			"cwd":               cwd,
			"sandbox":           "danger-full-access",
			"approvalPolicy":    "never",
			"approvalsReviewer": "user",
		}},
		{"turn/start", map[string]any{
			"threadId":          "test-thread",
			"cwd":               cwd,
			"approvalPolicy":    "never",
			"approvalsReviewer": "user",
			"sandboxPolicy":     map[string]any{"type": "dangerFullAccess", "networkAccess": false},
		}},
	} {
		if _, err := router.validateGatewayPolicyParams("deepseek", tc.method, tc.params); err != nil {
			t.Fatalf("%s 的完全访问载荷必须被接受：%v", tc.method, err)
		}
	}
}

// 回归：DeepSeek 不能接受自己施加不了的沙盒档位。
//
// 移动端无条件按用户选的权限模式发送 sandbox/sandboxPolicy，而 Harness 的权限档由
// Harness 自身维护，agentd 转发不了也施加不了。静默接受会让用户选了"只读"之后看到
// agent 照常写文件：被承诺却没有执行的约束比没有约束更危险，用户会据此把不该交给
// agent 的目录交给它。所以这里显式拒绝，只放行能被如实兑现的完全访问。
func TestDeepSeekRejectsSandboxModesItCannotEnforce(t *testing.T) {
	cfg, registry, _, _, cwd := appServerGatewayBaseFixture(t)
	cfg.DeepSeek = config.DeepSeekConfig{Enabled: true}
	router := &Router{cfg: cfg, projects: registry}

	for _, sandbox := range []string{"read-only", "workspace-write"} {
		_, err := router.validateGatewayPolicyParams("deepseek", "thread/start", map[string]any{
			"cwd": cwd, "sandbox": sandbox,
		})
		if err == nil || !strings.Contains(err.Error(), "完全访问") {
			t.Fatalf("thread/start 的 %s 必须被拒绝并说明可选项：%v", sandbox, err)
		}
	}
	for _, sandbox := range []string{"readOnly", "workspaceWrite"} {
		_, err := router.validateGatewayPolicyParams("deepseek", "turn/start", map[string]any{
			"threadId": "test-thread", "cwd": cwd,
			"sandboxPolicy": map[string]any{"type": sandbox},
		})
		if err == nil || !strings.Contains(err.Error(), "完全访问") {
			t.Fatalf("turn/start 的 %s 必须被拒绝并说明可选项：%v", sandbox, err)
		}
	}
	// 认不出的档位同样不能放行：把未知值当成完全访问，等于让一个拼错的参数
	// 变成一次静默提权。
	for _, params := range []map[string]any{
		{"cwd": cwd, "sandbox": 42},
		{"cwd": cwd, "sandbox": "  "},
		{"cwd": cwd, "sandbox": "workspace-write-v2"},
		{"cwd": cwd, "sandboxPolicy": map[string]any{"networkAccess": false}},
	} {
		if _, err := router.validateGatewayPolicyParams("deepseek", "thread/start", params); err == nil {
			t.Fatalf("无法识别的沙盒声明必须被拒绝：%v", params)
		}
	}
}

// channel 不能声明 agentd 施加不了的沙盒档位：声明了等于向客户端承诺一个
// 我们无法兑现的开关，而今天的移动端并不读 policy，所以这份声明是唯一的事后证据。
func TestDeepSeekChannelDeclaresOnlyEnforceableSandboxMode(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = "http://127.0.0.1:5173"
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, "startup-token")
	})
	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	channel := findAppServerChannel(fetchAppServerConfig(t, httpServer.URL), appServerRuntimeDeepSeekID)
	if channel == nil {
		t.Fatal("启用后必须声明 DeepSeek channel")
	}
	policy, _ := channel["policy"].(map[string]any)
	if policy == nil {
		t.Fatalf("channel 必须声明 policy：%+v", channel)
	}
	modes, _ := policy["sandbox_modes"].([]any)
	if len(modes) != 1 || modes[0] != "danger-full-access" {
		t.Fatalf("DeepSeek 只能声明可兑现的完全访问档位：%+v", modes)
	}
	approvals, _ := policy["approval_policies"].([]any)
	if len(approvals) != 1 || approvals[0] != "on-request" {
		t.Fatalf("审批仍由用户逐次应答，档位应只有 on-request：%+v", approvals)
	}
}

// 回归：带 callId 的审批不得靠"只有一个会话在跑"去认领。
//
// Harness 的 $events 是宿主级通道，别的会话（Harness Web、子 Agent）的审批同样会
// 送到这里。callId 带了却查不到映射，是"这次工具调用不在本连接订阅的会话里"的
// 正向证据；此时退回单例推断，就会把别人的审批卡片挂到用户的会话上，用户以为在
// 批准自己的操作，实际放行的是别人的。追问（载荷只有 questions）没有任何方向性
// 证据，才允许在唯一活跃会话上兜底。
func TestDeepSeekAttributeWaterfallRequiresEvidenceForApprovals(t *testing.T) {
	for _, tc := range []struct {
		name        string
		request     harnessclient.WaterfallRequest
		callThreads map[string]string
		activeTurns map[string]int
		want        string
	}{
		{
			name:        "帧自带的会话标识优先",
			request:     harnessclient.WaterfallRequest{Event: harnessclient.WaterfallApprovalRequest, ThreadID: "thread-hint"},
			callThreads: map[string]string{"call-1": "thread-a"},
			activeTurns: map[string]int{"thread-a": 1},
			want:        "thread-hint",
		},
		{
			name: "callId 有映射时按映射归属，不受活跃会话数影响",
			request: harnessclient.WaterfallRequest{
				Event: harnessclient.WaterfallApprovalRequest,
				Request: harnessclient.WaterfallPayload{
					CallID: "call-1",
				},
			},
			callThreads: map[string]string{"call-1": "thread-b"},
			activeTurns: map[string]int{"thread-a": 1, "thread-b": 1},
			want:        "thread-b",
		},
		{
			name: "callId 带了却查不到时必须放弃，不得认领唯一活跃会话",
			request: harnessclient.WaterfallRequest{
				Event: harnessclient.WaterfallApprovalRequest,
				Request: harnessclient.WaterfallPayload{
					CallID: "call-elsewhere",
				},
			},
			callThreads: map[string]string{"call-1": "thread-a"},
			activeTurns: map[string]int{"thread-a": 1},
			want:        "",
		},
		{
			name:        "追问没有 callId 时才允许单例兜底",
			request:     harnessclient.WaterfallRequest{Event: harnessclient.WaterfallUserQuestions},
			activeTurns: map[string]int{"thread-a": 1},
			want:        "thread-a",
		},
		{
			name:        "多个活跃会话时无从兜底",
			request:     harnessclient.WaterfallRequest{Event: harnessclient.WaterfallUserQuestions},
			activeTurns: map[string]int{"thread-a": 1, "thread-b": 1},
			want:        "",
		},
		{
			name:    "没有活跃会话时无从兜底",
			request: harnessclient.WaterfallRequest{Event: harnessclient.WaterfallUserQuestions},
			want:    "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			conn := &deepSeekGatewayConn{
				callThreads: tc.callThreads,
				activeTurns: tc.activeTurns,
			}
			if conn.callThreads == nil {
				conn.callThreads = map[string]string{}
			}
			if conn.activeTurns == nil {
				conn.activeTurns = map[string]int{}
			}
			if got := conn.attributeWaterfall(tc.request); got != tc.want {
				t.Fatalf("归属结果应为 %q，得到 %q", tc.want, got)
			}
		})
	}
}
