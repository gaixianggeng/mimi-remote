package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestTailcatConfigureRequiresExplicitDERPMapFlag(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	err := runTailcatWithWriters([]string{"tailcat", "configure"}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--derp-map-url") {
		t.Fatalf("configure 未显式指定中继时必须失败：%v", err)
	}

	err = runTailcatWithWriters(
		[]string{"tailcat", "enable", "--derp-map-url=https://relay.example/map"},
		&stdout,
		&stderr,
	)
	if err == nil || !strings.Contains(err.Error(), "只适用于 tailcat configure") {
		t.Fatalf("其他子命令不能接受中继参数：%v", err)
	}
}

func TestPrintTailcatStatusIncludesRelayMode(t *testing.T) {
	var output bytes.Buffer
	printTailcatStatus(&output, tailcatCommandStatus{Enabled: true, Running: true})
	if !strings.Contains(output.String(), "中继：Tailcat 默认") {
		t.Fatalf("默认中继未展示：%s", output.String())
	}

	output.Reset()
	printTailcatStatus(&output, tailcatCommandStatus{
		Enabled:    true,
		Running:    true,
		DERPMapURL: "https://relay.example/derpmap/default",
	})
	if !strings.Contains(output.String(), "中继：https://relay.example/derpmap/default") {
		t.Fatalf("自定义中继未展示：%s", output.String())
	}
}
