package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

type sharedFileReferenceCase struct {
	Name     string   `json:"name"`
	Text     string   `json:"text"`
	Expected []string `json:"expected"`
}

// 与 iOS MarkdownRenderingTests 读同一份用例：两侧规则漂移时这里先失败。
func TestAgentTextFileReferencePathsMatchesSharedDetectorCases(t *testing.T) {
	data, err := os.ReadFile("../../contracts/file-references/detector-cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []sharedFileReferenceCase `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("共享用例表不能为空")
	}
	for _, testCase := range fixture.Cases {
		got := agentTextFileReferencePaths(testCase.Text)
		if len(got) == 0 && len(testCase.Expected) == 0 {
			continue
		}
		if !reflect.DeepEqual(got, testCase.Expected) {
			t.Errorf("%s：got=%q want=%q", testCase.Name, got, testCase.Expected)
		}
	}
}

func collectAgentProducedFilePathsFromJSON(t *testing.T, payload string) []string {
	t.Helper()
	var root any
	if err := json.Unmarshal([]byte(payload), &root); err != nil {
		t.Fatal(err)
	}
	var paths []string
	collectAgentProducedFilePaths(root, func(path string) { paths = append(paths, path) })
	sort.Strings(paths)
	return paths
}

func TestCollectAgentProducedFilePathsIgnoresUserMessagesAndToolOutput(t *testing.T) {
	payload := `{"id":1,"result":{"thread":{"id":"t","turns":[{"id":"turn","items":[
		{"type":"userMessage","content":[{"type":"text","text":"看 /tmp/user.png"}]},
		{"type":"commandExecution","command":"ls /tmp/cmd.png","aggregatedOutput":"saved /tmp/output.png"},
		{"type":"mcpToolCall","result":{"structuredContent":{"type":"agentMessage","text":"/tmp/nested.png"}}},
		{"type":"dynamicToolCall","contentItems":[{"type":"inputText","text":"/tmp/dynamic.png"}]},
		{"type":"reasoning","summary":["/tmp/reasoning.png"]},
		{"type":"agentMessage","text":"已生成 ` + "`/tmp/out/row.png`" + ` 和 [报告](/tmp/out/report.pdf)"},
		{"type":"imageView","path":"/tmp/out/viewed.png"},
		{"type":"imageGeneration","savedPath":"/tmp/out/generated.png"},
		{"type":"fileChange","changes":[{"path":"/tmp/out/notes.md","kind":{"type":"add"}}]}
	]}]}}}`
	got := collectAgentProducedFilePathsFromJSON(t, payload)
	want := []string{
		"/tmp/out/generated.png", "/tmp/out/notes.md", "/tmp/out/report.pdf", "/tmp/out/row.png", "/tmp/out/viewed.png",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("只应收集 AI 产出的路径：got=%q want=%q", got, want)
	}

	notification := `{"method":"item/completed","params":{"threadId":"t","item":{"type":"agentMessage","text":"见 /tmp/live.png"}}}`
	if got := collectAgentProducedFilePathsFromJSON(t, notification); !reflect.DeepEqual(got, []string{"/tmp/live.png"}) {
		t.Fatalf("item 通知里的助手正文应被收集：%q", got)
	}
}

func agentMessageNotification(threadID string, text string) []byte {
	encoded, _ := json.Marshal(text)
	return []byte(`{"method":"item/completed","params":{"threadId":"` + threadID +
		`","turnId":"turn","item":{"type":"agentMessage","id":"item","text":` + string(encoded) + `}}}`)
}

