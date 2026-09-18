package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

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

// 回归：交互归属只能靠帧里的身份字段或 callId 映射，不得靠"只有一个会话在跑"推断。
//
// Harness 的 $events 是宿主级通道，别的会话（Harness Web、子 Agent）的交互同样会送到
// 这里。"只有一个会话在跑"不蕴含"这条交互是我的"：按单例认领会把别人的卡片挂到用户的
// 会话上，用户在那个上下文里点"允许"，放行的却是另一个会话的工具调用；追问更糟——用户
// 填的答案会被送回发起方。
//
// 生产帧必然带 agentId（api-gateway 的 RemoteEventInvocationFrame 把它定为必填，
// startRemoteEvent 对空值直接抛错），而 Harness 的身份设计是"agent 的注册表 id 等于其
// 会话 id"，所以主判据是帧里的身份字段。取不到证据时返回空串，由调用方暂存等待，
// 不再猜测。
func TestDeepSeekAttributeWaterfallRequiresEvidence(t *testing.T) {
	for _, tc := range []struct {
		name         string
		request      harnessclient.WaterfallRequest
		callThreads  map[string]string
		activeTurns  map[string]int
		want         string
		wantEvidence string
	}{
		{
			name: "agentId 是主判据，压过 callId 映射",
			request: harnessclient.WaterfallRequest{
				Event:   harnessclient.WaterfallApprovalRequest,
				AgentID: "thread-agent",
				Request: harnessclient.WaterfallPayload{CallID: "call-1"},
			},
			callThreads:  map[string]string{"call-1": "thread-a"},
			activeTurns:  map[string]int{"thread-a": 1},
			want:         "thread-agent",
			wantEvidence: deepSeekEvidenceAgent,
		},
		{
			name: "没有 agentId 时用帧里其它会话标识",
			request: harnessclient.WaterfallRequest{
				Event:    harnessclient.WaterfallApprovalRequest,
				ThreadID: "thread-hint",
			},
			callThreads:  map[string]string{"call-1": "thread-a"},
			activeTurns:  map[string]int{"thread-a": 1},
			want:         "thread-hint",
			wantEvidence: deepSeekEvidenceHint,
		},
		{
			name: "两者都缺时按 callId 映射复核",
			request: harnessclient.WaterfallRequest{
				Event:   harnessclient.WaterfallApprovalRequest,
				Request: harnessclient.WaterfallPayload{CallID: "call-1"},
			},
			callThreads:  map[string]string{"call-1": "thread-b"},
			activeTurns:  map[string]int{"thread-a": 1, "thread-b": 1},
			want:         "thread-b",
			wantEvidence: deepSeekEvidenceCall,
		},
		{
			name: "callId 查不到映射时不得认领唯一活跃会话",
			request: harnessclient.WaterfallRequest{
				Event:   harnessclient.WaterfallApprovalRequest,
				Request: harnessclient.WaterfallPayload{CallID: "call-elsewhere"},
			},
			callThreads: map[string]string{"call-1": "thread-a"},
			activeTurns: map[string]int{"thread-a": 1},
			want:        "",
		},
		{
			name:        "追问没有 agentId 时同样不得靠唯一活跃会话兜底",
			request:     harnessclient.WaterfallRequest{Event: harnessclient.WaterfallUserQuestions},
			activeTurns: map[string]int{"thread-a": 1},
			want:        "",
		},
		{
			name:        "多个活跃会话时更没有依据",
			request:     harnessclient.WaterfallRequest{Event: harnessclient.WaterfallUserQuestions},
			activeTurns: map[string]int{"thread-a": 1, "thread-b": 1},
			want:        "",
		},
		{
			name:    "没有活跃会话时没有依据",
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
			got, evidence := conn.attributeWaterfall(tc.request)
			if got != tc.want {
				t.Fatalf("归属结果应为 %q，得到 %q", tc.want, got)
			}
			if evidence != tc.wantEvidence {
				t.Fatalf("归属依据应为 %q，得到 %q", tc.wantEvidence, evidence)
			}
		})
	}
}

