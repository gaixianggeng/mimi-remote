package httpapi

import (
	"encoding/json"
	"net/http"
	"strconv"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件是 Gate B 要审的安全负向用例：交互归属与 $events/result 应答校验。
//
// 归属与审批帧形状在契约里是**源码级**（实跑未触发审批），因此这里一律
// fail closed：形状不符、证据不足、代次不符都拒绝，不静默降级。

// --- 归属：只认证据，不认「唯一活跃会话」 ---

func TestHarnessNativeAttributePrefersAgentIdentity(t *testing.T) {
	// agentId 是协议保证存在的字段，也是唯一由上游直接给出的会话标识。
	request := harnessclient.WaterfallRequest{
		Type:      "waterfall",
		Event:     harnessclient.WaterfallApprovalRequest,
		AgentID:   "session-from-agent",
		SessionID: "session-from-candidate",
	}
	sessionID, evidence := harnessNativeAttributeWaterfall(request, nil)
	if sessionID != "session-from-agent" {
		t.Fatalf("agentId 必须优先，得到 %q", sessionID)
	}
	if evidence != harnessNativeEvidenceAgent {
		t.Fatalf("归属依据应为 agent，得到 %q", evidence)
	}
}

func TestHarnessNativeAttributeFallsBackToHintThenCallMap(t *testing.T) {
	hintOnly := harnessclient.WaterfallRequest{
		Type:     "waterfall",
		Event:    harnessclient.WaterfallApprovalRequest,
		ThreadID: "session-from-hint",
		Request:  harnessclient.WaterfallPayload{CallID: "call-1"},
	}
	sessionID, evidence := harnessNativeAttributeWaterfall(hintOnly, map[string]string{"call-1": "session-from-call"})
	if sessionID != "session-from-hint" || evidence != harnessNativeEvidenceHint {
		t.Fatalf("hint 应优先于 callId 映射，得到 %q/%q", sessionID, evidence)
	}

	callOnly := harnessclient.WaterfallRequest{
		Type:    "waterfall",
		Event:   harnessclient.WaterfallApprovalRequest,
		Request: harnessclient.WaterfallPayload{CallID: "call-1"},
	}
	sessionID, evidence = harnessNativeAttributeWaterfall(callOnly, map[string]string{"call-1": "session-from-call"})
	if sessionID != "session-from-call" || evidence != harnessNativeEvidenceCall {
		t.Fatalf("有映射时应采用 callId 归属，得到 %q/%q", sessionID, evidence)
	}
}

func TestHarnessNativeAttributeNeverGuessesFromSingleActiveSession(t *testing.T) {
	// 契约与既有实现都明确废弃「唯一活跃会话」兜底：$events 是宿主级通道，
	// "只有一个会话在跑"并不蕴含"这条交互是我的"。取不到证据必须返回空串。
	request := harnessclient.WaterfallRequest{
		Type:    "waterfall",
		Event:   harnessclient.WaterfallApprovalRequest,
		Request: harnessclient.WaterfallPayload{CallID: "call-without-mapping", ToolName: "bash"},
	}
	sessionID, evidence := harnessNativeAttributeWaterfall(request, map[string]string{})
	if sessionID != "" || evidence != "" {
		t.Fatalf("无证据时必须返回空归属，不得猜测，得到 %q/%q", sessionID, evidence)
	}
}

func TestHarnessNativeRememberCallThreadIgnoresBlankValues(t *testing.T) {
	registry := newHarnessNativeInteractionRegistry()
	registry.rememberCallThread("", "session-a")
	registry.rememberCallThread("call-a", "")
	registry.rememberCallThread("  ", "session-a")
	if got := registry.callThreadSnapshot(); len(got) != 0 {
		t.Fatalf("空值不得登记映射，得到 %v", got)
	}
	registry.rememberCallThread("call-a", "session-a")
	if got := registry.callThreadSnapshot(); got["call-a"] != "session-a" {
		t.Fatalf("有效映射必须登记，得到 %v", got)
	}
}

// --- 应答认领：跨设备 / 跨会话 / 跨代次 / 已终结 ---

func TestHarnessNativeClaimRejectsEventNeverDelivered(t *testing.T) {
	// 这是伪造应答的主路径：拿一个本连接从未收到的 eventId 去替别人做决定。
	registry := newHarnessNativeInteractionRegistry()
	_, result, err := registry.claim("event-never-delivered", 1)
	if err == nil {
		t.Fatal("未投递的 eventId 必须拒绝")
	}
	if result != 0 {
		t.Fatalf("拒绝时不得返回认领结论，得到 %v", result)
	}
	status, message := harnessNativePolicyStatus(err)
	if status != http.StatusForbidden {
		t.Fatalf("应为 403，得到 %d（%s）", status, message)
	}
}

func TestHarnessNativeClaimRejectsStaleGeneration(t *testing.T) {
	// 跨代次：断线重连后新连接有自己的代次，旧代次的卡片不得替它做决定。
	registry := newHarnessNativeInteractionRegistry()
	if !registry.deliver(harnessNativeInteraction{
		EventID:    "event-1",
		SessionID:  "session-a",
		Event:      harnessclient.WaterfallApprovalRequest,
		Generation: 7,
	}) {
		t.Fatal("首次投递必须成功")
	}
	_, _, err := registry.claim("event-1", 8)
	if err == nil {
		t.Fatal("代次不符必须拒绝")
	}
	if status, _ := harnessNativePolicyStatus(err); status != http.StatusForbidden {
		t.Fatalf("应为 403，得到 %d", status)
	}

	// 同代次可以认领。
	if _, result, err := registry.claim("event-1", 7); err != nil || result != harnessNativeClaimAccepted {
		t.Fatalf("同代次应可认领，得到 %v/%v", result, err)
	}
}

func TestHarnessNativeClaimIsExclusiveWithinGeneration(t *testing.T) {
	// 同一代次内也不允许两个连接同时决定同一条交互。
	registry := newHarnessNativeInteractionRegistry()
	registry.deliver(harnessNativeInteraction{
		EventID: "event-1", SessionID: "session-a",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
	})
	if _, _, err := registry.claim("event-1", 1); err != nil {
		t.Fatal(err)
	}
	_, _, err := registry.claim("event-1", 1)
	if err == nil {
		t.Fatal("已认领的交互不得被再次认领")
	}
	if status, _ := harnessNativePolicyStatus(err); status != http.StatusConflict {
		t.Fatalf("应为 409，得到 %d", status)
	}
}

func TestHarnessNativeClaimTreatsSettledEventAsNoop(t *testing.T) {
	// 契约：迟到应答是空操作而非错误。转发只会拿到上游的 lookup-not-found。
	registry := newHarnessNativeInteractionRegistry()
	registry.deliver(harnessNativeInteraction{
		EventID: "event-1", SessionID: "session-a",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
	})
	registry.settle("event-1")

	pending, result, err := registry.claim("event-1", 1)
	if err != nil {
		t.Fatalf("已终结的应答应是空操作，不是错误：%v", err)
	}
	if result != harnessNativeClaimSettled {
		t.Fatalf("应判定为空操作，得到 %v", result)
	}
	if pending != nil {
		t.Fatalf("空操作不得返回可转发记录，得到 %+v", pending)
	}
}

func TestHarnessNativeClaimRejectsBlankEventID(t *testing.T) {
	registry := newHarnessNativeInteractionRegistry()
	_, _, err := registry.claim("   ", 1)
	if err == nil {
		t.Fatal("空 eventId 必须拒绝")
	}
	if status, _ := harnessNativePolicyStatus(err); status != http.StatusBadRequest {
		t.Fatalf("应为 400，得到 %d", status)
	}
}

// --- 投递去重与终态 ---

func TestHarnessNativeRedeliveryCannotRebindSessionOrGeneration(t *testing.T) {
	// 一条注册表属于一条移动连接；重连使用新注册表，不允许原记录被改绑。
	registry := newHarnessNativeInteractionRegistry()
	if !registry.deliver(harnessNativeInteraction{
		EventID: "event-1", SessionID: "session-a",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
	}) {
		t.Fatal("首次投递必须成功")
	}
	if registry.deliver(harnessNativeInteraction{
		EventID: "event-1", SessionID: "session-b",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 2,
	}) {
		t.Fatal("重投不得产生新卡片")
	}
	if count := registry.pendingCount(); count != 1 {
		t.Fatalf("重投后待应答条数应仍为 1，得到 %d", count)
	}
	// 不匹配的重投必须保留原记录与授权，不接受新的身份。
	registry.mu.Lock()
	updated := registry.pending["event-1"]
	registry.mu.Unlock()
	if updated.SessionID != "session-a" || updated.Generation != 1 {
		t.Fatalf("冲突重投不得改绑原卡片，得到 %+v", updated)
	}
}

func TestHarnessNativeTerminalEventCannotBeRevivedByAnotherStream(t *testing.T) {
	registry := newHarnessNativeInteractionRegistry()
	registry.deliver(harnessNativeInteraction{
		EventID: "event-1", SessionID: "session-a",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
	})
	registry.settle("event-1")

	if registry.deliver(harnessNativeInteraction{
		EventID: "event-1", SessionID: "session-a",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 2,
	}) {
		t.Fatal("已终结的 eventId 不得经另一条流复活")
	}
	if count := registry.pendingCount(); count != 0 {
		t.Fatalf("复活不应留下待应答记录，得到 %d", count)
	}
}

func TestHarnessNativePendingOverflowFailsObservably(t *testing.T) {
	// 溢出必须可观测失败，不能静默丢卡片：用户看不到卡片就会以为无事可做。
	registry := newHarnessNativeInteractionRegistry()
	for index := 0; index < harnessNativeInteractionPendingMax; index++ {
		if !registry.deliver(harnessNativeInteraction{
			EventID: eventIDFor(index), SessionID: "session-a",
			Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
		}) {
			t.Fatalf("第 %d 条不应被拒", index)
		}
	}
	if registry.deliver(harnessNativeInteraction{
		EventID: "event-overflow", SessionID: "session-a",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
	}) {
		t.Fatal("超出上限必须失败，不得静默丢弃")
	}
	if count := registry.pendingCount(); count != harnessNativeInteractionPendingMax {
		t.Fatalf("待应答条数应停在上限，得到 %d", count)
	}
}

func TestHarnessNativeReleaseAllowsRetryAfterKnownFailure(t *testing.T) {
	// 尚未发出或已知被拒的请求可解除本次认领；结果未知的网关路径不调用 release。
	registry := newHarnessNativeInteractionRegistry()
	registry.deliver(harnessNativeInteraction{
		EventID: "event-1", SessionID: "session-a",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
	})
	if _, _, err := registry.claim("event-1", 1); err != nil {
		t.Fatal(err)
	}
	registry.release("event-1")
	if _, result, err := registry.claim("event-1", 1); err != nil || result != harnessNativeClaimAccepted {
		t.Fatalf("释放后应可重新认领，得到 %v/%v", result, err)
	}
}

func TestHarnessNativeForgetSessionDropsPendingInteractions(t *testing.T) {
	// 撤权必须让旧卡片立刻失效：否则已不该看见该会话的客户端仍能替它做决定。
	registry := newHarnessNativeInteractionRegistry()
	registry.deliver(harnessNativeInteraction{
		EventID: "event-a", SessionID: "session-a",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
	})
	registry.deliver(harnessNativeInteraction{
		EventID: "event-b", SessionID: "session-b",
		Event: harnessclient.WaterfallApprovalRequest, Generation: 1,
	})

	registry.forgetSession("session-a")

	if count := registry.pendingCount(); count != 1 {
		t.Fatalf("只应丢弃目标会话的卡片，得到 %d", count)
	}
	// 撤权后的应答是**越权**，必须拒绝（403），不能当成迟到的良性空操作。
	_, _, err := registry.claim("event-a", 1)
	if err == nil {
		t.Fatal("撤权后的卡片不得再被认领")
	}
	if status, _ := harnessNativePolicyStatus(err); status != http.StatusForbidden {
		t.Fatalf("撤权后的应答应为 403，得到 %d", status)
	}
	// 撤权不记终态：会话重新授权后应能正常收到重投的卡片。
	if registry.isTerminal("event-a") {
		t.Fatal("撤权丢弃不应记终态，否则重新授权后无法再投递")
	}
	if _, result, err := registry.claim("event-b", 1); err != nil || result != harnessNativeClaimAccepted {
		t.Fatalf("其它会话的卡片不应受影响，得到 %v/%v", result, err)
	}
}

// --- outcome 形状校验（fail closed） ---

func TestHarnessNativeValidateOutcomeAcceptsContractShapes(t *testing.T) {
	cases := []struct {
		name  string
		event string
		raw   string
	}{
		{"next", harnessclient.WaterfallApprovalRequest, `{"kind":"next"}`},
		{"approval-allowed", harnessclient.WaterfallApprovalRequest, `{"kind":"result","value":"allowed-once"}`},
		{"approval-rejected", harnessclient.WaterfallApprovalRequest, `{"kind":"result","value":"rejected"}`},
		{"questions", harnessclient.WaterfallUserQuestions,
			`{"kind":"result","value":{"answers":[{"id":"q1","selected":["a"]}]}}`},
		{"rejected", harnessclient.WaterfallApprovalRequest,
			`{"kind":"rejected","error":{"name":"Error","message":"m"}}`},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if _, err := harnessNativeValidateOutcome(testCase.event, json.RawMessage(testCase.raw)); err != nil {
				t.Fatalf("契约形状必须接受：%v", err)
			}
		})
	}
}

