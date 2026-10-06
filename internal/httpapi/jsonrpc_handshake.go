package httpapi

import "context"

// jsonRPCInitializer 是 JSON-RPC 握手所需的最小能力。
// Codex 的 WebSocket 客户端与 Claude bridge 的 socket JSONL 客户端都满足它。
type jsonRPCInitializer interface {
	call(ctx context.Context, method string, params any, result any) error
	notify(ctx context.Context, method string, params any) error
}

// initializeJSONRPCClient 执行 JSON-RPC 的 initialize / initialized 握手并返回服务端 userAgent。
// 两种传输的握手报文完全一致，因此只保留这一份实现。
func initializeJSONRPCClient(
	ctx context.Context,
	client jsonRPCInitializer,
	name string,
	title string,
	version string,
) (string, error) {
	var result struct {
		UserAgent string `json:"userAgent"`
	}
	if err := client.call(ctx, "initialize", map[string]any{
		"clientInfo": map[string]any{
			"name":    name,
			"title":   title,
			"version": version,
		},
		"capabilities": map[string]any{},
	}, &result); err != nil {
		return "", err
	}
	if err := client.notify(ctx, "initialized", map[string]any{}); err != nil {
		return "", err
	}
	return result.UserAgent, nil
}
