package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

func TestCodexSessionRepairRequiresConfirmationAndLocalConfig(t *testing.T) {
	previous := releaseSharedCodexSession
	t.Cleanup(func() { releaseSharedCodexSession = previous })
	releaseSharedCodexSession = func(context.Context, appserver.SharedLocalOptions) (appserver.SharedLocalSessionRepairResult, error) {
		t.Fatal("拒绝路径不能释放进程")
		return appserver.SharedLocalSessionRepairResult{}, nil
	}
	for _, tc := range []struct {
		name string
		body string
		args []string
	}{
		{"missing confirmation", `{}`, nil},
		{"positional argument", `{}`, []string{"--confirm-disconnected", "unexpected"}},
		{"missing config", "", []string{"--confirm-disconnected"}},
		{"invalid config", `{`, []string{"--confirm-disconnected"}},
		{"disabled", `{"app_server":{"transport":"local"},"codex":{"enabled":false}}`, []string{"--confirm-disconnected"}},
		{"remote", `{"app_server":{"transport":"ssh","ssh_target":"example.invalid"}}`, []string{"--confirm-disconnected"}},
		{"mixed target", `{"app_server":{"transport":"local","ssh_target":"example.invalid"}}`, []string{"--confirm-disconnected"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.json")
			if tc.body != "" {
				if err := os.WriteFile(path, []byte(tc.body), 0600); err != nil {
					t.Fatal(err)
				}
			}
			args := append([]string{"repair-codex-session", "--config", path, "--json"}, tc.args...)
			var output bytes.Buffer
			if err := runCodexSessionRepairWithWriters(args, &output, io.Discard); err == nil {
				t.Fatal("应明确拒绝")
			}
			if output.Len() != 0 {
				t.Fatal("失败不能输出成功 JSON")
			}
		})
	}
}

func TestCodexSessionRepairReturnsReleaseOutcomeWithoutChangingConfig(t *testing.T) {
	previous := releaseSharedCodexSession
	t.Cleanup(func() { releaseSharedCodexSession = previous })
	path := filepath.Join(t.TempDir(), "config.json")
	body := []byte(`{"app_server":{"transport":"local"},"codex":{"bin":"codex-test","env":{"CODEX_HOME":"/tmp/repair-test-only"}}}`)
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	for _, released := range []bool{true, false} {
		releaseSharedCodexSession = func(ctx context.Context, options appserver.SharedLocalOptions) (appserver.SharedLocalSessionRepairResult, error) {
			if _, ok := ctx.Deadline(); !ok {
				t.Fatal("释放必须有总超时")
			}
			if options.CodexBin != "codex-test" || options.Env["CODEX_HOME"] != "/tmp/repair-test-only" {
				t.Fatalf("未传递配置的目标：%+v", options)
			}
			return appserver.SharedLocalSessionRepairResult{Released: released, Message: "checked"}, nil
		}
		var output bytes.Buffer
		err := runCodexSessionRepairWithWriters([]string{"repair-codex-session", "--config", path, "--confirm-disconnected", "--json"}, &output, io.Discard)
		if err != nil {
			t.Fatal(err)
		}
		var result map[string]any
		if err := json.Unmarshal(output.Bytes(), &result); err != nil || result["released"] != released || result["message"] != "checked" {
			t.Fatalf("错误的结果：%s (%v)", output.String(), err)
		}
	}
	releaseSharedCodexSession = func(context.Context, appserver.SharedLocalOptions) (appserver.SharedLocalSessionRepairResult, error) {
		return appserver.SharedLocalSessionRepairResult{}, errors.New("busy")
	}
	var output bytes.Buffer
	if err := runCodexSessionRepairWithWriters([]string{"repair-codex-session", "--config", path, "--confirm-disconnected", "--json"}, &output, io.Discard); err == nil || output.Len() != 0 {
		t.Fatal("有活动任务时必须返回失败而不是 released=false 成功")
	}
	current, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(current, body) {
		t.Fatal("一次性修复不应修改配置")
	}
}
