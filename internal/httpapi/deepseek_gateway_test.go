package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件覆盖 DeepSeek 网关的三类风险：
//
//   - 凭据：启动 token 只走认证握手，不得出现在错误帧、状态文案或诊断里。
//   - 契约：分页结果的键必须存在、item id 必须在直播与历史间一致。
//   - 失败方向：认不出的审批结论、非文本输入、无法归属的交互一律停下，不放行。

// ---------------------------------------------------------------- 纯函数契约

// 认不出的审批结论必须回 unavailable。默认放行会让一个格式错误的应答变成一次授权。
func TestDeepSeekApprovalOutcomeFailsClosedOnUnknownDecision(t *testing.T) {
	tests := []struct {
		name     string
		decision string
		want     string
	}{
		{name: "accept", decision: "accept", want: harnessclient.OutcomeAllowedOnce},
		{name: "approve", decision: "approve", want: harnessclient.OutcomeAllowedOnce},
		{name: "acceptForSession", decision: "acceptForSession", want: harnessclient.OutcomeAllowedOnce},
		{name: "acceptAlways", decision: "acceptAlways", want: harnessclient.OutcomeAllowedOnce},
		{name: "snake case accept", decision: "accept_for_session", want: harnessclient.OutcomeAllowedOnce},
		{name: "decline", decision: "decline", want: harnessclient.OutcomeRejected},
		{name: "reject", decision: "reject", want: harnessclient.OutcomeRejected},
		{name: "cancel", decision: "cancel", want: harnessclient.OutcomeCancelled},
		{name: "abort", decision: "abort", want: harnessclient.OutcomeCancelled},
		// 关键分支：认不出、大小写混杂、空值一律不得放行。
		{name: "unknown", decision: "maybe-later", want: harnessclient.OutcomeUnavailable},
		{name: "empty", decision: "", want: harnessclient.OutcomeUnavailable},
		{name: "allow spelled differently", decision: "allow", want: harnessclient.OutcomeUnavailable},
		{name: "prefix of accept", decision: "acc", want: harnessclient.OutcomeUnavailable},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := deepSeekApprovalOutcome(test.decision); got != test.want {
				t.Fatalf("decision=%q outcome=%q, want %q", test.decision, got, test.want)
			}
		})
	}
}

// 审批应答缺少 decision 字段时必须判为无效，不能拿零值当结论。
func TestDeepSeekApprovalDecisionRequiresExplicitField(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want bool
	}{
		{name: "valid", raw: `{"decision":"accept"}`, want: true},
		{name: "missing", raw: `{}`, want: false},
		{name: "blank", raw: `{"decision":"   "}`, want: false},
		{name: "wrong type", raw: `{"decision":7}`, want: false},
		{name: "not an object", raw: `"accept"`, want: false},
		{name: "empty", raw: ``, want: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, ok := deepSeekApprovalDecision(json.RawMessage(test.raw))
			if ok != test.want {
				t.Fatalf("raw=%s ok=%v, want %v", test.raw, ok, test.want)
			}
		})
	}
}

// 追问应答必须带 question id：没有 id 的答案无法对上 Harness 的问题。
func TestDeepSeekQuestionAnswersRequiresQuestionID(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want bool
	}{
		{name: "valid", raw: `{"answers":{"q1":{"answers":["a"]}}}`, want: true},
		{name: "empty map", raw: `{"answers":{}}`, want: false},
		{name: "missing key", raw: `{}`, want: false},
		{name: "blank id", raw: `{"answers":{"  ":{"answers":["a"]}}}`, want: false},
		{name: "malformed", raw: `{"answers":`, want: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, ok := deepSeekQuestionAnswers(json.RawMessage(test.raw))
			if ok != test.want {
				t.Fatalf("raw=%s ok=%v, want %v", test.raw, ok, test.want)
			}
		})
	}
}

// 追问应答要把答案按 question id 落在 Answer.ID 上。
func TestDeepSeekQuestionAnswersKeepsQuestionIDs(t *testing.T) {
	answers, ok := deepSeekQuestionAnswers(json.RawMessage(
		`{"answers":{"q1":{"answers":["first"]},"q2":{"answers":["second","third"]}}}`))
	if !ok {
		t.Fatal("合法应答应被接受")
	}
	if len(answers) != 2 {
		t.Fatalf("答案条数 = %d, want 2", len(answers))
	}
	byID := map[string][]string{}
	for _, answer := range answers {
		byID[answer.ID] = answer.Selected
	}
	if len(byID["q2"]) != 2 || byID["q1"][0] != "first" {
		t.Fatalf("答案未按 question id 归位：%+v", answers)
	}
}

// cursor 必须自带出处标记；不认识的 cursor 一律当作"从头开始"，不能猜一个 seq。
func TestDeepSeekCursorRoundTripsAndRejectsForeignCursors(t *testing.T) {
	for _, seq := range []int64{1, 7, 4096, 1 << 40} {
		encoded := encodeDeepSeekCursor(seq)
		if encoded == "" {
			t.Fatalf("seq=%d 应能编码", seq)
		}
		decoded, ok := decodeDeepSeekCursor(encoded)
		if !ok || decoded != seq {
			t.Fatalf("seq=%d 往返得到 %d ok=%v", seq, decoded, ok)
		}
	}
	if encodeDeepSeekCursor(0) != "" || encodeDeepSeekCursor(-3) != "" {
		t.Fatal("非正 seq 不应产生 cursor")
	}

	foreign := []string{
		"",
		"   ",
		"opaque-upstream-cursor",
		deepSeekTurnCursorPrefix,
		deepSeekTurnCursorPrefix + "!!!not-base64",
		deepSeekTurnCursorPrefix + "MA",   // 解码为 "0"，非正
		deepSeekTurnCursorPrefix + "LTEi", // 解码为 "-1"
	}
	for _, cursor := range foreign {
		if seq, ok := decodeDeepSeekCursor(cursor); ok {
			t.Fatalf("cursor=%q 不应被接受，得到 seq=%d", cursor, seq)
		}
	}
}

// 没有 turn/end 的 turn 如实报 inProgress：报 completed 会让界面显示一个从未完成的回合。
func TestDeepSeekTurnStatusReportsInProgressWithoutTurnEnd(t *testing.T) {
	tests := []struct {
		name   string
		bucket deepSeekTurnBucket
		want   string
	}{
		{name: "unterminated", bucket: deepSeekTurnBucket{Turn: 1}, want: "inProgress"},
		{name: "unterminated with reason", bucket: deepSeekTurnBucket{Turn: 1, Reason: "completed"}, want: "inProgress"},
		{name: "completed", bucket: deepSeekTurnBucket{Turn: 1, Ended: true, Reason: "completed"}, want: "completed"},
		{name: "failed", bucket: deepSeekTurnBucket{Turn: 1, Ended: true, Reason: "failed"}, want: "failed"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := deepSeekTurnStatusFor(test.bucket); got != test.want {
				t.Fatalf("status=%q, want %q", got, test.want)
			}
		})
	}
}

