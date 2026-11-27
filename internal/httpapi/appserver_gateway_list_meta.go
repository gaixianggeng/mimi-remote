package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

const gatewayMalformedThreadListReason = "upstream_malformed_thread_list"
const gatewayStalledThreadListCursorReason = "upstream_stalled_thread_list_cursor"

var allowedThreadListMetaSources = map[string]struct{}{
	"cli":   {},
	"other": {},
}

var allowedThreadListMetaDegradedReasons = map[string]struct{}{
	"other_timeout":                 {},
	"other_failed":                  {},
	"other_probe_permission_denied": {},
	"other_probe_io_error":          {},
}

func malformedThreadListPolicyError(id *json.RawMessage, message string) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id:      id,
		message: message,
		data: map[string]any{
			"reason": gatewayMalformedThreadListReason,
		},
		target: "client",
	}
}

func stalledThreadListCursorPolicyError(id *json.RawMessage, message string) *appServerGatewayPolicyError {
	return &appServerGatewayPolicyError{
		id:      id,
		message: message,
		data: map[string]any{
			"reason": gatewayStalledThreadListCursorReason,
		},
		target: "client",
	}
}

// isValidJSONRPCErrorObject 按 JSON-RPC 2.0 校验错误对象（整数 code + 字符串 message）。
func isValidJSONRPCErrorObject(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) || trimmed[0] != '{' {
		return false
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &obj); err != nil {
		return false
	}
	codeRaw, hasCode := obj["code"]
	msgRaw, hasMsg := obj["message"]
	if !hasCode || !hasMsg {
		return false
	}
	var codeVal any
	dec := json.NewDecoder(bytes.NewReader(codeRaw))
	dec.UseNumber()
	if err := dec.Decode(&codeVal); err != nil {
		return false
	}
	if _, ok := gatewayJSONNumberInt64(codeVal); !ok {
		return false
	}
	trimmedMsg := bytes.TrimSpace(msgRaw)
	if len(trimmedMsg) == 0 || trimmedMsg[0] != '"' {
		return false
	}
	var msg string
	if err := json.Unmarshal(trimmedMsg, &msg); err != nil {
		return false
	}
	return true
}

// validateThreadListNextCursor 严格校验 thread/list 响应的 nextCursor 字段：
// 必须显式存在；允许显式 JSON null 或 TrimSpace 后非空的 JSON string；
// 缺键、空串、纯空白或非法类型一律判畸形。返回保留原始字节的 rawCursor 及去空白 trimmed。
func validateThreadListNextCursor(resultFields map[string]json.RawMessage) (hasCursor bool, rawCursor string, trimmed string, err error) {
	raw, exists := resultFields["nextCursor"]
	if !exists {
		return false, "", "", fmt.Errorf("thread/list response 缺少 nextCursor 字段")
	}
	trimmedBytes := bytes.TrimSpace(raw)
	if bytes.Equal(trimmedBytes, []byte("null")) {
		return false, "", "", nil
	}
	var s string
	if unmarshalErr := json.Unmarshal(trimmedBytes, &s); unmarshalErr != nil {
		return false, "", "", fmt.Errorf("thread/list response.nextCursor 必须是字符串或 null")
	}
	t := strings.TrimSpace(s)
	if t == "" {
		return false, "", "", fmt.Errorf("thread/list response.nextCursor 不能为空字符串")
	}
	return true, s, t, nil
}

// validateOptionalJSONStringField 校验对象中可选键若存在且非 null 时必须为 JSON string。
func validateOptionalJSONStringField(fields map[string]json.RawMessage, key string) error {
	raw, exists := fields[key]
	if !exists {
		return nil
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil
	}
	var s string
	if err := json.Unmarshal(trimmed, &s); err != nil {
		return fmt.Errorf("thread/list item.%s 必须是字符串或 null", key)
	}
	return nil
}

