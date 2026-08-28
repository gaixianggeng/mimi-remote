package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

func (p *appServerGatewayPolicy) rewriteRemoteCLIResponse(payload []byte, frame *appServerGatewayFrame) ([]byte, bool, error) {
	if p == nil || p.clientKind != appServerGatewayClientRemoteCLI || frame == nil || !gatewayFrameIsResponse(frame) {
		return payload, false, nil
	}
	pending, ok := p.consumePendingClientRequest(frame.ID)
	if !ok || (pending.method != "config/read" && pending.method != "configRequirements/read" && pending.method != "account/read") {
		return payload, false, nil
	}
	if len(frame.Error) > 0 {
		return rewriteRemoteCLIResponseError(payload, pending.method+" failed")
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(frame.Result))
	decoder.UseNumber()
	if decoder.Decode(&result) != nil {
		return nil, true, fmt.Errorf("%s 响应不是 JSON object", pending.method)
	}
	safe := map[string]any{}
	switch pending.method {
	case "config/read":
		safe = sanitizeRemoteCLIConfigReadResult(result, pending.cwd)
	case "configRequirements/read":
		// 0.149.1 在无集中策略时返回 {requirements:null}。不把未来新增的
		// 未知字段跨 SSH 透传，升级协议基线后再显式评审。
		safe = map[string]any{"requirements": nil}
	case "account/read":
		safe = sanitizeRemoteCLIAccountReadResult(result)
	}
	return rewriteGatewayResponseResult(payload, safe)
}

func rewriteRemoteCLIResponseError(payload []byte, message string) ([]byte, bool, error) {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return nil, true, err
	}
	errorValue, err := json.Marshal(map[string]any{
		"code":    appServerPolicyErrorCode,
		"message": message,
	})
	if err != nil {
		return nil, true, err
	}
	delete(envelope, "result")
	envelope["error"] = errorValue
	rewritten, err := json.Marshal(envelope)
	return rewritten, true, err
}

func sanitizeRemoteCLIConfigReadResult(result map[string]any, cwd string) map[string]any {
	configValue, _ := result["config"].(map[string]any)
	safeConfig := copyGatewayParams(configValue,
		"model", "model_provider", "sandbox_mode", "personality", "web_search", "service_tier")
	// remote gateway 始终从可审批策略开始。客户端若显式选择完全访问，后续
	// turn/start 安全改写仍会在明确沙盒/permission profile 下归一化为 never。
	safeConfig["approval_policy"] = "on-request"
	if projectsValue, ok := configValue["projects"].(map[string]any); ok {
		for configuredPath, rawProject := range projectsValue {
			if strings.TrimSpace(configuredPath) != strings.TrimSpace(cwd) {
				continue
			}
			project, ok := rawProject.(map[string]any)
			if !ok {
				continue
			}
			trustLevel, ok := project["trust_level"].(string)
			if ok && (trustLevel == "trusted" || trustLevel == "untrusted") {
				safeConfig["projects"] = map[string]any{configuredPath: map[string]any{"trust_level": trustLevel}}
			}
		}
	}
	// Codex CLI 0.149.1 的响应模型包含这三个字段。空 origins/layers 保留协议形状，
	// 但不会把主机配置层、环境变量或 MCP 配置送过 SSH。
	return map[string]any{"config": safeConfig, "origins": map[string]any{}, "layers": []any{}}
}

func sanitizeRemoteCLIAccountReadResult(result map[string]any) map[string]any {
	safe := map[string]any{}
	if value, ok := result["requiresOpenaiAuth"].(bool); ok {
		safe["requiresOpenaiAuth"] = value
	}
	if account, ok := result["account"].(map[string]any); ok {
		safeAccount := copyGatewayParams(account, "type", "planType")
		if len(safeAccount) > 0 {
			safe["account"] = safeAccount
		}
	}
	return safe
}

func rewriteGatewayResponseResult(payload []byte, result any) ([]byte, bool, error) {
	var envelope map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&envelope); err != nil {
		return nil, true, err
	}
	envelope["result"] = result
	delete(envelope, "error")
	rewritten, err := json.Marshal(envelope)
	return rewritten, true, err
}