// 顺序切分必须对缺失 turn/end 免疫：上一轮被中断时不能把两轮的记录混进一个 turn。
func TestDeepSeekSplitTurnsKeepsUnterminatedTurnSeparate(t *testing.T) {
	records := []harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 1, Data: json.RawMessage(`{"turn":1}`)},
		{Type: deepSeekEventUserMessage, Seq: 2, Data: json.RawMessage(`{"id":"u1"}`)},
		// 第一轮没有 turn/end 就直接开始第二轮。
		{Type: deepSeekEventTurnStart, Seq: 3, Data: json.RawMessage(`{"turn":2}`)},
		{Type: deepSeekEventTurnEnd, Seq: 4, Data: json.RawMessage(`{"turn":2,"reason":{"kind":"completed"}}`)},
		// 收尾之后到达的记录归上一轮：turn/start 被上游裁剪时，这一条是它唯一的归属。
		{Type: deepSeekEventAssistantMessage, Seq: 5, Data: json.RawMessage(`{"step":0,"content":[{"type":"text","text":"late"}]}`)},
	}

	buckets := deepSeekSplitTurns(records)
	if len(buckets) != 2 {
		t.Fatalf("turn 桶数 = %d, want 2：%+v", len(buckets), buckets)
	}
	if buckets[0].Turn != 1 || buckets[0].Ended {
		t.Fatalf("第一轮应保持未结束：%+v", buckets[0])
	}
	if len(buckets[0].Records) != 2 {
		t.Fatalf("第一轮记录数 = %d, want 2（不得吞掉第二轮的记录）", len(buckets[0].Records))
	}
	if buckets[1].Turn != 2 || !buckets[1].Ended || buckets[1].Reason != "completed" {
		t.Fatalf("第二轮应结束且带结论：%+v", buckets[1])
	}
	if len(buckets[1].Records) != 3 {
		t.Fatalf("第二轮记录数 = %d, want 3（收尾后的记录归上一轮）", len(buckets[1].Records))
	}
}

// turn/start 之前的散记录不属于任何一轮，丢掉而不是塞进上一轮。
func TestDeepSeekSplitTurnsDropsRecordsBeforeFirstTurnStart(t *testing.T) {
	buckets := deepSeekSplitTurns([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventSessionTitle, Seq: 1, Data: json.RawMessage(`{"title":"x"}`)},
		{Type: deepSeekEventAssistantMessage, Seq: 2, Data: json.RawMessage(`{"step":0,"content":[{"type":"text","text":"orphan"}]}`)},
		{Type: deepSeekEventTurnStart, Seq: 3, Data: json.RawMessage(`{"turn":1}`)},
	})
	if len(buckets) != 1 || buckets[0].Turn != 1 {
		t.Fatalf("首轮之前的记录不应产生桶：%+v", buckets)
	}
	if len(buckets[0].Records) != 1 {
		t.Fatalf("第一轮记录数 = %d, want 1：%+v", len(buckets[0].Records), buckets[0])
	}
}

// turn/end 先于任何 turn/start 出现时，状态仍要能被表达出来，不能静默丢弃。
func TestDeepSeekSplitTurnsKeepsOrphanTurnEnd(t *testing.T) {
	buckets := deepSeekSplitTurns([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnEnd, Seq: 1, Data: json.RawMessage(`{"turn":9,"reason":{"kind":"failed"}}`)},
	})
	if len(buckets) != 1 {
		t.Fatalf("孤立的 turn/end 应自成一组，得到 %d 组", len(buckets))
	}
	if buckets[0].Turn != 9 || !buckets[0].Ended || buckets[0].Reason != "failed" {
		t.Fatalf("孤立 turn/end 的状态不符：%+v", buckets[0])
	}
}

// 无法解析的 turn/start 不能让切分错位：跳过它，不要让后续记录落进错误的桶。
func TestDeepSeekSplitTurnsSkipsMalformedTurnStart(t *testing.T) {
	buckets := deepSeekSplitTurns([]harnessclient.SessionWireEvent{
		{Type: deepSeekEventTurnStart, Seq: 1, Data: json.RawMessage(`{"turn":`)},
		{Type: deepSeekEventTurnStart, Seq: 2, Data: json.RawMessage(`{"turn":1}`)},
		{Type: deepSeekEventUserMessage, Seq: 3, Data: json.RawMessage(`{"id":"u1"}`)},
	})
	if len(buckets) != 1 || buckets[0].Turn != 1 {
		t.Fatalf("损坏的 turn/start 不应产生桶：%+v", buckets)
	}
	if len(buckets[0].Records) != 2 {
		t.Fatalf("记录数 = %d, want 2", len(buckets[0].Records))
	}
}

// thread/list 的 limit 上限是 Mimi 协议的 50。
func TestDeepSeekListLimitCapsAtProtocolMaximum(t *testing.T) {
	tests := []struct {
		params map[string]any
		want   int
	}{
		{params: map[string]any{}, want: 20},
		{params: map[string]any{"limit": json.Number("0")}, want: 20},
		{params: map[string]any{"limit": json.Number("5")}, want: 5},
		{params: map[string]any{"limit": json.Number("50")}, want: 50},
		{params: map[string]any{"limit": json.Number("500")}, want: 50},
		// 非法类型按缺省处理，不 panic。
		{params: map[string]any{"limit": "many"}, want: 20},
	}
	for _, test := range tests {
		if got := deepSeekListLimit(test.params); got != test.want {
			t.Fatalf("params=%v → %d, want %d", test.params, got, test.want)
		}
	}
}

// turn 页的 limit 上限同样是 200：上游不接受任意大的 maxMessages。
func TestDeepSeekTurnListLimitCapsAtProtocolMaximum(t *testing.T) {
	tests := []struct {
		params map[string]any
		want   int
	}{
		{params: map[string]any{}, want: 0},
		{params: map[string]any{"limit": json.Number("25")}, want: 25},
		{params: map[string]any{"limit": json.Number("200")}, want: 200},
		{params: map[string]any{"limit": json.Number("9999")}, want: 200},
		{params: map[string]any{"limit": json.Number("-4")}, want: -4},
	}
	for _, test := range tests {
		if got := deepSeekTurnListLimit(test.params); got != test.want {
			t.Fatalf("params=%v → %d, want %d", test.params, got, test.want)
		}
	}
}

// turn id 与 Harness 的数字 turn 的互转只认自己的形状。
func TestDeepSeekTurnNumberRejectsMalformedIdentifiers(t *testing.T) {
	for raw, want := range map[string]int64{"t0": 0, "t1": 1, "t42": 42} {
		got, ok := deepSeekTurnNumber(raw)
		if !ok || got != want {
			t.Fatalf("turnID=%q → (%d,%v), want (%d,true)", raw, got, ok, want)
		}
	}
	for _, raw := range []string{"", "  ", "1", "turn-1", "tx", "t1x", "T1", "tt1"} {
		if got, ok := deepSeekTurnNumber(raw); ok {
			t.Fatalf("turnID=%q 不应被接受，得到 %d", raw, got)
		}
	}
}

// 分页结果必须始终带 nextCursor 键（可为 null）：缺键会让 iOS 把整页判为无效响应。
func TestDeepSeekPageResultAlwaysCarriesNextCursorKey(t *testing.T) {
	for _, nextOffset := range []int{0, 40} {
		raw, err := json.Marshal(deepSeekPageResult([]any{map[string]any{"id": "t1"}}, nextOffset, nextOffset > 0))
		if err != nil {
			t.Fatalf("序列化失败：%v", err)
		}
		var decoded map[string]json.RawMessage
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("反序列化失败：%v", err)
		}
		cursor, ok := decoded["nextCursor"]
		if !ok {
			t.Fatalf("nextOffset=%d 的结果缺少 nextCursor 键：%s", nextOffset, raw)
		}
		if nextOffset == 0 && string(cursor) != "null" {
			t.Fatalf("没有下一页时 nextCursor 必须是 null，得到 %s", cursor)
		}
		if nextOffset > 0 && string(cursor) == "null" {
			t.Fatalf("有下一页时 nextCursor 不能为 null：%s", raw)
		}
	}
}

