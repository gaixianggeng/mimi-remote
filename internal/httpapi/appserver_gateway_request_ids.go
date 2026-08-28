package httpapi

import (
	"encoding/json"
	"fmt"
)

const appServerGatewayInflightClientRequestMax = 512

// reserveInflightClientRequest 对所有发往上游的 JSON-RPC 请求实施连接级 ID 唯一性。
// 这不仅符合 JSON-RPC 的响应关联语义，也防止普通请求的同 ID 响应误释放 turn admission。
func (p *appServerGatewayPolicy) reserveInflightClientRequest(id *json.RawMessage, method string) error {
	if p == nil || p.router == nil || normalizeAppServerRuntimeID(p.runtimeID) != "codex" || !p.router.cfg.AppServer.RemoteGateway.Enabled {
		return nil
	}
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("%s 请求缺少 id", method)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.inflightClientRequests == nil {
		p.inflightClientRequests = map[string]string{}
	}
	if previous, exists := p.inflightClientRequests[key]; exists {
		return fmt.Errorf("JSON-RPC request id 已被在途 %s 请求占用", previous)
	}
	if len(p.inflightClientRequests) >= appServerGatewayInflightClientRequestMax {
		return fmt.Errorf("gateway 在途 client request 过多")
	}
	p.inflightClientRequests[key] = method
	return nil
}

func (p *appServerGatewayPolicy) consumeInflightClientRequest(id *json.RawMessage) (string, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return "", false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	method, ok := p.inflightClientRequests[key]
	if ok {
		delete(p.inflightClientRequests, key)
	}
	return method, ok
}

func (p *appServerGatewayPolicy) cancelInflightClientRequest(id *json.RawMessage) {
	_, _ = p.consumeInflightClientRequest(id)
}

func (p *appServerGatewayPolicy) cancelInflightClientRequestFromPayload(payload []byte) {
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) == nil {
		p.cancelInflightClientRequest(frame.ID)
	}
}
