//go:build darwin

package appserver

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestSharedLocalModelDiscoveryKeepsCLIChoice(t *testing.T) {
	for _, tc := range []struct {
		name, output, want string
		fails              bool
	}{
		{"default enabled", "api_key_model_discovery stable true", "true", false},
		{"user disabled", "api_key_model_discovery under development false", "false", false},
		{"older CLI", "code_mode_host stable true", "", false},
		{"invalid value", "api_key_model_discovery stable unknown", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			bin := filepath.Join(home, "codex")
			// 探测必须使用后台相同的 cwd/CODEX_HOME，且仅调用 features list。
			script := "#!/bin/sh\n" +
				"test \"$1 $2\" = 'features list' || exit 1\n" +
				"test \"$PWD\" = \"$HOME\" || exit 2\n" +
				"test \"$CODEX_HOME\" = \"$HOME/.codex\" || exit 3\n" +
				"printf '%s\\n' '" + tc.output + "'\n"
			if err := os.WriteFile(bin, []byte(script), 0o700); err != nil {
				t.Fatal(err)
			}
			args, err := sharedLocalAppServerArgs(context.Background(), bin, map[string]string{
				"HOME": home, "CODEX_HOME": filepath.Join(home, ".codex"),
			}, "unix://example.sock")
			if (err != nil) != tc.fails {
				t.Fatalf("args=%v err=%v", args, err)
			}
			joined := strings.Join(args, " ")
			if tc.want == "" {
				if strings.Contains(joined, modelDiscoveryFeature) {
					t.Fatalf("不得向旧 CLI 或未知设置传递覆盖值: %v", args)
				}
			} else if !strings.Contains(joined, "features."+modelDiscoveryFeature+"="+tc.want) {
				t.Fatalf("没有保留 CLI 的 %s 设置: %v", tc.want, args)
			}
		})
	}
}

func TestSharedLocalModelDiscoveryProbeFailureDoesNotClaimCompatible(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, "codex")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\nprintf 'private diagnostic' >&2\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	_, err := sharedLocalAppServerArgs(context.Background(), bin, map[string]string{"HOME": home}, "unix://example.sock")
	if err == nil || strings.Contains(err.Error(), "private diagnostic") {
		t.Fatalf("探测失败必须返回脱敏错误: %v", err)
	}
}

func TestFrontDoorRuntimeFeatureReadback(t *testing.T) {
	for _, tc := range []struct {
		name               string
		pages              []map[string]any
		enabled, wantError bool
	}{
		{"enabled", []map[string]any{{"data": []any{map[string]any{"name": modelDiscoveryFeature, "enabled": true}}}}, true, false},
		{"disabled", []map[string]any{{"data": []any{map[string]any{"name": modelDiscoveryFeature, "enabled": false}}}}, false, false},
		{"paginated", []map[string]any{{"data": []any{}, "nextCursor": "next"}, {"data": []any{map[string]any{"name": modelDiscoveryFeature, "enabled": true}}}}, true, false},
		{"old backend missing flag", []map[string]any{{"data": []any{}}}, false, false},
		{"invalid response", []map[string]any{{}}, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := shortSharedLocalCodexHome(t)
			socket := filepath.Join(home, "features.sock")
			listener, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer conn.Close()
				var request map[string]any
				if conn.ReadJSON(&request) != nil {
					return
				}
				_ = conn.WriteJSON(map[string]any{"id": request["id"], "result": map[string]any{"userAgent": "codex/0.161.0"}})
				if conn.ReadJSON(&request) != nil { // initialized
					return
				}
				for _, page := range tc.pages {
					if conn.ReadJSON(&request) != nil {
						return
					}
					// 通知与其他请求响应不得污染本次功能读取。
					_ = conn.WriteJSON(map[string]any{"method": "config/updated", "params": map[string]any{}})
					_ = conn.WriteJSON(map[string]any{"id": 999, "result": map[string]any{}})
					_ = conn.WriteJSON(map[string]any{"id": request["id"], "result": page})
				}
			})}
			go func() { _ = server.Serve(listener) }()
			defer server.Close()
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			version, enabled, err := frontDoorRuntimeState(ctx, socket, home, false, true)
			if (err != nil) != tc.wantError || (!tc.wantError && (enabled != tc.enabled || version != "0.161.0")) {
				t.Fatalf("version=%s enabled=%v err=%v", version, enabled, err)
			}
		})
	}
}
