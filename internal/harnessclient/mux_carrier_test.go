package harnessclient

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// 本文件覆盖契约 §8 登记的两处仓库缺陷（均归 H03）：
//
//   - 缺陷 2：载体层只解 {streamId,value}，丢掉服务端顶层 type 判别值，
//     于是 error/end 帧变成空帧，流级错误只能表现为超时。
//   - 缺陷 3：Respond 断言 outcome 只有 result 一种，与上游
//     parseRemoteEventResult（接受 next/result/rejected）不符。
//
// 夹具依据：contracts/harness-native/fixtures/stream/mux-carrier.json
// 与 rpc/events-result.json。

// sendCarrierFrame 按 mux-carrier.json 的**服务端**形状写出一帧：顶层带 type。
//
// 既有的 sendFrame 只写 {streamId,value}（旧形状），这里必须另写一个——
// 正是「服务端每帧都带 type」这一点构成缺陷 2 的修复对象。
func sendCarrierFrame(conn *websocket.Conn, frame map[string]any) error {
	payload, err := json.Marshal(frame)
	if err != nil {
		return err
	}
	return conn.WriteMessage(websocket.TextMessage, payload)
}

// --- 缺陷 2：载体层判别式 ---

func TestDecodeMuxFrameCarrierItemKeepsInnerDiscriminator(t *testing.T) {
	value, deliver := decodeMuxFrame(muxFrame{
		Type:     CarrierItem,
		StreamID: "s1",
		Value:    json.RawMessage(`{"type":"snapshot","cursor":7}`),
	})
	if !deliver {
		t.Fatal("item 帧必须投递")
	}
	if value.CarrierType != CarrierItem {
		t.Fatalf("载体类型应为 item，得到 %q", value.CarrierType)
	}
	if value.Type != FrameSnapshot {
		t.Fatalf("内层判别式应为 snapshot，得到 %q", value.Type)
	}
	if string(value.Raw) != `{"type":"snapshot","cursor":7}` {
		t.Fatalf("value 必须原样保留，得到 %s", value.Raw)
	}
	if _, ok := value.CarrierFailure(); ok {
		t.Fatal("正常 item 帧不得被判定为载体错误")
	}
}

func TestDecodeMuxFrameCarrierErrorSurfacesStreamLevelError(t *testing.T) {
	value, deliver := decodeMuxFrame(muxFrame{
		Type:     CarrierError,
		StreamID: "s1",
		Error:    &RemoteError{Code: "gateway/internal", Message: "fixture stream failure"},
	})
	if !deliver {
		t.Fatal("error 帧必须投递：丢掉它会让上层只能等到超时")
	}
	if value.Type != FrameCarrierError {
		t.Fatalf("Type 应为 %q，得到 %q", FrameCarrierError, value.Type)
	}
	remoteErr, ok := value.CarrierFailure()
	if !ok {
		t.Fatal("必须判定为载体错误")
	}
	if remoteErr.Code != "gateway/internal" || remoteErr.Message != "fixture stream failure" {
		t.Fatalf("错误内容必须保留，得到 %+v", remoteErr)
	}
}

func TestDecodeMuxFrameCarrierErrorWithoutErrorObjectFailsClosed(t *testing.T) {
	// 服务端声明 error 却没带 error 对象。既不能当成功，也不能当"空错误"。
	value, deliver := decodeMuxFrame(muxFrame{Type: CarrierError, StreamID: "s1"})
	if !deliver {
		t.Fatal("error 帧必须投递")
	}
	remoteErr, ok := value.CarrierFailure()
	if !ok {
		t.Fatal("缺 error 对象仍必须判定为失败，不得静默降级")
	}
	if remoteErr.Code == "" {
		t.Fatal("合成的失败必须带可诊断 code")
	}
}

func TestDecodeMuxFrameCarrierEndIsDistinguishable(t *testing.T) {
	value, deliver := decodeMuxFrame(muxFrame{Type: CarrierEnd, StreamID: "s1"})
	if !deliver {
		t.Fatal("end 帧必须投递，让上层知道是服务端主动收尾")
	}
	if !value.IsCarrierEnd() {
		t.Fatalf("必须判定为服务端收尾，得到 %+v", value)
	}
	if _, ok := value.CarrierFailure(); ok {
		t.Fatal("end 不是错误")
	}
}

func TestDecodeMuxFrameDropsUnknownCarrierWithoutKillingSubscription(t *testing.T) {
	if _, deliver := decodeMuxFrame(muxFrame{Type: "something-new", StreamID: "s1"}); deliver {
		t.Fatal("不认识的载体类型应丢弃单帧，而不是投递成空帧")
	}
}

func TestDecodeMuxFrameWithoutCarrierTypeFallsBackToValue(t *testing.T) {
	// 兼容路径：不带顶层 type 的对端仍按 value 判别，保持旧行为。
	value, deliver := decodeMuxFrame(muxFrame{
		StreamID: "s1",
		Value:    json.RawMessage(`{"type":"ready","clientId":"c1"}`),
	})
	if !deliver {
		t.Fatal("无载体 type 时必须退回按 value 判别")
	}
	if value.Type != FrameReady {
		t.Fatalf("应解出 ready，得到 %q", value.Type)
	}
}