func writeSessionTempFile(t *testing.T, path string, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestFileReadAllowsOnlySessionReferencedTemporaryFiles(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不开放临时目录特例")
	}
	root := t.TempDir()
	outside := t.TempDir()
	server := newTestServer(t)
	server.router.sessionFileGrants = newSessionFileGrantStoreWithRoots([]string{root})

	referenced := filepath.Join(root, "out", "row.png")
	writeSessionTempFile(t, referenced, "png-bytes")
	unreferenced := filepath.Join(root, "out", "sheet.png")
	writeSessionTempFile(t, unreferenced, "png-bytes")
	missing := filepath.Join(root, "out", "missing.png")
	secret := filepath.Join(outside, "secret.png")
	writeSessionTempFile(t, secret, "secret")
	symlinked := filepath.Join(root, "out", "link.png")
	if err := os.Symlink(secret, symlinked); err != nil {
		t.Fatal(err)
	}
	hardSource := filepath.Join(root, "out", "hard-source.png")
	writeSessionTempFile(t, hardSource, "png-bytes")
	hardLinked := filepath.Join(root, "out", "hard.png")
	if err := os.Link(hardSource, hardLinked); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	escaped := filepath.Join(root, "escape", "secret.png")
	dotted := filepath.Join(root, "out") + "/../out/row.png"

	server.router.observeAgentProducedFiles(agentMessageNotification("thread", strings.Join([]string{
		"`" + referenced + "`", "`" + missing + "`", "`" + symlinked + "`", "`" + hardLinked + "`",
		"`" + escaped + "`", "`" + secret + "`", "`" + dotted + "`",
	}, "\n")))

	rec, body := readPreviewFile(t, server.handler, referenced)
	if rec.Code != http.StatusOK {
		t.Fatalf("AI 提到的临时文件应可预览，got=%d body=%s", rec.Code, rec.Body.String())
	}
	realReferenced, err := filepath.EvalSymlinks(referenced)
	if err != nil {
		t.Fatal(err)
	}
	if body["path"] != realReferenced || body["name"] != "row.png" || body["content_type"] != "image/png" {
		t.Fatalf("响应应返回真实路径和按扩展名识别的类型：%v", body)
	}

	cases := []struct {
		name string
		path string
		code string
	}{
		{name: "同目录但没被提到", path: unreferenced, code: fileReadCodePathOutsideScope},
		{name: "提到过但已被清理", path: missing, code: fileReadCodeNotFound},
		{name: "最终文件是符号链接", path: symlinked, code: fileReadCodePathOutsideScope},
		{name: "硬链接", path: hardLinked, code: fileReadCodePathOutsideScope},
		{name: "上级目录经符号链接跳出临时目录", path: escaped, code: fileReadCodePathOutsideScope},
		{name: "临时目录之外", path: secret, code: fileReadCodePathOutsideScope},
		{name: "含 .. 的路径", path: dotted, code: fileReadCodePathOutsideScope},
	}
	for _, testCase := range cases {
		rec, _ := readPreviewFile(t, server.handler, testCase.path)
		if rec.Code != http.StatusForbidden {
			t.Errorf("%s：应拒绝，got=%d body=%s", testCase.name, rec.Code, rec.Body.String())
			continue
		}
		var payload fileReadErrorResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		if payload.Code != testCase.code {
			t.Errorf("%s：错误码应为 %s，got=%s", testCase.name, testCase.code, payload.Code)
		}
	}
}

func TestSessionFileGrantStoreRejectsNonPreviewTypesAndExpires(t *testing.T) {
	root := t.TempDir()
	store := newSessionFileGrantStoreWithRoots([]string{root})
	now := time.Unix(1_000, 0)
	store.now = func() time.Time { return now }
	store.ttl = time.Hour
	store.maxEntries = 2

	script := filepath.Join(root, "run.sh")
	first := filepath.Join(root, "a.png")
	second := filepath.Join(root, "b.png")
	third := filepath.Join(root, "c.png")
	store.grant([]string{script, "relative/d.png", first})
	if store.granted(script) {
		t.Fatal("不在预览类型内的文件不能登记")
	}
	if !store.granted(first) {
		t.Fatal("临时目录内的图片应登记")
	}

	now = now.Add(10 * time.Minute)
	store.grant([]string{second})
	now = now.Add(10 * time.Minute)
	store.grant([]string{third})
	if store.granted(first) || !store.granted(second) || !store.granted(third) {
		t.Fatal("超出容量时应淘汰最久没被提到的路径")
	}

	now = now.Add(55 * time.Minute)
	if store.granted(second) {
		t.Fatal("超过有效期的授权应失效")
	}
	store.grant([]string{third})
	now = now.Add(30 * time.Minute)
	if !store.granted(third) {
		t.Fatal("再次被提到时应刷新有效期")
	}
}

