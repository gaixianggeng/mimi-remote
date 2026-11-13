package tailcatevents

import (
	"bytes"
	"strings"
	"sync"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/debuglog"
)

type lockedBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (b *lockedBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.Write(data)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.String()
}

func installTestSink(t *testing.T) (*lockedBuffer, func()) {
	t.Helper()
	output := &lockedBuffer{}
	sink := debuglog.New(output, func() bool { return true })
	remove := Install(sink)
	flush := func() {
		if err := sink.Sync(func() error { return nil }); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		remove()
		sink.Close()
	})
	return output, flush
}

func TestRecordSidecarLineRendersWhitelistedFields(t *testing.T) {
	output, flush := installTestSink(t)
	if !RecordSidecarLine(LinePrefix + `{"event":"derp_lost","peer":"[SbEMg]","region":901,"reason":"timeout","ms":1200}`) {
		t.Fatal("结构化事件应被识别")
	}
	flush()
	line := output.String()
	for _, want := range []string{"tailcat event=derp_lost", "peer=[SbEMg]", "region=901", "reason=timeout", "ms=1200"} {
		if !strings.Contains(line, want) {
			t.Fatalf("缺少 %q：%s", want, line)
		}
	}
}

func TestRecordSidecarLineDropsUnsafeValues(t *testing.T) {
	output, flush := installTestSink(t)
	cases := []string{
		`{"event":"made_up","reason":"timeout"}`,
		`not json 203.0.113.9`,
	}
	for _, payload := range cases {
		if !RecordSidecarLine(LinePrefix + payload) {
			t.Fatalf("带前缀的行应被消费：%s", payload)
		}
	}
	RecordSidecarLine(LinePrefix + `{"event":"path_direct","peer":"203.0.113.9:41641","reason":"via 203.0.113.9"}`)
	flush()
	text := output.String()
	if strings.Contains(text, "made_up") || strings.Contains(text, "203.0.113.9") {
		t.Fatalf("不安全内容进入了日志：%s", text)
	}
	if !strings.Contains(text, "event=path_direct") {
		t.Fatalf("合法事件名应保留、非法字段被丢弃：%s", text)
	}
}

func TestPlainSidecarLinesAreRedacted(t *testing.T) {
	output, flush := installTestSink(t)
	key := "nodekey:" + strings.Repeat("ab", 32)
	if RecordSidecarLine("Tailcat 实验失败：dial 203.0.113.9:8443 [2001:db8::1]:41641 " + key) {
		t.Fatal("普通文本不是结构化事件")
	}
	flush()
	text := output.String()
	for _, secret := range []string{"203.0.113.9", "2001:db8", key} {
		if strings.Contains(text, secret) {
			t.Fatalf("未脱敏 %q：%s", secret, text)
		}
	}
	if !strings.Contains(text, "event=sidecar_log") || !strings.Contains(text, "Tailcat 实验失败") {
		t.Fatalf("错误摘要应保留：%s", text)
	}
}

func TestRedactKeepsTimesAndPlainWords(t *testing.T) {
	for _, keep := range []string{"exit status 1", "pair: 短期配对节点启动耗时 1.2s", "signal: killed", "12:30:45"} {
		if got := Redact(keep); got != keep {
			t.Errorf("Redact(%q) = %q", keep, got)
		}
	}
	if got := Redact(strings.Repeat("a", 50)); strings.Contains(got, "aaaa") {
		t.Errorf("长地址串未脱敏：%q", got)
	}
}

func TestRecordWithoutSinkIsNoop(t *testing.T) {
	Record(EventSidecarStarted, "")
	if !RecordSidecarLine(LinePrefix + `{"event":"conn_opened"}`) {
		t.Fatal("没有日志时也要消费结构化事件")
	}
}