// 非文本输入必须 fail closed。静默丢弃会让用户以为附件已经发出去。
func TestDeepSeekPromptContentRejectsNonTextInput(t *testing.T) {
	valid, ok := deepSeekPromptContent([]any{map[string]any{"type": "text", "text": "hello"}})
	if !ok || len(valid) != 1 || valid[0].Text != "hello" {
		t.Fatalf("纯文本输入应被接受：%+v ok=%v", valid, ok)
	}

	rejected := map[string]any{
		"image input":     []any{map[string]any{"type": "image", "url": "https://example.invalid/a.png"}},
		"local image":     []any{map[string]any{"type": "localImage", "path": "/tmp/a.png"}},
		"missing type":    []any{map[string]any{"text": "hello"}},
		"mixed":           []any{map[string]any{"type": "text", "text": "hi"}, map[string]any{"type": "image", "url": "u"}},
		"empty text":      []any{map[string]any{"type": "text", "text": "   "}},
		"empty array":     []any{},
		"not an array":    map[string]any{"type": "text"},
		"string entry":    []any{"hello"},
		"nil":             nil,
		"missing content": []any{map[string]any{"type": "text"}},
	}
	for name, input := range rejected {
		t.Run(name, func(t *testing.T) {
			if _, ok := deepSeekPromptContent(input); ok {
				t.Fatalf("输入 %v 不应被接受", input)
			}
		})
	}
}

// 多条文本输入要拼接成一份完整回显。
func TestDeepSeekPromptJoinConcatenatesTextParts(t *testing.T) {
	joined := deepSeekPromptJoin([]harnessclient.PromptContent{
		{Type: "text", Text: "first"},
		{Type: "text", Text: "  "},
		{Type: "text", Text: "second"},
	})
	if joined != "first\nsecond" {
		t.Fatalf("拼接结果 = %q", joined)
	}
	if deepSeekPromptJoin(nil) != "" {
		t.Fatal("空输入应拼出空串")
	}
}

// 用户消息必须回显 clientId，否则 iOS 会整条丢弃乐观消息的对账依据。
func TestDeepSeekUserMessageItemEchoesClientID(t *testing.T) {
	item, ok := deepSeekUserMessageItem(json.RawMessage(
		`{"id":"msg-1","content":[{"type":"text","text":"hi"}],"source":{"rpcId":"rpc-9"}}`))
	if !ok {
		t.Fatal("合法用户消息应能投影")
	}
	if item["id"] != "u:msg-1" || item["type"] != deepSeekItemUserMessage {
		t.Fatalf("item 标识不符：%+v", item)
	}
	if item["clientId"] != "rpc-9" {
		t.Fatalf("clientId 必须回显 source.rpcId：%+v", item)
	}

	// 没有 id 的记录无法建立稳定 item，必须跳过。
	if _, ok := deepSeekUserMessageItem(json.RawMessage(`{"content":[{"type":"text","text":"hi"}]}`)); ok {
		t.Fatal("缺少 id 的用户消息不应被投影")
	}
	if _, ok := deepSeekUserMessageItem(json.RawMessage(`{"id":"msg-2","content":[]}`)); ok {
		t.Fatal("没有正文的用户消息不应被投影")
	}
}

// 模型目录只转发 Harness 自己声明的模型与推理档位，不替用户推断供应商。
func TestDeepSeekModelListWireFlattensGroupsAndReasoning(t *testing.T) {
	rows := deepSeekModelListWire(harnessclient.ModelCatalogResult{
		Groups: []harnessclient.ModelCatalogGroup{{
			ID:   "ark-plan",
			Name: "方舟套餐",
			Models: []harnessclient.ModelEntry{{
				ID:   "deepseek-v4-pro",
				Name: "V4 Pro",
				Reasoning: &harnessclient.ModelReasoning{
					Efforts:       []harnessclient.ModelReasoningEffort{{ID: "high", Name: "高"}},
					DefaultEffort: "high",
				},
			}},
		}},
	})
	if len(rows) != 1 {
		t.Fatalf("模型行数 = %d, want 1", len(rows))
	}
	row, _ := rows[0].(map[string]any)
	if row["id"] != "deepseek-v4-pro" || row["provider"] != "ark-plan" {
		t.Fatalf("模型行标识不符：%+v", row)
	}
	// 模型自己的 name 优先于分组 name。
	if row["displayName"] != "V4 Pro" {
		t.Fatalf("displayName = %v", row["displayName"])
	}
	efforts, _ := row["reasoningEfforts"].([]any)
	if len(efforts) != 1 || row["defaultReasoningEffort"] != "high" {
		t.Fatalf("推理档位未转发：%+v", row)
	}

	// 没有模型自己的 name 时回退到分组名。
	fallback := deepSeekModelListWire(harnessclient.ModelCatalogResult{
		Groups: []harnessclient.ModelCatalogGroup{{
			ID:     "g",
			Name:   "Group Name",
			Models: []harnessclient.ModelEntry{{ID: "m"}},
		}},
	})
	row, _ = fallback[0].(map[string]any)
	if row["displayName"] != "Group Name" {
		t.Fatalf("缺少模型名时应回退到分组名：%+v", row)
	}
	if _, present := row["reasoningEfforts"]; present {
		t.Fatalf("没有推理档位时不应凭空生成：%+v", row)
	}
}

// 会话摘要投影成 thread 时，status 只区分"在跑"与"未加载"，空标题不下发 name。
func TestDeepSeekThreadWireMapsStatusAndOptionalFields(t *testing.T) {
	running := deepSeekThreadWire(harnessclient.SessionSummary{
		SessionID: "s1",
		CWD:       "/workspace/demo",
		UpdatedAt: 1700000000000,
		Running:   true,
	}, nil, false)
	if running["status"] != "running" || running["cwd"] != "/workspace/demo" {
		t.Fatalf("运行中会话投影不符：%+v", running)
	}
	if _, present := running["name"]; present {
		t.Fatalf("没有投影标题时不应下发 name：%+v", running)
	}
	if _, present := running["turns"]; present {
		t.Fatalf("includeTurns=false 时不应带 turns：%+v", running)
	}

	idle := deepSeekThreadWire(harnessclient.SessionSummary{
		SessionID: "s2",
		Projections: &harnessclient.SessionProjectionHints{
			Values: harnessclient.SessionProjectionValue{
				Title:       "  修复登录  ",
				TurnOutline: []harnessclient.SessionTurnOutline{{Turn: 1, Prompt: "第一个问题"}},
			},
		},
	}, nil, false)
	if idle["status"] != "notLoaded" {
		t.Fatalf("未运行会话应报 notLoaded：%+v", idle)
	}
	if idle["name"] != "修复登录" {
		t.Fatalf("标题应去除空白：%v", idle["name"])
	}
	if idle["preview"] != "第一个问题" {
		t.Fatalf("轮次大纲应作为预览：%v", idle["preview"])
	}
}

// ---------------------------------------------------------------- 状态与 channel

