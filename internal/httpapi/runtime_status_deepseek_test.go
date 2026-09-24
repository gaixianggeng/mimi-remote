package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

func TestDeepSeekRuntimeStatusRequiresAuthenticatedModels(t *testing.T) {
	for _, tc := range []struct {
		name, token, models string
		want                runtimeConnectionState
	}{
		{"ready", "", `{"groups":[{"id":"fixture","models":[{"id":"model-a"}]}]}`, runtimeStateAvailable},
		{"invalid credential", "invalid-private-credential", `{"groups":[]}`, runtimeStateUnavailable},
		{"no models", "", `{"groups":[]}`, runtimeStateUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			harness := newFakeDeepSeekHarness(t)
			harness.handle(harnessclient.MethodSessionModelCatalog, func(json.RawMessage) (any, *harnessclient.RemoteError) {
				return json.RawMessage(tc.models), nil
			})
			hs := harness.serve()
			token := tc.token
			if token == "" {
				token = harness.token
			}
			router := &Router{cfg: config.Config{DeepSeek: config.DeepSeekConfig{
				Enabled: true, BaseURL: hs.URL, TokenFile: writeDeepSeekTestTokenFile(t, token),
			}}}
			status := router.probeDeepSeekRuntime(context.Background())
			if status.ID != "deepseek" || !status.Enabled || status.State != tc.want {
				t.Fatalf("DeepSeek 运行态不符：%+v", status)
			}
			raw, err := json.Marshal(status)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(raw), token) || strings.Contains(string(raw), hs.URL) {
				t.Fatal("运行态不得带入凭据或服务私有地址")
			}
		})
	}
}

func TestDeepSeekRuntimeStatusPlaceholderOnlyAddsEnabledExperiment(t *testing.T) {
	router := &Router{cfg: config.Config{}}
	if got := router.runtimeStatusPlaceholder(); len(got.Runtimes) != 2 {
		t.Fatalf("未启用的 DeepSeek 不扩展默认运行态：%+v", got.Runtimes)
	}
	router.cfg.DeepSeek.Enabled = true
	got := router.runtimeStatusPlaceholder()
	if len(got.Runtimes) != 3 || got.Runtimes[2].ID != "deepseek" || got.Runtimes[2].Reason != "refresh_in_progress" {
		t.Fatalf("已启用 DeepSeek 必须有真实状态占位：%+v", got.Runtimes)
	}
}

func TestDeepSeekRuntimeStatusDoesNotBlockOnCredentialPipe(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("/dev/fd 是 Unix 文件接口")
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	router := &Router{cfg: config.Config{DeepSeek: config.DeepSeekConfig{
		Enabled: true, TokenFile: fmt.Sprintf("/dev/fd/%d", reader.Fd()),
	}}}
	done := make(chan runtimeAccountStatus, 1)
	go func() { done <- router.probeDeepSeekRuntime(context.Background()) }()
	select {
	case status := <-done:
		if status.Reason != "credentials_unavailable" {
			t.Fatalf("非普通文件必须被拒绝：%+v", status)
		}
	case <-time.After(time.Second):
		t.Fatal("凭据管道不得阻塞运行态探测")
	}
}
