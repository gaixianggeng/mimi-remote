package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRuntimeRestartInterlockRejectsMissingConfirmationFlag(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := runRuntimeWithWriters(
		[]string{"runtime", "--codex-sharing-restart"},
		&stdout,
		&stderr,
	)
	if err == nil || !strings.Contains(err.Error(), "防误触") {
		t.Fatalf("缺少双 flag 时必须阻止误触破坏性迁移：%v", err)
	}
}
