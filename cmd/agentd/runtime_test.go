package main

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func TestConfirmedDisableTimeoutCoversLockWaitAndDaemonTransaction(t *testing.T) {
	const minimumInnerBudget = 15*time.Second + 90*time.Second
	if confirmedCodexSharingDisableTimeout <= minimumInnerBudget {
		t.Fatalf(
			"confirmed disable timeout 必须覆盖锁等待、daemon stop 与后置复核：%s",
			confirmedCodexSharingDisableTimeout,
		)
	}
}

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

func TestRuntimeCodexSharingDisableConfirmationRequiresDisabledMode(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{
			name: "without mode",
			args: []string{"runtime", "--codex-sharing-disable-confirmed"},
		},
		{
			name: "enabled mode",
			args: []string{"runtime", "--codex-sharing=enabled", "--codex-sharing-disable-confirmed"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			err := runRuntimeWithWriters(test.args, &stdout, &stderr)
			if err == nil || !strings.Contains(err.Error(), "--codex-sharing=disabled") {
				t.Fatalf("confirmed disable 必须只允许 disabled 模式：%v", err)
			}
		})
	}
}
