package httpapi

import (
	"bytes"
	"encoding/json"
	"strings"
)

// gatewayWriterHeldElsewhereField 是网关附加在 Codex 会话上的展示字段：共享 App Server 没有
// 加载这条会话，但它的 writer 锁被电脑上另一个 Codex 进程（通常是普通 Desktop “This Mac”）
// 持有。它只说明占用，不代表正在运行，也不参与授权；能否写入仍以 thread/resume 的结果为准。
const gatewayWriterHeldElsewhereField = "writerHeldElsewhere"

type gatewayWriterLockInspector interface {
	HeldThreads(threadIDs []string) (held map[string]struct{}, known bool)
}

type appServerGatewayWriterHolderThread struct {
	ID     string          `json:"id"`
	Status json.RawMessage `json:"status"`
}

// gatewayThreadStatusIsNotLoaded 兼容对象和字符串两种 status 形态。
func gatewayThreadStatusIsNotLoaded(raw json.RawMessage) bool {
	var object struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(raw, &object) == nil && object.Type != "" {
		return object.Type == "notLoaded"
	}
	var text string
	return json.Unmarshal(raw, &text) == nil && text == "notLoaded"
}

// annotateWriterHolders 给 Codex 的 thread/list 结果标注占用情况。只有共享 App Server 报告
// notLoaded 的会话才可能被别处持有：已加载的会话，锁就在共享实例自己手里。
// 无法确认的会话不带这个字段，由客户端沿用已知值，不能写成 false。
func (p *appServerGatewayPolicy) annotateWriterHolders(payload []byte) []byte {
	if p == nil || p.router == nil || p.router.codexWriterLocks == nil || p.runtimeID != "codex" {
		return payload
	}
	var response map[string]json.RawMessage
	if json.Unmarshal(payload, &response) != nil {
		return payload
	}
	var result map[string]json.RawMessage
	if raw := response["result"]; len(raw) == 0 || json.Unmarshal(raw, &result) != nil {
		return payload
	}
	var items []map[string]json.RawMessage
	if raw := result["data"]; len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &items) != nil {
		return payload
	}

	notLoaded := make(map[int]string, len(items))
	candidates := make([]string, 0, len(items))
	for index, item := range items {
		var thread appServerGatewayWriterHolderThread
		if id, ok := item["id"]; !ok || json.Unmarshal(id, &thread.ID) != nil {
			continue
		}
		thread.ID = strings.TrimSpace(thread.ID)
		if thread.ID == "" || !gatewayThreadStatusIsNotLoaded(item["status"]) {
			continue
		}
		notLoaded[index] = thread.ID
		candidates = append(candidates, thread.ID)
	}
	held, known := p.router.codexWriterLocks.HeldThreads(candidates)

	falseValue, trueValue := json.RawMessage("false"), json.RawMessage("true")
	for index, item := range items {
		// 上游不应带这个字段；先删掉，保证客户端看到的只可能来自这里。
		delete(item, gatewayWriterHeldElsewhereField)
		id, isCandidate := notLoaded[index]
		if !isCandidate {
			item[gatewayWriterHeldElsewhereField] = falseValue
			continue
		}
		if _, isHeld := held[id]; isHeld {
			item[gatewayWriterHeldElsewhereField] = trueValue
		} else if known {
			item[gatewayWriterHeldElsewhereField] = falseValue
		}
	}

	data, err := json.Marshal(items)
	if err != nil {
		return payload
	}
	result["data"] = data
	resultRaw, err := json.Marshal(result)
	if err != nil {
		return payload
	}
	response["result"] = resultRaw
	rewritten, err := json.Marshal(response)
	if err != nil {
		return payload
	}
	return rewritten
}
