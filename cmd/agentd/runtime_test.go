package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRuntimeLegacyCleanupRequiresDesktopSyncOperation(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := runRuntimeWithWriters(
		[]string{"runtime", "--cleanup-legacy-sharing-confirmed"},
		&stdout,
		&stderr,
	)
	if err == nil || !strings.Contains(err.Error(), "--codex-desktop-sync") {
		t.Fatalf("遗留清理必须绑定 Desktop sync 操作：%v", err)
	}
}

func TestDesktopSyncModeRejectsUnknownValue(t *testing.T) {
	_, err := parseEnabledDisabled("sometimes")
	if err == nil || !strings.Contains(err.Error(), "--codex-desktop-sync") {
		t.Fatalf("未知 Desktop sync 模式必须报错：%v", err)
	}
}
