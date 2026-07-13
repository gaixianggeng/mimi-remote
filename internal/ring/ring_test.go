package ring

import "testing"

func TestBufferKeepsRecentBytes(t *testing.T) {
	b := New(5)
	b.Write([]byte("hello"))
	b.Write([]byte(" world"))
	if got := b.String(); got != "world" {
		t.Fatalf("期望保留最近输出 world，实际 %q", got)
	}
}

func TestBufferKeepsTailOfOversizedChunk(t *testing.T) {
	b := New(5)
	b.Write([]byte("old"))
	b.Write([]byte("0123456789"))
	if got := b.String(); got != "56789" {
		t.Fatalf("期望超大块只保留尾部 56789，实际 %q", got)
	}
}

func TestBufferReusesWindowAcrossSmallChunks(t *testing.T) {
	b := New(8)
	b.Write([]byte("abcd"))
	b.Write([]byte("ef"))
	b.Write([]byte("ghij"))
	if got := b.String(); got != "cdefghij" {
		t.Fatalf("期望跨小块保留最近窗口 cdefghij，实际 %q", got)
	}
}
