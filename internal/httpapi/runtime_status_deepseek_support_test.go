package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// writeDeepSeekTestTokenFile 写一个 0600 的 token 文件，返回其路径。
func writeDeepSeekTestTokenFile(t *testing.T, token string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "deepseek.token")
	if err := os.WriteFile(path, []byte(token), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// fakeDeepSeekHarness 是运行态探测所需的最小 Harness 替身：认证握手 + Connection RPC。
//
// 原 app-server 适配层的替身随该层一起删除。运行态探测（runtime_status_deepseek.go）
// 仍要验"握手 + 模型目录"，因此保留这份只覆盖 `session/modelCatalog` 的精简版本，
// 不引入 remote.mux 订阅等探测用不到的协议面。
type fakeDeepSeekHarness struct {
	t        *testing.T
	token    string
	handlers map[string]func(json.RawMessage) (any, *harnessclient.RemoteError)
}

func newFakeDeepSeekHarness(t *testing.T) *fakeDeepSeekHarness {
	t.Helper()
	return &fakeDeepSeekHarness{
		t:        t,
		token:    "harness-startup-token-fixture",
		handlers: map[string]func(json.RawMessage) (any, *harnessclient.RemoteError){},
	}
}

func (f *fakeDeepSeekHarness) handle(method string, handler func(json.RawMessage) (any, *harnessclient.RemoteError)) {
	f.handlers[method] = handler
}

func (f *fakeDeepSeekHarness) serve() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		if r.URL.Query().Get("token") != f.token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		// 认证是一次 303 握手：普通 API 不接受 Authorization 头，只认这个 Cookie。
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "cookie-fixture", Path: "/"})
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		if _, err := r.Cookie("harness_session"); err != nil {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		method := strings.TrimPrefix(r.URL.Path, "/api/")
		var envelope map[string]any
		if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		payload, _ := envelope["payload"].(map[string]any)
		rawArgs, _ := json.Marshal(payload["args"])
		handler := f.handlers[method]
		if handler == nil {
			f.writeEnvelope(w, envelope, nil, &harnessclient.RemoteError{Code: "gateway/internal", Message: method})
			return
		}
		value, remoteErr := handler(rawArgs)
		f.writeEnvelope(w, envelope, value, remoteErr)
	})
	server := httptest.NewServer(mux)
	f.t.Cleanup(server.Close)
	return server
}

func (f *fakeDeepSeekHarness) writeEnvelope(
	w http.ResponseWriter,
	envelope map[string]any,
	value any,
	remoteErr *harnessclient.RemoteError,
) {
	rpcID, _ := envelope["rpcId"].(string)
	result := map[string]any{"ok": remoteErr == nil}
	if remoteErr == nil {
		result["value"] = value
	} else {
		result["error"] = remoteErr
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]any{
		"type":   "server-response",
		"rpcId":  rpcID,
		"result": result,
	}); err != nil {
		f.t.Errorf("写出应答失败：%v", err)
	}
}