// 回归：暂存的交互必须在有证据前保留、到期被清理，且未归属时绝不擅自下发。
//
// 这是审查 Finding 2 的状态机不变式：approval 的 callId → 会话映射由会话订阅上的
// tool/call 事件建立，审批却来自另一条 $events 连接，两者没有可靠的到达顺序——waterfall
// 先到、tool/call 后到是正常时序。因此拿不到归属时应该暂存而不是丢弃，超时按诊断清理，
// 反复重试既不能过早丢弃、也不能刷新到期时间：前者让卡片永久消失，后者把"等 2 分钟"
// 退化成"永远等"。
func TestDeepSeekHoldInteractionPreservesUntilEvidenceOrExpiry(t *testing.T) {
	conn := &deepSeekGatewayConn{
		callThreads:         map[string]string{},
		activeTurns:         map[string]int{},
		waterfalls:          map[string]deepSeekPendingWaterfall{},
		pendingInteractions: map[string]deepSeekPendingInteraction{},
	}

	unattributed := deepSeekPendingInteraction{
		request: harnessclient.WaterfallRequest{
			Event:   harnessclient.WaterfallApprovalRequest,
			EventID: "evt-pending",
			Request: harnessclient.WaterfallPayload{CallID: "call-missing"},
		},
		expiresAt: time.Now().Add(50 * time.Millisecond),
	}
	expired := deepSeekPendingInteraction{
		request: harnessclient.WaterfallRequest{
			Event:   harnessclient.WaterfallUserQuestions,
			EventID: "evt-expired",
		},
		expiresAt: time.Now().Add(-time.Second),
	}
	conn.pendingInteractions[unattributed.request.EventID] = unattributed
	conn.pendingInteractions[expired.request.EventID] = expired

	conn.retryPendingInteractions()

	// 未过期但无证据：保留原条目与原到期时间，不丢弃、不刷新。
	kept, ok := conn.pendingInteractions[unattributed.request.EventID]
	if !ok {
		t.Fatalf("无证据且未过期的交互不应被丢弃，否则审批会因为到达顺序永久丢失")
	}
	if !kept.expiresAt.Equal(unattributed.expiresAt) {
		t.Fatalf("暂存重试不得刷新到期时间：want %v，got %v", unattributed.expiresAt, kept.expiresAt)
	}
	// 已过等待窗口：按诊断清理，不做任何应答动作。
	if _, ok := conn.pendingInteractions[expired.request.EventID]; ok {
		t.Fatalf("超出等待窗口的交互应被清理")
	}
	// 没有可归属的交互，绝不能下发待应答卡片。
	if len(conn.waterfalls) != 0 {
		t.Fatalf("未归属的交互不得被下发，waterfalls=%d", len(conn.waterfalls))
	}
}

// 回归（PR 评审：未匹配的 waterfall 被永久忽略）：审批先到、tool/call 后到是正常时序，
// 关联信息补齐的那一刻必须真的把卡片发出去。
//
// 上一条只钉住"没有证据时保留、过期时清理"。评审指出的失败模式比这更进一步：暂存之后
// 再无人回访，Harness 一直等应答、turn 卡死。因此这里跑完整个闭环——暂存 → tool/call
// 落表 → 自动重试 → 卡片到达客户端，并核对卡片挂在正确的会话上。
func TestDeepSeekHeldInteractionDeliveredWhenCallContextArrives(t *testing.T) {
	const eventID = "event-late-context"
	serverConn, clientConn := deepSeekCancelTestWebSocketPair(t)
	policy, projectDir := newInboundPolicyForTest(t, appServerRuntimeDeepSeekID)
	// 反向请求要过下行授权门禁（inboundServerRequestAllowed 按 threadId 查授权表），
	// 先把这条会话登记成已授权，否则测的是门禁而不是重试闭环。
	policy.allowThread(appServerGatewayAllowedThread{
		id: "thread-late", runtimeID: appServerRuntimeDeepSeekID, cwd: projectDir, scopeID: "project",
	})
	conn := &deepSeekGatewayConn{
		client:              serverConn,
		policy:              policy,
		callThreads:         map[string]string{},
		follows:             map[string]*deepSeekFollow{},
		waterfalls:          map[string]deepSeekPendingWaterfall{},
		pendingInteractions: map[string]deepSeekPendingInteraction{},
	}

	// 审批来自 $events：帧里没有 agentId，callId 在本连接的会话事件里也还没出现过，
	// 此刻没有任何方向性证据可用。
	request := harnessclient.WaterfallRequest{
		Type:    "waterfall",
		EventID: eventID,
		Event:   harnessclient.WaterfallApprovalRequest,
		Request: harnessclient.WaterfallPayload{ToolName: "write", CallID: "call-late"},
	}
	conn.dispatchWaterfall(t.Context(), request)
	if _, ok := conn.pendingInteractions[eventID]; !ok {
		t.Fatal("拿不到归属的审批必须暂存，否则审批会因到达顺序永久丢失")
	}
	if _, ok := conn.waterfalls[eventID]; ok {
		t.Fatal("还没有归属依据时不得下发卡片")
	}

	// 会话订阅随后补上工具调用：映射一落表就必须回访暂存项并下发，不需要等轮询定时器。
	conn.noteEventContext("thread-late", harnessclient.SessionWireEvent{
		Type: deepSeekEventToolCall,
		Data: json.RawMessage(`{"callId":"call-late","turn":1,"step":1}`),
	})

	if _, ok := conn.pendingInteractions[eventID]; ok {
		t.Fatal("关联信息补齐后暂存项应被消费")
	}
	pending, ok := conn.waterfalls[eventID]
	if !ok {
		t.Fatal("关联信息补齐后审批卡片必须真的下发，否则 Harness 会一直等应答")
	}
	if pending.threadID != "thread-late" {
		t.Fatalf("卡片应挂到提供 callId 映射的会话，得到 %q", pending.threadID)
	}
	if pending.method != "item/commandExecution/requestApproval" {
		t.Fatalf("下发的应是审批请求，得到 %q", pending.method)
	}
	if err := clientConn.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	_, raw, err := clientConn.ReadMessage()
	if err != nil {
		t.Fatalf("客户端应收到一张审批卡片：%v", err)
	}
	if !strings.Contains(string(raw), `"item/commandExecution/requestApproval"`) {
		t.Fatalf("下发的帧应是审批请求：%s", raw)
	}
	if !strings.Contains(string(raw), `"thread-late"`) {
		t.Fatalf("审批请求应带上归属会话：%s", raw)
	}
}
