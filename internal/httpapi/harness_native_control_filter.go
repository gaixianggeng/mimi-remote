package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

var errHarnessNativeControlShape = errors.New("unsupported Harness control frame")

// harnessNativeFilterControl 按已冻结的 control.ts 契约裁剪宿主级控制帧。
// baseline 的字典都以 session ID 为键；0.1.6 可以省略 queues。
// authorize 的结果只在本帧内去重，不建立跨帧授权缓存。未知外壳直接失败，
// 避免新版本增加未经授权的新容器后，被一次 RawMessage 透传带到手机。
func harnessNativeFilterControl(
	raw json.RawMessage,
	authorize func(string) (bool, error),
) (json.RawMessage, error) {
	frame, err := harnessNativeControlObject(raw)
	if err != nil {
		return nil, err
	}
	var kind string
	if json.Unmarshal(frame["type"], &kind) != nil {
		return nil, errHarnessNativeControlShape
	}
	if kind != "baseline" {
		var keys []string
		switch kind {
		case "projection":
			keys = []string{"type", "sessionId", "key", "value", "seq"}
		case "queue":
			keys = []string{"type", "sessionId", "items"}
		case "jobs":
			keys = []string{"type", "sessionId", "jobs"}
		default:
			return nil, errHarnessNativeControlShape
		}
		if !harnessNativeControlKeys(frame, keys...) {
			return nil, errHarnessNativeControlShape
		}
		var id string
		if json.Unmarshal(frame["sessionId"], &id) != nil || !harnessNativeControlID(id) {
			return nil, errHarnessNativeControlShape
		}
		allowed, err := authorize(id)
		if err != nil || !allowed {
			return nil, err
		}
		return raw, nil
	}

	if !harnessNativeControlKeys(frame, "type", "value") {
		return nil, errHarnessNativeControlShape
	}
	value, err := harnessNativeControlObject(frame["value"])
	if err != nil {
		return nil, errHarnessNativeControlShape
	}
	sectionNames := []string{"jobs", "projections"}
	if !harnessNativeControlKeys(value, sectionNames...) {
		sectionNames = []string{"queues", "jobs", "projections"}
		if !harnessNativeControlKeys(value, sectionNames...) {
			return nil, errHarnessNativeControlShape
		}
	}
	sections := make(map[string]map[string]json.RawMessage, len(sectionNames))
	ids := make(map[string]struct{})
	for _, name := range sectionNames {
		entries, err := harnessNativeControlObject(value[name])
		if err != nil {
			return nil, err
		}
		sections[name] = entries
		for id := range entries {
			if !harnessNativeControlID(id) {
				return nil, errHarnessNativeControlShape
			}
			ids[id] = struct{}{}
		}
	}
	ordered := make([]string, 0, len(ids))
	for id := range ids {
		ordered = append(ordered, id)
	}
	sort.Strings(ordered)
	for _, id := range ordered {
		allowed, err := authorize(id)
		if err != nil {
			// 一项授权检查失败，不能将剩余部分伪装成完整 baseline。
			return nil, err
		}
		if !allowed {
			for _, entries := range sections {
				delete(entries, id)
			}
		}
	}
	for name, entries := range sections {
		value[name], err = json.Marshal(entries)
		if err != nil {
			return nil, err
		}
	}
	frame["value"], err = json.Marshal(value)
	if err != nil {
		return nil, err
	}
	return json.Marshal(frame)
}

func harnessNativeControlID(id string) bool {
	return id != "" && strings.TrimSpace(id) == id && !strings.ContainsRune(id, 0)
}

func harnessNativeControlKeys(value map[string]json.RawMessage, keys ...string) bool {
	if len(value) != len(keys) {
		return false
	}
	for _, key := range keys {
		if _, ok := value[key]; !ok {
			return false
		}
	}
	return true
}

func harnessNativeControlObject(raw json.RawMessage) (map[string]json.RawMessage, error) {
	var value map[string]json.RawMessage
	if err := json.Unmarshal(raw, &value); err != nil || value == nil {
		return nil, fmt.Errorf("%w: expected object", errHarnessNativeControlShape)
	}
	return value, nil
}
