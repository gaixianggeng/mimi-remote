package httpapi

import (
	"bufio"
	"bytes"
	"io"
	"strings"
	"testing"
)

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
