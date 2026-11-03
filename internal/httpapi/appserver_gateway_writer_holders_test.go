package httpapi

import (
	"encoding/json"
	"testing"
)

type stubGatewayWriterLocks struct {
	held      map[string]struct{}
	known     bool
	requested []string
}

func (s *stubGatewayWriterLocks) HeldThreads(ids []string) (map[string]struct{}, bool) {
	s.requested = append(s.requested, ids...)
	return s.held, s.known
}

func annotateWriterHoldersForTest(t *testing.T, policy *appServerGatewayPolicy, payload string) map[string]map[string]any {
	t.Helper()
	var response struct {
		Result struct {
			Data       []map[string]any `json:"data"`
			NextCursor string           `json:"nextCursor"`
		} `json:"result"`
	}
	if err := json.Unmarshal(policy.annotateWriterHolders([]byte(payload)), &response); err != nil {
		t.Fatal(err)
	}
	if response.Result.NextCursor != "next" {
		t.Fatalf("result 的其他字段应保留：%+v", response.Result)
	}
	threads := map[string]map[string]any{}
	for _, item := range response.Result.Data {
		threads[item["id"].(string)] = item
	}
	return threads
}

const writerHoldersTestPayload = `{"id":7,"result":{"nextCursor":"next","data":[
{"id":"desktop","status":{"type":"notLoaded"},"updatedAt":1793718269},
{"id":"free","status":{"type":"notLoaded"}},
{"id":"loaded","status":{"type":"idle"},"writerHeldElsewhere":true}
]}}`

func TestAnnotateWriterHoldersMarksOnlyNotLoadedThreads(t *testing.T) {
	locks := &stubGatewayWriterLocks{held: map[string]struct{}{"desktop": {}}, known: true}
	policy := &appServerGatewayPolicy{router: &Router{codexWriterLocks: locks}, runtimeID: "codex"}
	threads := annotateWriterHoldersForTest(t, policy, writerHoldersTestPayload)

	if threads["desktop"]["writerHeldElsewhere"] != true {
		t.Fatalf("别处持有的会话应标记：%v", threads["desktop"])
	}
	if threads["free"]["writerHeldElsewhere"] != false {
		t.Fatalf("没有持有方的会话应明确为 false：%v", threads["free"])
	}
	if threads["loaded"]["writerHeldElsewhere"] != false {
		t.Fatalf("已加载的会话锁在共享实例手里，上游字段也不能被采信：%v", threads["loaded"])
	}
	if len(locks.requested) != 2 {
		t.Fatalf("只应查询 notLoaded 的会话：%v", locks.requested)
	}
	if threads["desktop"]["updatedAt"] != float64(1793718269) {
		t.Fatalf("其他字段应原样保留：%v", threads["desktop"])
	}
}

func TestAnnotateWriterHoldersOmitsFieldWhenUnknown(t *testing.T) {
	locks := &stubGatewayWriterLocks{known: false}
	policy := &appServerGatewayPolicy{router: &Router{codexWriterLocks: locks}, runtimeID: "codex"}
	threads := annotateWriterHoldersForTest(t, policy, writerHoldersTestPayload)
	if _, ok := threads["desktop"]["writerHeldElsewhere"]; ok {
		t.Fatalf("无法确认时不能写成 false：%v", threads["desktop"])
	}
}

func TestAnnotateWriterHoldersOnlyAppliesToCodexWithInspector(t *testing.T) {
	locks := &stubGatewayWriterLocks{held: map[string]struct{}{"desktop": {}}, known: true}
	cases := map[string]*appServerGatewayPolicy{
		"claude 通道":  {router: &Router{codexWriterLocks: locks}, runtimeID: "claude"},
		"未启用检查器（远端）": {router: &Router{}, runtimeID: "codex"},
	}
	for name, policy := range cases {
		if got := policy.annotateWriterHolders([]byte(writerHoldersTestPayload)); string(got) != writerHoldersTestPayload {
			t.Fatalf("%s 不应改写响应：%s", name, got)
		}
	}
}

func TestAnnotateWriterHoldersKeepsMalformedPayload(t *testing.T) {
	locks := &stubGatewayWriterLocks{known: true}
	policy := &appServerGatewayPolicy{router: &Router{codexWriterLocks: locks}, runtimeID: "codex"}
	for _, payload := range []string{`not json`, `{"id":1}`, `{"id":1,"result":{"data":null}}`} {
		if got := policy.annotateWriterHolders([]byte(payload)); string(got) != payload {
			t.Fatalf("异常响应应原样放行：%s -> %s", payload, got)
		}
	}
}
