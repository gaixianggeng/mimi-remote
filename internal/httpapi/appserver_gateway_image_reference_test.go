package httpapi

import (
	"strings"
	"testing"
)

func TestGatewayImageReferenceBoundary(t *testing.T) {
	for _, method := range []string{"turn/start", "turn/steer", "thread/queue/add"} {
		t.Run(method, func(t *testing.T) {
			for _, input := range []map[string]any{
				{"type": "image", "fileId": "test-attachment"},
				{"type": "image", "fileId": "test-attachment", "url": "data:image/png;base64,AA=="},
			} {
				_, err := collectGatewayInputPaths(method, map[string]any{"input": []any{input}})
				if err == nil || !strings.Contains(err.Error(), "fileId 尚未开放") {
					t.Fatalf("未授权附件引用必须明确拒绝，input=%v err=%v", input, err)
				}
			}
			_, err := collectGatewayInputPaths(method, map[string]any{
				"input": []any{map[string]any{"type": "image", "url": "data:image/png;base64,AA=="}},
			})
			if err != nil {
				t.Fatalf("旧版 URL 图片输入应保持兼容：%v", err)
			}
		})
	}
}