func TestHarnessNativeValidateOutcomeRejectsBadShapes(t *testing.T) {
	cases := []struct {
		name  string
		event string
		raw   string
	}{
		{"unknown-kind", harnessclient.WaterfallApprovalRequest, `{"kind":"whatever"}`},
		{"missing-kind", harnessclient.WaterfallApprovalRequest, `{}`},
		{"approval-out-of-domain", harnessclient.WaterfallApprovalRequest, `{"kind":"result","value":"always-allow"}`},
		{"approval-not-string", harnessclient.WaterfallApprovalRequest, `{"kind":"result","value":{"answers":[]}}`},
		{"questions-empty", harnessclient.WaterfallUserQuestions, `{"kind":"result","value":{"answers":[]}}`},
		{"questions-missing-id", harnessclient.WaterfallUserQuestions,
			`{"kind":"result","value":{"answers":[{"selected":["a"]}]}}`},
		{"rejected-without-error", harnessclient.WaterfallApprovalRequest, `{"kind":"rejected"}`},
		{"rejected-without-name", harnessclient.WaterfallApprovalRequest, `{"kind":"rejected","error":{"message":"m"}}`},
		{"unknown-interaction", "something/else", `{"kind":"result","value":"allowed-once"}`},
		{"unknown-field", harnessclient.WaterfallApprovalRequest, `{"kind":"next","sessionId":"s"}`},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if _, err := harnessNativeValidateOutcome(testCase.event, json.RawMessage(testCase.raw)); err == nil {
				t.Fatal("非法形状必须 fail closed 拒绝")
			}
		})
	}
}

func eventIDFor(index int) string {
	return "event-" + strconv.Itoa(index)
}