func TestStreamSurfacesCarrierErrorInsteadOfSilentTimeout(t *testing.T) {
	// 缺陷 2 的端到端回归：服务端发 error 帧后，上层必须立刻拿到可判定的失败，
	// 而不是空帧或超时。
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		streamID, _ := open["streamId"].(string)
		return sendCarrierFrame(conn, map[string]any{
			"type":     CarrierError,
			"streamId": streamID,
			"error": map[string]any{
				"code":    "gateway/internal",
				"message": "fixture stream failure",
			},
		})
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.OpenStream(context.Background(), EndpointEvents, map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()

	select {
	case frame, ok := <-stream.Frames():
		if !ok {
			t.Fatal("订阅在给出原因之前就结束了，上层拿不到失败理由")
		}
		remoteErr, isFailure := frame.CarrierFailure()
		if !isFailure {
			t.Fatalf("载体 error 帧必须可判定为失败，得到 %+v", frame)
		}
		if remoteErr.Code != "gateway/internal" {
			t.Fatalf("错误 code 必须保留，得到 %q", remoteErr.Code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("载体 error 帧被吞掉：上层只能等到超时，无法区分报错与静默")
	}
}

func TestStreamEndsWhenServerSendsCarrierEnd(t *testing.T) {
	fake := newFakeHarness(t)
	fake.onMuxOpen(func(conn *websocket.Conn, open map[string]any) error {
		streamID, _ := open["streamId"].(string)
		if err := sendCarrierFrame(conn, map[string]any{"type": CarrierEnd, "streamId": streamID}); err != nil {
			return err
		}
		// 服务端不再发帧；订阅必须因 end 自行结束，而不是挂在这里等读期限。
		<-streamDone(conn)
		return nil
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	stream, err := client.OpenStream(context.Background(), EndpointEvents, map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()

	deadline := time.After(5 * time.Second)
	for {
		select {
		case frame, ok := <-stream.Frames():
			if !ok {
				return // 通道关闭即订阅已结束
			}
			if !frame.IsCarrierEnd() {
				t.Fatalf("end 之前不应有其它帧，得到 %+v", frame)
			}
		case <-deadline:
			t.Fatal("服务端 end 帧未结束订阅")
		}
	}
}

// --- 缺陷 3：outcome 三种 kind ---

func TestRespondOutcomeForwardsEveryKindVerbatim(t *testing.T) {
	cases := []struct {
		name    string
		outcome map[string]any
	}{
		{"next", map[string]any{"kind": OutcomeKindNext}},
		{"result", map[string]any{"kind": OutcomeKindResult, "value": OutcomeAllowedOnce}},
		{"rejected", map[string]any{
			"kind": OutcomeKindRejected,
			"error": map[string]any{
				"name":    "Error",
				"message": "fixture rejection message",
				"code":    "fixture/rejection-code",
				"details": map[string]any{},
			},
		}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			fake := newFakeHarness(t)
			fake.handle(EndpointEventsResult, func(json.RawMessage) (any, *RemoteError) {
				return map[string]any{}, nil
			})
			server := fake.serve()
			client := authenticatedClient(t, fake, server.URL)

			err := client.RespondOutcome(context.Background(), "client-fixture-0001", "evt-fixture-0001", testCase.outcome)
			if err != nil {
				t.Fatalf("kind=%s 必须被转发，不得被中继拒收：%v", testCase.name, err)
			}

			calls := fake.recorded()
			if len(calls) != 1 {
				t.Fatalf("期望一次上游调用，得到 %d", len(calls))
			}
			if calls[0].Path != "/api/$events/result" {
				t.Fatalf("路径必须是字面 /api/$events/result，得到 %q", calls[0].Path)
			}
			args := rpcArgs(t, calls[0].Envelope)
			// 上游用 exactKeys 校验：键必须恰好三个。
			if len(args) != 3 {
				t.Fatalf("args 必须恰好三个键，得到 %v", keysOf(args))
			}
			for _, key := range []string{"clientId", "eventId", "outcome"} {
				if _, ok := args[key]; !ok {
					t.Fatalf("args 缺少 %q：%v", key, keysOf(args))
				}
			}
			if !reflect.DeepEqual(args["outcome"], testCase.outcome) {
				t.Fatalf("outcome 必须逐字转发，期望 %v，得到 %v", testCase.outcome, args["outcome"])
			}
		})
	}
}

func TestRespondRemainsResultOnlyShorthand(t *testing.T) {
	fake := newFakeHarness(t)
	fake.handle(EndpointEventsResult, func(json.RawMessage) (any, *RemoteError) {
		return map[string]any{}, nil
	})
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	if err := client.Respond(context.Background(), "client-fixture-0001", "evt-fixture-0001", OutcomeRejected); err != nil {
		t.Fatal(err)
	}
	args := rpcArgs(t, fake.recorded()[0].Envelope)
	expected := map[string]any{"kind": OutcomeKindResult, "value": OutcomeRejected}
	if !reflect.DeepEqual(args["outcome"], expected) {
		t.Fatalf("Respond 应保持 {kind:result,value:…} 形状，得到 %v", args["outcome"])
	}
}

// rpcArgs 从记录的 Connection RPC 外壳里取出 payload.args。
func rpcArgs(t *testing.T, envelope map[string]any) map[string]any {
	t.Helper()
	payload, ok := envelope["payload"].(map[string]any)
	if !ok {
		t.Fatalf("外壳缺少 payload：%v", envelope)
	}
	args, ok := payload["args"].(map[string]any)
	if !ok {
		t.Fatalf("外壳缺少 payload.args：%v", envelope)
	}
	return args
}

func keysOf(value map[string]any) []string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	return keys
}