// 状态文案不得泄漏 token 文件路径。channel 会下发到移动端。
func TestAppServerDeepSeekStatusNeverLeaksTokenFilePath(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "very-secret-location", "deepseek.token")
	status := appServerDeepSeekStatusFor(config.DeepSeekConfig{
		Enabled:   true,
		BaseURL:   "http://127.0.0.1:5173",
		TokenFile: missing,
	})
	if status.Status != deepSeekStatusCredential || status.Healthy {
		t.Fatalf("凭据不可读时应报 credential_unavailable：%+v", status)
	}
	if strings.Contains(status.Fix, missing) || strings.Contains(status.Fix, "very-secret-location") {
		t.Fatalf("修复建议不得包含本机路径：%q", status.Fix)
	}
}

func TestAppServerDeepSeekStatusStates(t *testing.T) {
	t.Run("disabled", func(t *testing.T) {
		status := appServerDeepSeekStatusFor(config.DeepSeekConfig{Enabled: false})
		if status.Status != deepSeekStatusDisabled || status.Healthy {
			t.Fatalf("未启用应报 disabled：%+v", status)
		}
	})

	t.Run("unconfigured without base url", func(t *testing.T) {
		tokenFile := writeDeepSeekTestTokenFile(t, "startup-token")
		status := appServerDeepSeekStatusFor(config.DeepSeekConfig{Enabled: true, TokenFile: tokenFile})
		if status.Status != deepSeekStatusUnconfigured || status.Healthy {
			t.Fatalf("缺少地址应报 unconfigured：%+v", status)
		}
	})

	t.Run("unconfigured with plaintext non loopback", func(t *testing.T) {
		tokenFile := writeDeepSeekTestTokenFile(t, "startup-token")
		status := appServerDeepSeekStatusFor(config.DeepSeekConfig{
			Enabled:   true,
			BaseURL:   "http://10.0.0.5:5173",
			TokenFile: tokenFile,
		})
		if status.Healthy {
			t.Fatalf("明文 HTTP 非回环地址不得判为就绪：%+v", status)
		}
	})

	t.Run("ready", func(t *testing.T) {
		tokenFile := writeDeepSeekTestTokenFile(t, "startup-token")
		status := appServerDeepSeekStatusFor(config.DeepSeekConfig{
			Enabled:   true,
			BaseURL:   "http://127.0.0.1:5173",
			TokenFile: tokenFile,
		})
		if status.Status != deepSeekStatusReady || !status.Healthy {
			t.Fatalf("地址与凭据齐备应判就绪：%+v", status)
		}
		if status.Fix != "" {
			t.Fatalf("就绪时不应给修复建议：%q", status.Fix)
		}
	})
}

// channel 只在 deepseek.enabled 时出现，且只给状态与修复建议，不给本机 endpoint 与凭据路径。
func TestAppServerChannelsDeclareDeepSeekOnlyWhenEnabled(t *testing.T) {
	t.Run("disabled", func(t *testing.T) {
		server := newTestServer(t)
		httpServer := httptest.NewServer(server.handler)
		defer httpServer.Close()

		body := fetchAppServerConfig(t, httpServer.URL)
		if channel := findAppServerChannel(body, appServerRuntimeDeepSeekID); channel != nil {
			t.Fatalf("未启用时不应声明 DeepSeek channel：%+v", channel)
		}
	})

	t.Run("enabled without credentials", func(t *testing.T) {
		server := newTestServerWithConfig(t, func(cfg *config.Config) {
			cfg.DeepSeek.Enabled = true
			cfg.DeepSeek.BaseURL = "http://127.0.0.1:5173"
			cfg.DeepSeek.TokenFile = filepath.Join(t.TempDir(), "absent.token")
		})
		httpServer := httptest.NewServer(server.handler)
		defer httpServer.Close()

		channel := findAppServerChannel(fetchAppServerConfig(t, httpServer.URL), appServerRuntimeDeepSeekID)
		if channel == nil {
			t.Fatal("启用后必须声明 DeepSeek channel")
		}
		if channel["gateway_available"] != false {
			t.Fatalf("凭据不可读时 channel 不得标为可用：%+v", channel)
		}
		bridge, _ := channel["bridge"].(map[string]any)
		if bridge["status"] != deepSeekStatusCredential {
			t.Fatalf("bridge 状态应为 credential_unavailable：%+v", bridge)
		}
	})

	t.Run("enabled and ready", func(t *testing.T) {
		tokenFile := writeDeepSeekTestTokenFile(t, "startup-token")
		server := newTestServerWithConfig(t, func(cfg *config.Config) {
			cfg.DeepSeek.Enabled = true
			cfg.DeepSeek.BaseURL = "http://127.0.0.1:5173"
			cfg.DeepSeek.TokenFile = tokenFile
		})
		httpServer := httptest.NewServer(server.handler)
		defer httpServer.Close()

		channel := findAppServerChannel(fetchAppServerConfig(t, httpServer.URL), appServerRuntimeDeepSeekID)
		if channel == nil {
			t.Fatal("启用后必须声明 DeepSeek channel")
		}
		if channel["gateway_available"] != true {
			t.Fatalf("就绪时 channel 应标为可用：%+v", channel)
		}
		// channel 会下发到移动端，本机 endpoint 与凭据路径不属于它需要知道的运行态。
		serialized, err := json.Marshal(channel)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(serialized), tokenFile) {
			t.Fatalf("channel 不得包含 token 文件路径：%s", serialized)
		}
		if strings.Contains(string(serialized), "5173") {
			t.Fatalf("channel 不得包含本机 Harness 地址：%s", serialized)
		}
	})
}

// ---------------------------------------------------------------- 网关接线

// 普通 GET 不应触发一次对 Harness 的认证：先确认升级意图再继续。
func TestDeepSeekGatewayRejectsPlainGETWithoutUpgrade(t *testing.T) {
	server := newTestServer(t)
	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	req, err := http.NewRequest(http.MethodGet, httpServer.URL+appServerGatewayPath+"?runtime=deepseek", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("非升级请求应返回 400，得到 %d", response.StatusCode)
	}
}

// 未启用时必须在下发认证前就拒绝，并给出稳定错误码。
func TestDeepSeekGatewayRefusesWhenDisabled(t *testing.T) {
	server := newTestServer(t)
	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	frame := readDeepSeekGatewayFrame(t, conn)
	if code := deepSeekFrameErrorCode(t, frame); code != deepSeekCodeDisabled {
		t.Fatalf("未启用时应回 %s，得到 %q（帧：%s）", deepSeekCodeDisabled, code, frame)
	}
}

// 地址不可用时给出 unconfigured，而不是把本机配置细节带出去。
func TestDeepSeekGatewayReportsUnconfiguredAddress(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = "http://10.0.0.5:5173"
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, "startup-token")
	})
	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	frame := readDeepSeekGatewayFrame(t, conn)
	if code := deepSeekFrameErrorCode(t, frame); code != deepSeekCodeUnconfigured {
		t.Fatalf("地址不可用时应回 %s，得到 %q（帧：%s）", deepSeekCodeUnconfigured, code, frame)
	}
}