// sanitizeThreadListMeta 白名单清洗上游 listMeta：
// - 省略或显式 null：返回 (nil, false, nil)，绝不伪造 complete；
// - 严禁上游传入 pageDisposition、retryReason 或任何未知键；
// - complete == true：严禁 degradedReason/degradedSources，允许可选去重 sources；
// - complete == false：严禁 sources，必填白名单 degradedReason 与非空去重 degradedSources。
func sanitizeThreadListMeta(raw json.RawMessage) (map[string]any, bool, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, false, nil
	}
	if trimmed[0] != '{' {
		return nil, false, fmt.Errorf("thread/list listMeta 必须是对象")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &fields); err != nil {
		return nil, false, fmt.Errorf("thread/list listMeta JSON 无效")
	}

	for key := range fields {
		switch key {
		case "schemaVersion", "complete", "sources", "degradedReason", "degradedSources":
		default:
			return nil, false, fmt.Errorf("thread/list listMeta 包含不允许的字段")
		}
	}

	rawVersion, hasVersion := fields["schemaVersion"]
	if !hasVersion {
		return nil, false, fmt.Errorf("thread/list listMeta 缺少 schemaVersion")
	}
	var versionVal any
	dec := json.NewDecoder(bytes.NewReader(rawVersion))
	dec.UseNumber()
	if err := dec.Decode(&versionVal); err != nil {
		return nil, false, fmt.Errorf("thread/list listMeta.schemaVersion 无效")
	}
	versionNum, ok := gatewayJSONNumberInt64(versionVal)
	if !ok || versionNum != 1 {
		return nil, false, fmt.Errorf("thread/list listMeta.schemaVersion 必须为 1")
	}

	rawComplete, hasComplete := fields["complete"]
	if !hasComplete {
		return nil, false, fmt.Errorf("thread/list listMeta 缺少 complete")
	}
	trimmedComplete := bytes.TrimSpace(rawComplete)
	if !bytes.Equal(trimmedComplete, []byte("true")) && !bytes.Equal(trimmedComplete, []byte("false")) {
		return nil, false, fmt.Errorf("thread/list listMeta.complete 必须是布尔值")
	}
	var complete bool
	if err := json.Unmarshal(trimmedComplete, &complete); err != nil {
		return nil, false, fmt.Errorf("thread/list listMeta.complete 必须是布尔值")
	}

	out := map[string]any{
		"schemaVersion": 1,
		"complete":      complete,
	}

	if complete {
		if _, exists := fields["degradedReason"]; exists {
			return nil, false, fmt.Errorf("thread/list listMeta complete=true 时禁止包含 degradedReason")
		}
		if _, exists := fields["degradedSources"]; exists {
			return nil, false, fmt.Errorf("thread/list listMeta complete=true 时禁止包含 degradedSources")
		}
		if rawSources, exists := fields["sources"]; exists {
			sources, err := parseThreadListMetaSources(rawSources, "sources")
			if err != nil {
				return nil, false, err
			}
			out["sources"] = sources
		}
		return out, true, nil
	}

	// complete == false
	if _, exists := fields["sources"]; exists {
		return nil, false, fmt.Errorf("thread/list listMeta complete=false 时禁止包含 sources")
	}
	rawReason, hasReason := fields["degradedReason"]
	if !hasReason {
		return nil, false, fmt.Errorf("thread/list listMeta complete=false 时缺少 degradedReason")
	}
	var reason string
	if err := json.Unmarshal(rawReason, &reason); err != nil {
		return nil, false, fmt.Errorf("thread/list listMeta.degradedReason 必须是字符串")
	}
	if _, valid := allowedThreadListMetaDegradedReasons[reason]; !valid {
		return nil, false, fmt.Errorf("thread/list listMeta.degradedReason 非法")
	}
	rawDegradedSources, hasDegradedSources := fields["degradedSources"]
	if !hasDegradedSources {
		return nil, false, fmt.Errorf("thread/list listMeta complete=false 时缺少 degradedSources")
	}
	degradedSources, err := parseThreadListMetaSources(rawDegradedSources, "degradedSources")
	if err != nil {
		return nil, false, err
	}
	out["degradedReason"] = reason
	out["degradedSources"] = degradedSources
	return out, true, nil
}

func parseThreadListMetaSources(raw json.RawMessage, fieldName string) ([]string, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) || trimmed[0] != '[' {
		return nil, fmt.Errorf("thread/list listMeta.%s 必须是非空字符串数组", fieldName)
	}
	var items []string
	if err := json.Unmarshal(trimmed, &items); err != nil {
		return nil, fmt.Errorf("thread/list listMeta.%s 必须是字符串数组", fieldName)
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("thread/list listMeta.%s 不能为空数组", fieldName)
	}
	seen := make(map[string]struct{}, len(items))
	for _, s := range items {
		if _, ok := allowedThreadListMetaSources[s]; !ok {
			return nil, fmt.Errorf("thread/list listMeta.%s 包含非法来源", fieldName)
		}
		if _, dup := seen[s]; dup {
			return nil, fmt.Errorf("thread/list listMeta.%s 不能重复", fieldName)
		}
		seen[s] = struct{}{}
	}
	return items, nil
}

func buildGlobalThreadListMeta(upstreamMeta map[string]any, hasUpstreamMeta bool, incomplete bool) map[string]any {
	out := make(map[string]any, 6)
	if hasUpstreamMeta {
		for k, v := range upstreamMeta {
			out[k] = v
		}
	} else {
		out["schemaVersion"] = 1
	}
	if incomplete {
		out["pageDisposition"] = "same_page_retry"
		out["retryReason"] = "git_ownership_pending"
	} else {
		out["pageDisposition"] = "advance"
	}
	return out
}
