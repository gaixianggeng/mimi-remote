package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// runtime status 探测单独放在客户端文件，避免主入口继续膨胀，同时保持 setup/status 共用同一校验逻辑。
func runtimeStatusURL(endpoint string) (string, error) {
	return serviceCheckURL(endpoint, "/api/runtime/status")
}

func fetchServiceRuntimeStatus(
	ctx context.Context,
	endpoint string,
	token string,
	timeout time.Duration,
	refresh bool,
) (map[string]any, error) {
	target, err := runtimeStatusURL(endpoint)
	if err != nil {
		return nil, err
	}
	if refresh {
		target += "?refresh=wait"
	}
	requestCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}
	if value := strings.TrimSpace(token); value != "" {
		req.Header.Set("Authorization", "Bearer "+value)
	}
	client := http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("runtime status HTTP %d", resp.StatusCode)
	}
	var payload map[string]any
	decoder := json.NewDecoder(io.LimitReader(resp.Body, 256*1024))
	if err := decoder.Decode(&payload); err != nil {
		return nil, fmt.Errorf("runtime status 响应不是有效 JSON：%w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return nil, errors.New("runtime status 响应包含多个 JSON 值")
		}
		return nil, fmt.Errorf("runtime status 响应包含畸形尾部数据：%w", err)
	}
	if err := validateRuntimeStatusPayload(payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func validateRuntimeStatusPayload(payload map[string]any) error {
	rawRuntimes, ok := payload["runtimes"]
	if !ok {
		return errors.New("runtime status 响应缺少 runtimes")
	}
	runtimes, ok := rawRuntimes.([]any)
	if !ok {
		return errors.New("runtime status 响应的 runtimes 不是数组")
	}
	for index, rawRuntime := range runtimes {
		runtime, ok := rawRuntime.(map[string]any)
		if !ok {
			return fmt.Errorf("runtime status 响应的 runtimes[%d] 不是对象", index)
		}
		for _, key := range []string{"id", "title", "state"} {
			value, ok := runtime[key].(string)
			if !ok || strings.TrimSpace(value) == "" {
				return fmt.Errorf("runtime status 响应的 runtimes[%d].%s 无效", index, key)
			}
		}
		if _, ok := runtime["enabled"].(bool); !ok {
			return fmt.Errorf("runtime status 响应的 runtimes[%d].enabled 无效", index)
		}
	}
	for _, key := range []string{"refreshing", "stale"} {
		if value, exists := payload[key]; exists {
			if _, ok := value.(bool); !ok {
				return fmt.Errorf("runtime status 响应的 %s 不是布尔值", key)
			}
		}
	}
	if value, exists := payload["checked_at"]; exists {
		if _, ok := value.(string); !ok {
			return errors.New("runtime status 响应的 checked_at 不是字符串")
		}
	}
	return nil
}