// 凭据不可读时只给可操作文案：错误帧里不得出现本机路径。
func TestDeepSeekGatewayCredentialFailureDoesNotLeakPath(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "vault", "deepseek.token")
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = "http://127.0.0.1:5173"
		cfg.DeepSeek.TokenFile = missing
	})
	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	frame := readDeepSeekGatewayFrame(t, conn)
	if code := deepSeekFrameErrorCode(t, frame); code != deepSeekCodeCredentials {
		t.Fatalf("凭据不可读时应回 %s，得到 %q（帧：%s）", deepSeekCodeCredentials, code, frame)
	}
	if strings.Contains(string(frame), "vault") {
		t.Fatalf("错误帧不得包含本机路径：%s", frame)
	}
}

// Harness 不可达时，错误帧不得出现启动 token —— 传输层错误里可能包着带查询串的 URL。
func TestDeepSeekGatewayAuthFailureNeverLeaksStartupToken(t *testing.T) {
	const secret = "startup-token-must-not-leak-9f3a"

	// 取一个已被释放的端口：连接必然失败，且错误里会带上请求 URL。
	probe := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	baseURL := probe.URL
	probe.Close()

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = baseURL
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, secret)
	})
	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	frame := readDeepSeekGatewayFrame(t, conn)
	if code := deepSeekFrameErrorCode(t, frame); code != deepSeekCodeAuthFailed {
		t.Fatalf("认证失败时应回 %s，得到 %q（帧：%s）", deepSeekCodeAuthFailed, code, frame)
	}
	if strings.Contains(string(frame), secret) {
		t.Fatalf("错误帧泄漏了启动 token：%s", frame)
	}
}

// 会话名额用尽时要给稳定错误码，而不是静默失败或无限等待。
func TestDeepSeekSessionSlotsAreBoundedAndReleased(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = "http://127.0.0.1:5173"
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, "startup-token")
		cfg.DeepSeek.MaxConcurrentSessions = 2
	})
	router := server.router

	for index := 0; index < 2; index++ {
		if !router.acquireDeepSeekSession() {
			t.Fatalf("第 %d 个名额应可获取", index+1)
		}
	}
	if router.acquireDeepSeekSession() {
		t.Fatal("超出 max_concurrent_sessions 后应拒绝")
	}
	router.releaseDeepSeekSession()
	if !router.acquireDeepSeekSession() {
		t.Fatal("归还后应能重新获取")
	}

	// 上限缺省时回退到默认值，不能变成 0 导致全部拒绝。
	bare := newTestServer(t)
	bare.router.cfg.DeepSeek.MaxConcurrentSessions = 0
	if !bare.router.acquireDeepSeekSession() {
		t.Fatal("未配置上限时应回退到默认值而不是拒绝")
	}

	// 多余归还不能把计数减成负数，否则上限会被永久放大。
	router.releaseDeepSeekSession()
	router.releaseDeepSeekSession()
	router.releaseDeepSeekSession()
	if !router.acquireDeepSeekSession() {
		t.Fatal("多余归还后仍应能获取名额")
	}
}

// ---------------------------------------------------------------- 端到端

// 用假 Harness 走通完整链路：认证、$events ready、方法分发与结果投影。
func TestDeepSeekGatewayServesAppServerMethodsAgainstHarness(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"items": []any{
			map[string]any{
				"sessionId": "s-visible",
				"cwd":       harness.workspace,
				"updatedAt": 1700000000000,
				"projections": map[string]any{
					"values": map[string]any{"title": "已授权会话"},
				},
			},
			// 会话列表不按目录过滤，授权裁剪必须由 agentd 完成。
			map[string]any{"sessionId": "s-outside", "cwd": "/elsewhere", "updatedAt": 1700000000001},
			// 没有 cwd 的会话无法证明属于授权工作区，必须 fail closed。
			map[string]any{"sessionId": "s-nocwd", "updatedAt": 1700000000002},
			// 空会话在 Mimi 里不展示。
			map[string]any{"sessionId": "s-blank", "cwd": harness.workspace, "blank": true, "updatedAt": 1700000000003},
		}}, nil
	})
	harness.handle(harnessclient.MethodSessionModelCatalog, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"groups": []any{
			map[string]any{
				"id":   "ark-plan",
				"name": "方舟套餐",
				"models": []any{
					map[string]any{"id": "deepseek-v4-pro", "name": "V4 Pro"},
				},
			},
		}}, nil
	})
	harness.handle(harnessclient.MethodSessionCreate, func(args json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"sessionId": "s-created", "agentPreset": "default"}, nil
	})
	harnessServer := harness.serve()

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = harnessServer.URL
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, harness.token)
	})
	// 假 Harness 的会话必须落在 agentd 的授权目录里，否则会被正确裁掉。
	harness.setWorkspace(server.router.cfg.Projects[0].Path)

	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	t.Run("initialize advertises the runtime family", func(t *testing.T) {
		result := callDeepSeekGateway(t, conn, 1, "initialize", map[string]any{})
		if result["platformFamily"] != "macos" {
			t.Fatalf("initialize 应答不符：%+v", result)
		}
	})

	t.Run("thread/list trims to the authorized workspace", func(t *testing.T) {
		result := callDeepSeekGateway(t, conn, 2, "thread/list", map[string]any{
			"cwd": server.router.cfg.Projects[0].Path,
		})
		rows, _ := result["data"].([]any)
		if len(rows) != 1 {
			t.Fatalf("授权裁剪后应只剩 1 条会话，得到 %d 条：%+v", len(rows), rows)
		}
		row, _ := rows[0].(map[string]any)
		if row["id"] != "s-visible" {
			t.Fatalf("可见会话不符：%+v", row)
		}
		if row["name"] != "已授权会话" {
			t.Fatalf("会话标题应投影为 name：%+v", row)
		}
		// 未运行的会话报告为未加载，Mimi 侧归入历史。
		if row["status"] != "notLoaded" {
			t.Fatalf("会话状态不符：%+v", row)
		}
		if _, present := result["nextCursor"]; !present {
			t.Fatalf("分页结果必须带 nextCursor 键：%+v", result)
		}
	})

	t.Run("thread/list rejects a cwd outside the allowlist", func(t *testing.T) {
		code, _ := callDeepSeekGatewayError(t, conn, 3, "thread/list", map[string]any{"cwd": "/not/authorized"})
		if code == 0 {
			t.Fatal("越权 cwd 必须被拒绝")
		}
	})

	t.Run("thread/list requires a cwd", func(t *testing.T) {
		code, _ := callDeepSeekGatewayError(t, conn, 4, "thread/list", map[string]any{})
		if code == 0 {
			t.Fatal("缺少 cwd 的 thread/list 必须被拒绝")
		}
	})

	t.Run("model/list forwards the harness catalog", func(t *testing.T) {
		result := callDeepSeekGateway(t, conn, 5, "model/list", map[string]any{})
		rows, _ := result["data"].([]any)
		if len(rows) != 1 {
			t.Fatalf("模型行数 = %d, want 1：%+v", len(rows), rows)
		}
		row, _ := rows[0].(map[string]any)
		if row["id"] != "deepseek-v4-pro" || row["provider"] != "ark-plan" {
			t.Fatalf("模型行不符：%+v", row)
		}
	})

	t.Run("thread/start creates and subscribes", func(t *testing.T) {
		result := callDeepSeekGateway(t, conn, 6, "thread/start", map[string]any{
			"cwd": server.router.cfg.Projects[0].Path,
		})
		thread, _ := result["thread"].(map[string]any)
		if thread == nil || thread["id"] != "s-created" {
			t.Fatalf("thread/start 应答不符：%+v", result)
		}
		// 新建后必须已经订阅：没有订阅就收不到后续 turn 与直播帧。
		if opened := harness.openedEndpoints(); !containsString(opened, harnessclient.MethodSessionFollow) {
			t.Fatalf("thread/start 后应建立会话订阅，已打开的订阅：%v", opened)
		}
	})

	t.Run("unknown methods are refused", func(t *testing.T) {
		code, _ := callDeepSeekGatewayError(t, conn, 7, "thread/archive", map[string]any{})
		if code == 0 {
			t.Fatal("白名单外的方法必须被拒绝")
		}
	})

	// 启动 token 只能用于换取 Cookie：任何一次 RPC 都不得携带它。
	for _, call := range harness.recorded() {
		if strings.Contains(call.Cookie, harness.token) {
			t.Fatalf("启动 token 出现在 RPC 凭据里：%q", call.Cookie)
		}
		if strings.Contains(call.RequestURI, harness.token) {
			t.Fatalf("启动 token 出现在 RPC 请求行里：%s", call.RequestURI)
		}
	}
	if !harness.sawAuthHandshake() {
		t.Fatal("应完成一次 token 换 Cookie 的认证握手")
	}
}

