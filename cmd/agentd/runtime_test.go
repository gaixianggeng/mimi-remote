package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRuntimeRejectsUnconfirmedSharedDaemonRestart(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := runRuntimeWithWriters(
		[]string{"runtime", "--codex-sharing-restart"},
		&stdout,
		&stderr,
	)
	if err == nil || !strings.Contains(err.Error(), "仅供 Mac App") {
		t.Fatalf("普通 CLI 不能绕过 Desktop 正常退出与设置页确认：%v", err)
	}
}
