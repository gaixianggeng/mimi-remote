package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// 按仓库查询的 thread/list 可能带回仓库外兄弟 worktree 的会话（Claude 适配器按
// `listSessions({ dir })` 语义返回同仓所有 worktree）。同仓会话必须能打开且只读，
// 无关仓库的会话仍不得授权。
func TestScopedThreadListAuthorizesSameRepositoryWorktreesReadOnly(t *testing.T) {
	browseRoot := t.TempDir()
	var projectDir, externalWorktree, otherRepo string

	upstreamURL, _, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params map[string]any  `json:"params"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("fake upstream 收到无效 JSON：%v", err)
			return
		}
		switch frame.Method {
		case "thread/list":
			_ = conn.WriteJSON(map[string]any{
				"jsonrpc": "2.0", "id": json.RawMessage(frame.ID),
				"result": map[string]any{
					"data": []any{
						map[string]any{"id": "thread-root", "cwd": projectDir, "canAcceptDirectInput": true},
						map[string]any{"id": "thread-sibling", "cwd": externalWorktree, "canAcceptDirectInput": true},
						map[string]any{"id": "thread-other", "cwd": otherRepo, "canAcceptDirectInput": true},
						map[string]any{"id": "thread-deleted", "cwd": filepath.Join(browseRoot, "deleted-worktree")},
					},
					"nextCursor": "keep-me",
				},
			})
		case "thread/read":
			threadID, _ := frame.Params["threadId"].(string)
			cwd := map[string]string{"thread-root": projectDir, "thread-sibling": externalWorktree, "thread-other": otherRepo}[threadID]
			_ = conn.WriteJSON(map[string]any{
				"jsonrpc": "2.0", "id": json.RawMessage(frame.ID),
				"result": map[string]any{
					"thread": map[string]any{"id": threadID, "cwd": cwd, "canAcceptDirectInput": true},
				},
			})
		}
	})
	handler, dir := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.BrowseRoots = []string{browseRoot}
	})
	projectDir = dir
	runGitTestCommand(t, projectDir, "init")
	runGitTestCommand(t, projectDir, "config", "user.email", "gh656@example.invalid")
	runGitTestCommand(t, projectDir, "config", "user.name", "gh-656")
	if err := os.WriteFile(filepath.Join(projectDir, "README.md"), []byte("gh656\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, projectDir, "add", "README.md")
	runGitTestCommand(t, projectDir, "commit", "-m", "initial")
	externalWorktree = filepath.Join(browseRoot, "sibling-worktree")
	runGitTestCommand(t, projectDir, "worktree", "add", "-b", "gh656-sibling", externalWorktree)
	t.Cleanup(func() {
		_ = exec.Command("git", "-C", projectDir, "worktree", "remove", "--force", externalWorktree).Run()
	})
	otherRepo = filepath.Join(browseRoot, "unrelated-repository")
	if err := os.MkdirAll(otherRepo, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitTestCommand(t, otherRepo, "init")

	server := httptest.NewServer(handler)
	defer server.Close()
	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()

	if err := conn.WriteJSON(map[string]any{
		"id": 900, "method": "thread/list",
		"params": map[string]any{"cwd": projectDir, "limit": 50},
	}); err != nil {
		t.Fatal(err)
	}
	var list struct {
		Result struct {
			Data []struct {
				ID string `json:"id"`
			} `json:"data"`
			NextCursor string `json:"nextCursor"`
		} `json:"result"`
	}
	listRaw := readGatewayRaw(t, conn)
	if err := json.Unmarshal(listRaw, &list); err != nil {
		t.Fatal(err)
	}
	var listed []string
	for _, item := range list.Result.Data {
		listed = append(listed, item.ID)
	}
	// 只保留能打开的会话：无关仓库与工作目录已删除的条目都要从列表里去掉。
	if strings.Join(listed, ",") != "thread-root,thread-sibling" || list.Result.NextCursor != "keep-me" {
		t.Fatalf("按仓库列表应只含可打开的会话并保留分页游标：%s", listRaw)
	}

	readThread := func(id int, threadID string) []byte {
		t.Helper()
		if err := conn.WriteJSON(map[string]any{
			"id": id, "method": "thread/read", "params": map[string]any{"threadId": threadID},
		}); err != nil {
			t.Fatal(err)
		}
		return readGatewayRaw(t, conn)
	}
	canInput := func(raw []byte) *bool {
		t.Helper()
		var response struct {
			Result struct {
				Thread struct {
					CanAcceptDirectInput *bool `json:"canAcceptDirectInput"`
				} `json:"thread"`
			} `json:"result"`
		}
		if err := json.Unmarshal(raw, &response); err != nil {
			t.Fatal(err)
		}
		return response.Result.Thread.CanAcceptDirectInput
	}

	if got := canInput(readThread(901, "thread-root")); got == nil || !*got {
		t.Fatalf("仓库根会话应保留写能力")
	}
	sibling := readThread(902, "thread-sibling")
	if strings.Contains(string(sibling), "未由当前 gateway 连接授权") {
		t.Fatalf("同仓兄弟 worktree 会话应能打开：%s", sibling)
	}
	if got := canInput(sibling); got == nil || *got {
		t.Fatalf("browse 作用域的同仓 worktree 会话必须只读：%s", sibling)
	}
	if other := readThread(903, "thread-other"); !strings.Contains(string(other), "未由当前 gateway 连接授权") {
		t.Fatalf("无关仓库的会话不得授权：%s", other)
	}
}