// 回归：thread/start 成功之后，同一个连接必须能立刻继续发消息、读历史、中断。
//
// 这是产品必经路径，而它曾经是断的：适配层把翻译后的响应直接写回移动端，没有经过
// appServerGatewayPolicy 的响应侧处理，于是 thread/start 返回的新线程从未被登记进
// 授权表，紧随其后的 turn/start 被判成"未授权 thread"。用户看到的现象是
// 「会话建好了，但发不出第一条消息」，而且不是网络错误，重试也不会好。
//
// 这里刻意不预置任何授权记录，只走真实的 create → prompt → read → interrupt 链。
func TestDeepSeekGatewayAuthorizesCreatedThreadForTurns(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"items": []any{}}, nil
	})
	harness.handle(harnessclient.MethodSessionCreate, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"sessionId": "s-new", "agentPreset": "default"}, nil
	})

	// 订阅连接要由测试自己持有，才能在 prompt 之后推一条属于本次投递的 turn/start。
	//
	// onOpen 会完全接管开场帧（handleOpen 见到它就 return），所以两个 endpoint 都要
	// 自己回：漏掉 $events 的 ready，网关会停在「等 clientId」上，整条连接报事件流不可用。
	var mu sync.Mutex
	var followConn *websocket.Conn
	var prompts []map[string]any
	harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
		switch endpoint, _ := open["endpoint"].(string); endpoint {
		case harnessclient.EndpointEvents:
			return writeDeepSeekMuxValue(conn, "", map[string]any{
				"type":     "ready",
				"clientId": "client-fixture",
			})
		case harnessclient.MethodSessionFollow:
			mu.Lock()
			followConn = conn
			mu.Unlock()
			// 空快照：新会话还没有任何轮次。
			return writeDeepSeekMuxValue(conn, "", map[string]any{
				"type":    "snapshot",
				"cursor":  12,
				"header":  map[string]any{"id": "s-new"},
				"records": []any{},
			})
		}
		return nil
	}
	harness.handle(harnessclient.MethodSessionPrompt, func(args json.RawMessage) (any, *harnessclient.RemoteError) {
		// prompt 的参数是 {"request": {...}}，与 harnessclient.Prompt 的信封一致。
		var envelope struct {
			Request map[string]any `json:"request"`
		}
		if err := json.Unmarshal(args, &envelope); err != nil {
			return nil, &harnessclient.RemoteError{Code: "gateway/bad-request", Message: err.Error()}
		}
		mu.Lock()
		prompts = append(prompts, envelope.Request)
		conn := followConn
		mu.Unlock()
		// 真实 Harness 在收到投递后才把新轮次写进会话日志，这里照此回放：
		// turn/start 开出轮次，user/message 把 source.rpcId 记成 prompt 的 requestId。
		// 后者是"这一轮属于哪次投递"的唯一判据，缺了它本次 ACK 拿不到 turn id。
		if conn != nil {
			_ = writeDeepSeekMuxValue(conn, "", map[string]any{
				"type": "event",
				"event": map[string]any{
					"type": "turn/start",
					"seq":  13,
					"data": map[string]any{"turn": 2},
				},
			})
			_ = writeDeepSeekMuxValue(conn, "", map[string]any{
				"type": "event",
				"event": map[string]any{
					"type": "user/message",
					"seq":  14,
					"data": map[string]any{
						"id":      "um-1",
						"role":    "user",
						"content": []any{map[string]any{"type": "text", "text": "你好"}},
						"source":  map[string]any{"kind": "user", "rpcId": envelope.Request["requestId"]},
					},
				},
			})
		}
		return map[string]any{"accepted": true}, nil
	})
	harness.handle(harnessclient.MethodSessionCancel, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"accepted": true}, nil
	})

	harnessServer := harness.serve()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = harnessServer.URL
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, harness.token)
	})
	workspace := server.router.cfg.Projects[0].Path

	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	callDeepSeekGateway(t, conn, 1, "initialize", map[string]any{})

	start := callDeepSeekGateway(t, conn, 2, "thread/start", map[string]any{"cwd": workspace})
	thread, _ := start["thread"].(map[string]any)
	if thread == nil || thread["id"] != "s-new" {
		t.Fatalf("thread/start 应答不符：%+v", start)
	}

	// 关键断言：不预置授权，也要能对刚创建的线程发消息。
	turn := callDeepSeekGateway(t, conn, 3, "turn/start", map[string]any{
		"threadId":            "s-new",
		"cwd":                 workspace,
		"clientUserMessageId": "msg-1",
		"input":               []any{map[string]any{"type": "text", "text": "你好"}},
	})
	turnInfo, _ := turn["turn"].(map[string]any)
	if turnInfo == nil {
		t.Fatalf("turn/start 应答缺少 turn：%+v", turn)
	}
	if turnInfo["id"] != "t2" {
		t.Fatalf("turn id 应来自本次投递对应的 turn/start 事件：%+v", turnInfo)
	}

	mu.Lock()
	delivered := append([]map[string]any(nil), prompts...)
	mu.Unlock()
	if len(delivered) != 1 {
		t.Fatalf("应恰好投递一次 prompt，得到 %d 次", len(delivered))
	}
	if delivered[0]["sessionId"] != "s-new" {
		t.Fatalf("prompt 应投递到新建会话：%+v", delivered[0])
	}
	if delivered[0]["requestId"] != "msg-1" {
		t.Fatalf("prompt 的 requestId 必须复用客户端 clientUserMessageId：%+v", delivered[0])
	}

	// 历史回读与中断同样依赖该线程已授权。
	if _, err := callDeepSeekGatewayNoFatal(conn, 4, "thread/turns/list", map[string]any{
		"threadId": "s-new",
	}); err != nil {
		t.Fatalf("新建线程应可读历史：%v", err)
	}
	callDeepSeekGateway(t, conn, 5, "turn/interrupt", map[string]any{"threadId": "s-new"})
}