func newSessionFileGrantPolicyForTest(t *testing.T, runtimeID string) (*appServerGatewayPolicy, *Router, string) {
	t.Helper()
	root := t.TempDir()
	router := &Router{
		monitor:           newRelayMonitor(),
		historyMedia:      newAppServerHistoryMediaStore(),
		sessionFileGrants: newSessionFileGrantStoreWithRoots([]string{root}),
		gatewayThreads:    map[string]appServerGatewayAllowedThread{},
	}
	policy := &appServerGatewayPolicy{
		router:                router,
		runtimeID:             runtimeID,
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingHistory:        map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets:        map[string]appServerGatewayHistoryBudget{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
	}
	policy.allowThread(appServerGatewayAllowedThread{
		id: "allowed", runtimeID: runtimeID, cwd: "/repo", scopeID: "repo",
	})
	return policy, router, root
}

// skipWhereSessionFileGrantsDisabled：Windows 上 newSessionFileGrantStore 返回 nil（没有逐级
// O_NOFOLLOW 读取），iOS 也只识别 "/" 开头的路径，正向用例在那里不成立；关闭行为由
// TestSessionFileGrantsDisabledOnWindows 单独断言。
func skipWhereSessionFileGrantsDisabled(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不开放会话引用授权")
	}
}

func TestSessionFileGrantsDisabledOnWindows(t *testing.T) {
	store := newSessionFileGrantStore()
	if runtime.GOOS != "windows" {
		if store == nil {
			t.Fatal("非 Windows 平台应启用会话引用授权")
		}
		return
	}
	if store != nil {
		t.Fatal("Windows 不应启用会话引用授权")
	}
	router := &Router{sessionFileGrants: store}
	path := filepath.Join(os.TempDir(), "mentioned.png")
	router.observeAgentProducedFiles(agentMessageNotification("thread", "见 "+path))
	if _, candidate, err := router.resolveSessionReferencedTemporaryFile(path); candidate || err != nil {
		t.Fatalf("Windows 上任何路径都不应走会话引用授权：candidate=%v err=%v", candidate, err)
	}
}

func TestGatewayRecordsSessionFileGrantsOnlyFromAuthorizedAgentItems(t *testing.T) {
	skipWhereSessionFileGrantsDisabled(t)
	for _, runtimeID := range []string{"codex", "claude"} {
		policy, router, root := newSessionFileGrantPolicyForTest(t, runtimeID)
		allowedPath := filepath.Join(root, "allowed.png")
		otherThreadPath := filepath.Join(root, "other-thread.png")
		userPath := filepath.Join(root, "user.png")

		if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage,
			agentMessageNotification("allowed", "见 `"+allowedPath+"`")); !forward || policyErr != nil {
			t.Fatalf("%s：已授权 thread 的通知应转发：forward=%v err=%+v", runtimeID, forward, policyErr)
		}
		if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage,
			agentMessageNotification("desktop-only", "见 `"+otherThreadPath+"`")); forward {
			t.Fatalf("%s：未授权 thread 的通知不应转发", runtimeID)
		}
		userEcho, _ := json.Marshal("看 " + userPath)
		policy.observeUpstreamFrame(websocket.TextMessage, []byte(`{"method":"item/completed","params":{"threadId":"allowed",`+
			`"item":{"type":"userMessage","content":[{"type":"text","text":`+string(userEcho)+`}]}}}`))

		grants := router.sessionFileGrants
		if !grants.granted(allowedPath) {
			t.Fatalf("%s：已授权 thread 里 AI 提到的文件应登记", runtimeID)
		}
		if grants.granted(otherThreadPath) || grants.granted(userPath) {
			t.Fatalf("%s：未授权 thread 或用户消息里的路径不能登记", runtimeID)
		}
	}
}

