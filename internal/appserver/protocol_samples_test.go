package appserver

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestProtocolSamplesIncludeRequiredMethods(t *testing.T) {
	file, err := os.Open("testdata/protocol_samples.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	required := map[string]bool{
		"initialize":     false,
		"thread/list":    false,
		"thread/start":   false,
		"thread/resume":  false,
		"thread/read":    false,
		"turn/start":     false,
		"turn/interrupt": false,
	}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var sample struct {
			Message wireMessage `json:"message"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &sample); err != nil {
			t.Fatalf("协议样例不是合法 JSON：%v line=%q", err, scanner.Text())
		}
		if _, ok := required[sample.Message.Method]; ok {
			required[sample.Message.Method] = true
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	for method, seen := range required {
		if !seen {
			t.Fatalf("协议样例缺少方法 %s", method)
		}
	}
}

func TestProtocolSamplesUseJsonRPCLiteShape(t *testing.T) {
	file, err := os.Open("testdata/protocol_samples.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var sample struct {
			Name    string                     `json:"name"`
			Message map[string]any             `json:"message"`
			Raw     map[string]json.RawMessage `json:"-"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &sample); err != nil {
			t.Fatalf("协议样例不是合法 JSON：%v line=%q", err, scanner.Text())
		}
		if _, ok := sample.Message["jsonrpc"]; ok {
			t.Fatalf("app-server 线上协议不需要 jsonrpc 字段：%s", sample.Name)
		}
		hasID := sample.Message["id"] != nil
		method, hasMethod := sample.Message["method"].(string)
		_, hasResult := sample.Message["result"]
		_, hasError := sample.Message["error"]
		switch {
		case strings.Contains(sample.Name, ".request"):
			if !hasID || !hasMethod || method == "" || sample.Message["params"] == nil {
				t.Fatalf("request 样例应包含 id/method/params：%s", sample.Name)
			}
		case strings.Contains(sample.Name, ".response"):
			if !hasID || (!hasResult && !hasError) {
				t.Fatalf("response 样例应包含 id/result 或 id/error：%s", sample.Name)
			}
		case strings.Contains(sample.Name, ".notification"):
			if hasID || !hasMethod || sample.Message["params"] == nil {
				t.Fatalf("notification 样例应只有 method/params 且没有 id：%s", sample.Name)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
}