// 回归：thread/search 的结果必须带 cwd 与 snippet。
//
// 两个独立问题都落在这个形状上：iOS 的 threadSearchPage 逐行要求
// {thread: {…cwd…}, snippet}，缺任一项会抛 invalidResponse 让整页搜索失败；
// 而 cwd 同时是 policy 裁剪搜索结果的唯一判据——Harness 的检索结果不带 cwd，
// 请求侧也没有 cwd 可比。缺了它，未授权工作区的会话摘要会直接下发到移动端。
func TestDeepSeekGatewaySearchRowsCarryCWDAndTrimUnauthorized(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"items": []any{
			map[string]any{
				"sessionId": "s-inside",
				"cwd":       harness.workspace,
				"updatedAt": 1700000000000,
				"projections": map[string]any{
					"values": map[string]any{"title": "授权会话"},
				},
			},
			map[string]any{"sessionId": "s-outside", "cwd": "/elsewhere", "updatedAt": 1700000000001},
		}}, nil
	})
	// 检索索引覆盖本机全部会话，命中里会同时出现授权与未授权的会话。
	harness.handle(harnessclient.MethodSessionSearch, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"items": []any{
			map[string]any{"sessionId": "s-inside", "snippet": "命中片段"},
			map[string]any{"sessionId": "s-outside", "snippet": "越权命中"},
			map[string]any{"sessionId": "s-unknown", "snippet": "列表里没有的会话"},
		}}, nil
	})

	harnessServer := harness.serve()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = harnessServer.URL
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, harness.token)
	})
	harness.setWorkspace(server.router.cfg.Projects[0].Path)

	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	callDeepSeekGateway(t, conn, 1, "initialize", map[string]any{})
	result := callDeepSeekGateway(t, conn, 2, "thread/search", map[string]any{"searchTerm": "命中"})

	rows, _ := result["data"].([]any)
	if len(rows) != 1 {
		t.Fatalf("只应留下授权工作区内的命中，得到 %d 条：%+v", len(rows), rows)
	}
	row, _ := rows[0].(map[string]any)
	if row["snippet"] != "命中片段" {
		t.Fatalf("搜索结果行必须带 snippet：%+v", row)
	}
	thread, ok := row["thread"].(map[string]any)
	if !ok {
		t.Fatalf("搜索结果行必须以 thread 承载会话，否则 iOS 会整页判为无效：%+v", row)
	}
	if thread["id"] != "s-inside" {
		t.Fatalf("命中会话不符：%+v", thread)
	}
	if thread["cwd"] != server.router.cfg.Projects[0].Path {
		t.Fatalf("thread 必须带 cwd，否则无法证明归属且 iOS 会丢弃该行：%+v", thread)
	}
	if _, present := result["nextCursor"]; !present {
		t.Fatalf("分页结果必须带 nextCursor 键：%+v", result)
	}
}

// callDeepSeekGatewayNoFatal 与 callDeepSeekGateway 同路，但把拒绝也返回给调用方。
func callDeepSeekGatewayNoFatal(conn *websocket.Conn, id int, method string, params map[string]any) (map[string]any, error) {
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  method,
		"params":  params,
	})
	if err != nil {
		return nil, err
	}
	if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
		return nil, err
	}
	if err := conn.SetReadDeadline(time.Now().Add(20 * time.Second)); err != nil {
		return nil, err
	}
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return nil, err
		}
		var frame map[string]any
		if err := json.Unmarshal(raw, &frame); err != nil {
			continue
		}
		gotID, ok := frame["id"].(float64)
		if !ok || gotID != float64(id) {
			continue
		}
		if rawError, present := frame["error"].(map[string]any); present {
			message, _ := rawError["message"].(string)
			return nil, fmt.Errorf("%s 被拒绝：%s", method, message)
		}
		result, _ := frame["result"].(map[string]any)
		return result, nil
	}
}

// 事件流拿不到 clientId 时必须失败，而不是带着空 clientId 继续——那会让所有应答静默失效。
func TestDeepSeekGatewayFailsWhenEventsStreamHasNoReady(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
		if open["endpoint"] == harnessclient.EndpointEvents {
			// 只回一条无 clientId 的 ready，让网关在这里停下。
			return writeDeepSeekMuxValue(conn, "", map[string]any{"type": "ready"})
		}
		return nil
	}
	harnessServer := harness.serve()

	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = harnessServer.URL
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, harness.token)
	})
	httpServer := httptest.NewServer(server.handler)
	defer httpServer.Close()

	conn := dialDeepSeekGateway(t, httpServer.URL)
	defer conn.Close()

	frame := readDeepSeekGatewayFrame(t, conn)
	if code := deepSeekFrameErrorCode(t, frame); code != deepSeekCodeEvents {
		t.Fatalf("ready 缺少 clientId 时应回 %s，得到 %q（帧：%s）", deepSeekCodeEvents, code, frame)
	}
}

// ---------------------------------------------------------------- 测试夹具

// writeDeepSeekTestTokenFile 写一个 0600 的 token 文件，返回其路径。
func writeDeepSeekTestTokenFile(t *testing.T, token string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "deepseek.token")
	if err := os.WriteFile(path, []byte(token), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func dialDeepSeekGateway(t *testing.T, serverURL string) *websocket.Conn {
	t.Helper()
	target := wsURL(serverURL, appServerGatewayPath) + "?runtime=deepseek"
	conn, response, err := websocket.DefaultDialer.Dial(target, http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		t.Fatalf("连接 DeepSeek 网关失败：%v", err)
	}
	return conn
}

// readDeepSeekGatewayFrame 读一帧原始报文。
func readDeepSeekGatewayFrame(t *testing.T, conn *websocket.Conn) []byte {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatal(err)
	}
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("读取网关帧失败：%v", err)
	}
	return raw
}

// readDeepSeekGatewayResponse 读到指定 id 的应答，跳过通知与不相关的 id。
func readDeepSeekGatewayResponse(t *testing.T, conn *websocket.Conn, wantID float64) map[string]any {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		raw := readDeepSeekGatewayFrame(t, conn)
		var frame map[string]any
		if err := json.Unmarshal(raw, &frame); err != nil {
			continue
		}
		id, ok := frame["id"].(float64)
		if !ok || id != wantID {
			continue
		}
		return frame
	}
	t.Fatalf("等待 id=%v 的应答超时", wantID)
	return nil
}

// callDeepSeekGateway 发一条请求并返回 result，失败即终止测试。
func callDeepSeekGateway(t *testing.T, conn *websocket.Conn, id int, method string, params map[string]any) map[string]any {
	t.Helper()
	frame := sendDeepSeekGatewayRequest(t, conn, id, method, params)
	if _, present := frame["error"]; present {
		t.Fatalf("%s 返回错误：%+v", method, frame["error"])
	}
	result, ok := frame["result"].(map[string]any)
	if !ok {
		t.Fatalf("%s 的 result 不是对象：%+v", method, frame)
	}
	return result
}

// callDeepSeekGatewayError 发一条请求并返回错误码，期望被拒绝。
func callDeepSeekGatewayError(t *testing.T, conn *websocket.Conn, id int, method string, params map[string]any) (float64, string) {
	t.Helper()
	frame := sendDeepSeekGatewayRequest(t, conn, id, method, params)
	rawError, present := frame["error"].(map[string]any)
	if !present {
		return 0, ""
	}
	code, _ := rawError["code"].(float64)
	message, _ := rawError["message"].(string)
	return code, message
}

func sendDeepSeekGatewayRequest(t *testing.T, conn *websocket.Conn, id int, method string, params map[string]any) map[string]any {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  method,
		"params":  params,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
		t.Fatalf("发送 %s 失败：%v", method, err)
	}
	return readDeepSeekGatewayResponse(t, conn, float64(id))
}

