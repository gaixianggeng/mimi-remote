package httpapi

import (
	"bufio"
	"bytes"
	"io"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestClaudeAdapterTurnHintsEnvironmentDefaultsOnAndDoesNotAffectLegacyBridge(t *testing.T) {
	off := false
	cases := []struct {
		name      string
		cfg       config.ClaudeConfig
		isAdapter bool
		want      string
		present   bool
	}{
		{name: "adapter omitted defaults on", cfg: config.ClaudeConfig{}, isAdapter: true, want: "true", present: true},
		{name: "adapter explicit off", cfg: config.ClaudeConfig{TurnHintsEnabled: &off}, isAdapter: true, want: "false", present: true},
		{name: "legacy bridge receives no injected switch", cfg: config.ClaudeConfig{}, isAdapter: false, present: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			value, present := claudeBridgeRuntimeEnv(tc.cfg, tc.isAdapter)[claudeAdapterTurnHintsEnv]
			if value != tc.want || present != tc.present {
				t.Fatalf("turn hint env mismatch value=%q present=%t", value, present)
			}
		})
	}
}

// 超大单帧必须被丢弃而不是撕掉连接：正常帧照常返回，超限帧返回 oversize=true 且不残留内容，
// 其后的正常帧仍能继续读取。这是 Claude 通道断线循环兜底的核心保证。
func TestReadBridgeStdoutLineDropsOversizeAndKeepsReading(t *testing.T) {
	const max = 1 << 10
	big := strings.Repeat("x", max*4)
	input := "first line\n" + big + "\n" + "third line\n"
	reader := bufio.NewReaderSize(strings.NewReader(input), 64)

	line, oversize, err := readBridgeStdoutLine(reader, max)
	if oversize || err != nil || string(bytes.TrimSpace(line)) != "first line" {
		t.Fatalf("第一行应正常读取：line=%q oversize=%v err=%v", line, oversize, err)
	}

	line, oversize, err = readBridgeStdoutLine(reader, max)
	if !oversize || err != nil {
		t.Fatalf("超限行应返回 oversize 且不报错：oversize=%v err=%v", oversize, err)
	}
	if line != nil {
		t.Fatalf("超限行不应残留内容，避免内存放大：len=%d", len(line))
	}

	line, oversize, err = readBridgeStdoutLine(reader, max)
	if oversize || err != nil || string(bytes.TrimSpace(line)) != "third line" {
		t.Fatalf("丢弃超限行后应能继续读取后续正常帧：line=%q oversize=%v err=%v", line, oversize, err)
	}
}

// 结尾没有换行的最后一帧要连同 io.EOF 一起返回，让调用方先转发再收口，不丢最后一条消息。
func TestReadBridgeStdoutLineReturnsFinalUnterminatedLineWithEOF(t *testing.T) {
	reader := bufio.NewReaderSize(strings.NewReader("only line no newline"), 64)
	line, oversize, err := readBridgeStdoutLine(reader, 1<<20)
	if oversize {
		t.Fatalf("正常尾行不应判为 oversize")
	}
	if err != io.EOF {
		t.Fatalf("尾行应携带 io.EOF：err=%v", err)
	}
	if string(line) != "only line no newline" {
		t.Fatalf("尾行内容应完整返回：line=%q", line)
	}
}

// max<=0 表示不设上限：任意长度的行都完整返回，永不判 oversize。
func TestReadBridgeStdoutLineNoLimitReadsFullLine(t *testing.T) {
	big := strings.Repeat("y", 8<<10)
	reader := bufio.NewReaderSize(strings.NewReader(big+"\n"), 64)
	line, oversize, err := readBridgeStdoutLine(reader, 0)
	if oversize || err != nil {
		t.Fatalf("无上限时不应判 oversize 也不应报错：oversize=%v err=%v", oversize, err)
	}
	if string(bytes.TrimSpace(line)) != big {
		t.Fatalf("无上限时应完整返回整行：len=%d want=%d", len(bytes.TrimSpace(line)), len(big))
	}
}

func TestClaudeGatewayInheritsProxyEnvironmentAndAllowsConfigOverride(t *testing.T) {
	isolateProxyEnvironment(t)
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:10808")
	t.Setenv("http_proxy", "http://127.0.0.1:10808")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:10808")
	t.Setenv("NO_PROXY", "localhost,127.0.0.1")
	env := buildClaudeBridgeEnv(map[string]string{
		"https_proxy": "http://127.0.0.1:18080",
	})

	values := map[string]string{}
	for _, item := range env {
		key, value, ok := strings.Cut(item, "=")
		if ok {
			canonical := strings.ToUpper(key)
			if _, exists := values[canonical]; exists {
				t.Fatalf("代理环境变量不应因大小写重复：%v", env)
			}
			values[canonical] = value
		}
	}
	if values["HTTP_PROXY"] != "http://127.0.0.1:10808" ||
		values["HTTPS_PROXY"] != "http://127.0.0.1:18080" ||
		values["NO_PROXY"] != "localhost,127.0.0.1" {
		t.Fatalf("Claude bridge 应继承代理并允许 claude.env 覆盖：%v", values)
	}
}

// isolateProxyEnvironment 清掉运行测试的 shell 继承来的代理变量，避免宿主的
// no_proxy、https_proxy 等按小写优先规则盖过测试设定的值。claudeenv.Build 还会按
// 大小写不敏感回退到 Http_Proxy 这类混合写法，所以也清掉进程环境里所有同组键。
// t.Setenv 先登记还原宿主值。
func isolateProxyEnvironment(t *testing.T) {
	t.Helper()
	aliases := []string{"https_proxy", "http_proxy", "all_proxy", "no_proxy"}
	keys := map[string]struct{}{}
	for _, alias := range aliases {
		keys[alias] = struct{}{}
		keys[strings.ToUpper(alias)] = struct{}{}
	}
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		for _, alias := range aliases {
			if key != "" && strings.EqualFold(key, alias) {
				keys[key] = struct{}{}
			}
		}
	}
	sorted := make([]string, 0, len(keys))
	for key := range keys {
		sorted = append(sorted, key)
	}
	sort.Strings(sorted)
	for _, key := range sorted {
		t.Setenv(key, "")
		if err := os.Unsetenv(key); err != nil {
			t.Fatalf("unset %s: %v", key, err)
		}
	}
}