func TestGatewayRecordsSessionFileGrantsFromForwardedHistoryPages(t *testing.T) {
	skipWhereSessionFileGrantsDisabled(t)
	policy, router, root := newSessionFileGrantPolicyForTest(t, "codex")
	referenced := filepath.Join(root, "history.pdf")
	requestID := json.RawMessage(`301`)
	params := map[string]any{"threadId": "allowed", "limit": json.Number("20"), "sortDirection": "desc"}
	if err := policy.reserveHistoryRequest(&requestID, "thread/turns/list", params, 128); err != nil {
		t.Fatalf("history 请求应可登记：%+v", err)
	}
	text, _ := json.Marshal("报告在 " + referenced)
	response := []byte(`{"id":301,"result":{"data":[{"id":"turn","items":[{"type":"agentMessage","id":"a","text":` +
		string(text) + `}]}]}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, response); !forward || policyErr != nil {
		t.Fatalf("history 响应应转发：forward=%v err=%+v", forward, policyErr)
	}
	if !router.sessionFileGrants.granted(referenced) {
		t.Fatal("转发给客户端的历史页里 AI 提到的文件应登记")
	}

	// 没有对应 pending 请求的响应不是本连接授权过的历史，不能成为证据。
	stray := filepath.Join(root, "stray.pdf")
	strayText, _ := json.Marshal("见 " + stray)
	policy.observeUpstreamFrame(websocket.TextMessage, []byte(`{"id":999,"result":{"data":[{"items":[{"type":"agentMessage","text":`+
		string(strayText)+`}]}]}}`))
	if router.sessionFileGrants.granted(stray) {
		t.Fatal("未登记的响应不能产生授权")
	}
}

// thread/read 的响应要先通过只读子会话的作用域校验才会转发；校验失败的响应即使带着 AI
// 提到的文件，也不能留下授权。
func TestGatewayDoesNotGrantFilesFromRejectedThreadReadResponse(t *testing.T) {
	skipWhereSessionFileGrantsDisabled(t)
	policy, router, root := newSessionFileGrantPolicyForTest(t, "codex")
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "project", Name: "Project", Path: projectDir}})
	if err != nil {
		t.Fatal(err)
	}
	router.projects = registry
	policy.allowThread(appServerGatewayAllowedThread{
		id: "child", runtimeID: "codex", cwd: projectDir, scopeID: "project", readOnly: true,
	})

	readThread := func(requestID string, responseThreadID string, mentioned string) ([]byte, bool, *appServerGatewayPolicyError) {
		t.Helper()
		id := json.RawMessage(requestID)
		if err := policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{
			method: "thread/read", threadID: "child",
		}); err != nil {
			t.Fatal(err)
		}
		if err := policy.reserveHistoryRequest(&id, "thread/read", map[string]any{
			"threadId": "child", "includeTurns": true,
		}, 128); err != nil {
			t.Fatalf("history 请求应可登记：%+v", err)
		}
		thread, _ := json.Marshal(map[string]any{
			"id": responseThreadID, "cwd": projectDir,
			"turns": []any{map[string]any{"id": "turn", "items": []any{
				map[string]any{"type": "agentMessage", "id": "a", "text": "见 " + mentioned},
			}}},
		})
		return policy.observeUpstreamFrame(websocket.TextMessage,
			[]byte(`{"id":`+requestID+`,"result":{"thread":`+string(thread)+`}}`))
	}

	rejected := filepath.Join(root, "other-thread.png")
	if _, forward, policyErr := readThread("401", "other", rejected); forward || policyErr == nil {
		t.Fatalf("返回别的 thread 时响应应被拒绝：forward=%v err=%+v", forward, policyErr)
	}
	if router.sessionFileGrants.granted(rejected) {
		t.Fatal("被拒绝的 thread/read 响应不能登记文件授权")
	}

	accepted := filepath.Join(root, "child.png")
	if _, forward, policyErr := readThread("402", "child", accepted); !forward || policyErr != nil {
		t.Fatalf("同一 thread 的响应应转发：forward=%v err=%+v", forward, policyErr)
	}
	if !router.sessionFileGrants.granted(accepted) {
		t.Fatal("通过校验并转发的 thread/read 响应应登记文件授权")
	}
}

// 一页历史可能带上成千上万条路径：单次最多登记 maxEntries 条，淘汰一次完成。
func TestSessionFileGrantStoreBoundsWorkForHugePages(t *testing.T) {
	root := t.TempDir()
	store := newSessionFileGrantStoreWithRoots([]string{root})
	now := time.Unix(1_000, 0)
	store.now = func() time.Time { return now }
	store.maxEntries = 100

	var older []string
	for index := 0; index < 60; index++ {
		older = append(older, filepath.Join(root, fmt.Sprintf("older-%03d.png", index)))
	}
	store.grant(older)

	now = now.Add(time.Minute)
	var huge []string
	for index := 0; index < 20_000; index++ {
		huge = append(huge, filepath.Join(root, fmt.Sprintf("page-%05d.png", index)))
	}
	store.grant(huge)

	if got := len(store.lastSeen); got != store.maxEntries {
		t.Fatalf("授权表应保持在容量上限：got=%d want=%d", got, store.maxEntries)
	}
	for _, path := range older {
		if store.granted(path) {
			t.Fatalf("更早被提到的路径应先被淘汰：%s", path)
		}
	}
	for index, path := range huge {
		if store.granted(path) != (index < store.maxEntries) {
			t.Fatalf("单次只应登记前 %d 条路径：index=%d granted=%v", store.maxEntries, index, store.granted(path))
		}
	}
}