// deepSeekFrameErrorCode 从一帧运行时错误里取出稳定错误码。
func deepSeekFrameErrorCode(t *testing.T, raw []byte) string {
	t.Helper()
	var frame map[string]any
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatalf("解析网关错误帧失败：%v（帧：%s）", err, raw)
	}
	rawError, ok := frame["error"].(map[string]any)
	if !ok {
		t.Fatalf("帧里没有 error 字段：%s", raw)
	}
	data, _ := rawError["data"].(map[string]any)
	code, _ := data["code"].(string)
	return code
}

// fetchAppServerConfig 取 GET app-server config 的响应体。
func fetchAppServerConfig(t *testing.T, serverURL string) map[string]any {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, serverURL+"/api/app-server/config", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+testToken)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("app-server config 返回 %d", response.StatusCode)
	}
	var body map[string]any
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body
}

// findAppServerChannel 在 channels 里按 runtime id 找一条声明。
func findAppServerChannel(body map[string]any, runtimeID string) map[string]any {
	channels, _ := body["channels"].([]any)
	for _, entry := range channels {
		channel, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		if channel["runtime_id"] == runtimeID || channel["id"] == runtimeID {
			return channel
		}
	}
	return nil
}

// deepSeekRecordedCall 记录一次到达假 Harness 的 RPC。
type deepSeekRecordedCall struct {
	Path       string
	RequestURI string
	Cookie     string
	Envelope   map[string]any
}

// fakeDeepSeekHarness 是最小的 Harness 替身：认证握手、Connection RPC、
// remote.mux 订阅。刻意不做业务语义，只保证协议形状与真实 Harness 一致。
type fakeDeepSeekHarness struct {
	t      *testing.T
	token  string
	cookie string

	mu       sync.Mutex
	calls    []deepSeekRecordedCall
	opens    []map[string]any
	handlers map[string]func(json.RawMessage) (any, *harnessclient.RemoteError)
	auth     bool
	// workspace 是假会话所属目录，创建后由测试设置为 agentd 的授权目录。
	workspace string

	// onOpen 在订阅声明后调用，用于按 endpoint 回放帧。
	onOpen func(conn *websocket.Conn, open map[string]any) error
}

func newFakeDeepSeekHarness(t *testing.T) *fakeDeepSeekHarness {
	t.Helper()
	return &fakeDeepSeekHarness{
		t:        t,
		token:    "harness-startup-token-fixture",
		cookie:   "harness_session=cookie-fixture",
		handlers: map[string]func(json.RawMessage) (any, *harnessclient.RemoteError){},
	}
}

func (f *fakeDeepSeekHarness) handle(method string, handler func(json.RawMessage) (any, *harnessclient.RemoteError)) {
	f.handlers[method] = handler
}

func (f *fakeDeepSeekHarness) setWorkspace(path string) {
	f.mu.Lock()
	f.workspace = path
	f.mu.Unlock()
}

func (f *fakeDeepSeekHarness) recorded() []deepSeekRecordedCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]deepSeekRecordedCall(nil), f.calls...)
}

func (f *fakeDeepSeekHarness) openedEndpoints() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	endpoints := make([]string, 0, len(f.opens))
	for _, open := range f.opens {
		endpoint, _ := open["endpoint"].(string)
		endpoints = append(endpoints, endpoint)
	}
	return endpoints
}

func (f *fakeDeepSeekHarness) sawAuthHandshake() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.auth
}

func (f *fakeDeepSeekHarness) serve() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		if r.URL.Query().Get("token") != f.token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		f.mu.Lock()
		f.auth = true
		f.mu.Unlock()
		// 认证是一次 303 握手：普通 API 不接受 Authorization 头，只认这个 Cookie。
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "cookie-fixture", Path: "/"})
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc(harnessclient.GatewayPath(), f.serveMux)
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		if _, err := r.Cookie("harness_session"); err != nil {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		method := strings.TrimPrefix(r.URL.Path, "/api/")
		var envelope map[string]any
		if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.mu.Lock()
		f.calls = append(f.calls, deepSeekRecordedCall{
			Path:       r.URL.Path,
			RequestURI: r.RequestURI,
			Cookie:     r.Header.Get("Cookie"),
			Envelope:   envelope,
		})
		f.mu.Unlock()

		payload, _ := envelope["payload"].(map[string]any)
		rawArgs, _ := json.Marshal(payload["args"])
		handler := f.handlers[method]
		if handler == nil {
			f.writeEnvelope(w, envelope, nil, &harnessclient.RemoteError{Code: "gateway/internal", Message: method})
			return
		}
		value, remoteErr := handler(rawArgs)
		f.writeEnvelope(w, envelope, value, remoteErr)
	})
	server := httptest.NewServer(mux)
	f.t.Cleanup(server.Close)
	return server
}

func (f *fakeDeepSeekHarness) writeEnvelope(
	w http.ResponseWriter,
	envelope map[string]any,
	value any,
	remoteErr *harnessclient.RemoteError,
) {
	rpcID, _ := envelope["rpcId"].(string)
	result := map[string]any{"ok": remoteErr == nil}
	if remoteErr == nil {
		result["value"] = value
	} else {
		result["error"] = remoteErr
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]any{
		"type":   "server-response",
		"rpcId":  rpcID,
		"result": result,
	}); err != nil {
		f.t.Errorf("写出应答失败：%v", err)
	}
}

// serveMux 处理 remote.mux：读取 open 帧后回放对应订阅的开场帧。
func (f *fakeDeepSeekHarness) serveMux(w http.ResponseWriter, r *http.Request) {
	if _, err := r.Cookie("harness_session"); err != nil {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	conn, err := (&websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}).Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer func() { _ = conn.Close() }()

	for {
		if _, raw, err := conn.ReadMessage(); err != nil {
			return
		} else if err := f.handleOpen(conn, raw); err != nil {
			return
		}
	}
}

func (f *fakeDeepSeekHarness) handleOpen(conn *websocket.Conn, raw []byte) error {
	var open map[string]any
	if err := json.Unmarshal(raw, &open); err != nil {
		return err
	}
	f.mu.Lock()
	f.opens = append(f.opens, open)
	f.mu.Unlock()

	if f.onOpen != nil {
		return f.onOpen(conn, open)
	}
	endpoint, _ := open["endpoint"].(string)
	switch endpoint {
	case harnessclient.EndpointEvents:
		return writeDeepSeekMuxValue(conn, "", map[string]any{
			"type":     "ready",
			"clientId": "client-fixture",
		})
	case harnessclient.MethodSessionFollow:
		// 开场快照给出 cursor（= 分页切点）且声明没有更早的记录。
		return writeDeepSeekMuxValue(conn, "", map[string]any{
			"type":   "snapshot",
			"cursor": 12,
			"header": map[string]any{"id": "s-fixture"},
			"records": []any{
				map[string]any{
					"type": "event",
					"event": map[string]any{
						"type": "turn/start",
						"seq":  1,
						"data": map[string]any{"turn": 1},
					},
				},
			},
		})
	}
	return nil
}

func writeDeepSeekMuxValue(conn *websocket.Conn, streamID string, value any) error {
	raw, err := json.Marshal(map[string]any{
		"streamId": streamID,
		"value":    value,
	})
	if err != nil {
		return err
	}
	return conn.WriteMessage(websocket.TextMessage, raw)
}
