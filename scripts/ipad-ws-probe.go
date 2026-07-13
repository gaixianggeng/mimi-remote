//go:build ignore || ipadwsprobe

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

type agentdConfigFile struct {
	Auth struct {
		Token string `json:"token"`
	} `json:"auth"`
}

type appServerConfig struct {
	GatewayWSURL string `json:"gateway_ws_url"`
	Runtime      struct {
		GatewayAvailable bool `json:"gateway_available"`
		Running          bool `json:"running"`
		Initialized      bool `json:"initialized"`
		PendingRequests  int  `json:"pending_requests"`
	} `json:"runtime"`
	Channels []appServerChannel `json:"channels"`
	Projects []project          `json:"projects"`
}

type appServerChannel struct {
	ID               string `json:"id"`
	RuntimeID        string `json:"runtime_id"`
	Provider         string `json:"provider"`
	Protocol         string `json:"protocol"`
	GatewayWSURL     string `json:"gateway_ws_url"`
	GatewayAvailable bool   `json:"gateway_available"`
	Experimental     bool   `json:"experimental"`
	Lifecycle        string `json:"lifecycle"`
	Bridge           struct {
		Status         string `json:"status"`
		Error          string `json:"error"`
		LastProbeError string `json:"last_probe_error"`
	} `json:"bridge"`
}

type project struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
}

type rpcFrame struct {
	ID     any            `json:"id,omitempty"`
	Method string         `json:"method,omitempty"`
	Params map[string]any `json:"params,omitempty"`
	Result any            `json:"result,omitempty"`
	Error  *rpcError      `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type rpcResponse struct {
	ID     json.RawMessage `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

type rpcClient struct {
	name      string
	conn      *websocket.Conn
	writeMu   sync.Mutex
	pendingMu sync.Mutex
	pending   map[string]chan rpcResponse
	events    chan rpcFrame
	closed    chan struct{}
	closeOnce sync.Once
	closeErr  atomic.Value
}

type workerResult struct {
	Worker             int           `json:"worker"`
	CWD                string        `json:"cwd"`
	Model              string        `json:"model"`
	ThreadID           string        `json:"thread_id,omitempty"`
	TurnID             string        `json:"turn_id,omitempty"`
	StartedNewThread   bool          `json:"started_new_thread"`
	HandshakeLatencyMS int64         `json:"handshake_latency_ms"`
	ThreadLatencyMS    int64         `json:"thread_latency_ms"`
	TurnStartLatencyMS int64         `json:"turn_start_latency_ms"`
	FirstEventMS       int64         `json:"first_event_ms,omitempty"`
	FirstDeltaMS       int64         `json:"first_delta_ms,omitempty"`
	CompletedMS        int64         `json:"completed_ms,omitempty"`
	EventCount         int           `json:"event_count"`
	DeltaCount         int           `json:"delta_count"`
	AssistantTextBytes int           `json:"assistant_text_bytes"`
	EventMethods       []string      `json:"event_methods,omitempty"`
	Error              string        `json:"error,omitempty"`
	Duration           time.Duration `json:"-"`
}

type listedThread struct {
	ID        string `json:"id"`
	Title     string `json:"title,omitempty"`
	Preview   string `json:"preview,omitempty"`
	CWD       string `json:"cwd,omitempty"`
	Status    string `json:"status,omitempty"`
	UpdatedAt any    `json:"updated_at,omitempty"`
}

type listedModel struct {
	Model     string
	Provider  string
	IsDefault bool
}

func main() {
	var endpoint string
	var token string
	var configPath string
	var cwd string
	var projectID string
	var threadID string
	var model string
	var prompt string
	var runtime string
	var concurrency int
	var listLimit int
	var timeout time.Duration
	var listenAfterTurn time.Duration
	var startNew bool
	var goalGet bool
	var listOnly bool
	var modelsOnly bool
	var findThreadPrefix string
	var useStateDBOnly bool

	defaultConfig := defaultAgentDConfigPath()
	flag.StringVar(&endpoint, "endpoint", "", "Mac 的 Tailscale agentd endpoint，例如 http://100.x.y.z:8787（必填）")
	flag.StringVar(&token, "token", os.Getenv("AGENTD_TOKEN"), "agentd Bearer token；默认读 AGENTD_TOKEN 或 config")
	flag.StringVar(&configPath, "config", defaultConfig, "本机 agentd config.json，用于读取 token")
	flag.StringVar(&cwd, "cwd", "", "目标项目 cwd；为空时优先使用当前目录命中的 allowlist 项目")
	flag.StringVar(&projectID, "project", "", "目标项目 id；为空时按 cwd 或当前目录选择")
	flag.StringVar(&threadID, "thread", "", "指定已有 thread id；为空时按 -new 决定 thread/start 或 thread/list 最新项")
	flag.StringVar(&model, "model", "", "显式指定 app-server model；为空时先读 model/list 的默认项")
	flag.StringVar(&prompt, "prompt", "【ipad-ws-probe】请只回复 ok，用于验证 iPad WebSocket 链路。", "发送给目标 runtime 的探测消息")
	flag.StringVar(&runtime, "runtime", "codex", "目标 runtime：codex 或 claude")
	flag.IntVar(&concurrency, "concurrency", 1, "并发会话数，每个 worker 使用独立 WebSocket")
	flag.IntVar(&listLimit, "list-limit", 20, "thread/list limit")
	flag.DurationVar(&timeout, "timeout", 45*time.Second, "单个 JSON-RPC 请求超时")
	flag.DurationVar(&listenAfterTurn, "listen", 90*time.Second, "turn/start 成功后继续监听事件的时长")
	flag.BoolVar(&startNew, "new", true, "true=每个 worker thread/start 新会话；false=优先 resume 指定/最新 thread")
	flag.BoolVar(&goalGet, "goal-get", true, "发送前模拟 iPad connectForEvents 的 thread/goal/get")
	flag.BoolVar(&listOnly, "list-only", false, "只执行 initialize + thread/list，不发送 turn")
	flag.BoolVar(&modelsOnly, "models-only", false, "只执行 initialize + model/list，不发送 turn")
	flag.StringVar(&findThreadPrefix, "find-thread-prefix", "", "只输出 id 以该前缀开头的 thread；为空输出列表窗口")
	flag.BoolVar(&useStateDBOnly, "state-db-only", true, "thread/list 优先读取 Codex 状态库；false 用于验证普通扫描回退")
	flag.Parse()

	if strings.TrimSpace(endpoint) == "" {
		fatalf("缺少 endpoint：请用 -endpoint 指定 Mac 的 Tailscale agentd 地址")
	}
	if strings.TrimSpace(token) == "" {
		loaded, err := loadToken(configPath)
		if err != nil {
			fatalf("读取 token 失败：%v", err)
		}
		token = loaded
	}
	if strings.TrimSpace(token) == "" {
		fatalf("缺少 token：请设置 AGENTD_TOKEN 或提供 -config")
	}
	if concurrency < 1 {
		concurrency = 1
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout+listenAfterTurn+30*time.Second)
	defer cancel()

	cfg, err := fetchAppServerConfig(ctx, endpoint, token)
	if err != nil {
		fatalf("读取 app-server config 失败：%v", err)
	}
	runtime = normalizeRuntimeID(runtime)
	gatewayURL, channel, err := gatewayForRuntime(cfg, runtime)
	if err != nil {
		fatalf("gateway 不可用：runtime=%s err=%v", runtime, err)
	}
	selected, err := selectProject(cfg.Projects, cwd, projectID)
	if err != nil {
		fatalf("选择项目失败：%v", err)
	}
	if runtime == "claude" && goalGet {
		// Claude v1 channel 明确标记 goals=false；probe 不主动调用未声明能力，避免把能力差异误判成链路失败。
		goalGet = false
	}
	fmt.Printf("probe target endpoint=%s runtime=%s gateway=%s projects=%d cwd=%s runtime_running=%t runtime_initialized=%t pending=%d channel_protocol=%s lifecycle=%s experimental=%t\n",
		endpoint,
		runtime,
		gatewayURL,
		len(cfg.Projects),
		selected.Path,
		cfg.Runtime.Running,
		cfg.Runtime.Initialized,
		cfg.Runtime.PendingRequests,
		channel.Protocol,
		channel.Lifecycle,
		channel.Experimental,
	)
	if modelsOnly {
		models, err := listModels(ctx, gatewayURL, token, timeout)
		if err != nil {
			fatalf("model/list 失败：%v", err)
		}
		printJSON(models)
		return
	}
	if listOnly || strings.TrimSpace(findThreadPrefix) != "" {
		threads, err := listThreads(ctx, gatewayURL, token, selected, listLimit, useStateDBOnly, timeout)
		if err != nil {
			fatalf("thread/list 失败：%v", err)
		}
		prefix := strings.TrimSpace(findThreadPrefix)
		if prefix != "" {
			filtered := threads[:0]
			for _, item := range threads {
				if strings.HasPrefix(item.ID, prefix) {
					filtered = append(filtered, item)
				}
			}
			threads = filtered
		}
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(threads); err != nil {
			fatalf("输出 thread/list 失败：%v", err)
		}
		return
	}

	model = strings.TrimSpace(model)
	var modelProvider string
	if model == "" {
		models, err := listModels(ctx, gatewayURL, token, timeout)
		if err != nil {
			fatalf("model/list 失败：%v", err)
		}
		selectedModel, err := defaultModelFromList(models)
		if err != nil {
			fatalf("解析 model/list 失败：%v", err)
		}
		model = selectedModel.Model
		modelProvider = selectedModel.Provider
	}
	if model == "" {
		fatalf("缺少 model：model/list 未返回可用模型，请显式传 -model")
	}
	fmt.Printf("probe selected model=%s provider=%s\n", model, emptyAsAbsent(modelProvider))

	results := make([]workerResult, concurrency)
	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			workerPrompt := prompt
			if concurrency > 1 {
				workerPrompt = fmt.Sprintf("%s worker=%d nonce=%s", prompt, worker, shortNonce())
			}
			results[worker] = runWorker(ctx, worker, gatewayURL, token, selected, threadID, model, modelProvider, workerPrompt, startNew, goalGet, listLimit, useStateDBOnly, timeout, listenAfterTurn)
		}(i)
	}
	wg.Wait()

	sort.Slice(results, func(i, j int) bool { return results[i].Worker < results[j].Worker })
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(results); err != nil {
		fatalf("输出结果失败：%v", err)
	}

	failed := 0
	for _, item := range results {
		if item.Error != "" {
			failed++
		}
	}
	if failed > 0 {
		os.Exit(2)
	}
}

func runWorker(ctx context.Context, worker int, wsURL string, token string, p project, threadID string, model string, modelProvider string, prompt string, startNew bool, goalGet bool, listLimit int, useStateDBOnly bool, timeout time.Duration, listenAfterTurn time.Duration) workerResult {
	started := time.Now()
	result := workerResult{Worker: worker, CWD: p.Path, Model: model}
	client, err := dialRPC(ctx, fmt.Sprintf("worker-%d", worker), wsURL, token)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	defer client.close()

	handshakeStart := time.Now()
	if err := initializeClient(ctx, client, timeout); err != nil {
		result.Error = "initialize: " + err.Error()
		return result
	}
	result.HandshakeLatencyMS = elapsedMS(handshakeStart)

	// 先 thread/list：这一步既模拟 iPad 拉历史，也让 gateway 在当前连接授权已有 thread。
	listStart := time.Now()
	listResult, err := client.request(ctx, timeout, "thread/list", threadListParams(p, listLimit, useStateDBOnly))
	if err != nil {
		result.Error = "thread/list: " + err.Error()
		return result
	}
	result.ThreadLatencyMS = elapsedMS(listStart)
	latestThreadID := firstThreadID(listResult)

	if strings.TrimSpace(threadID) != "" {
		result.ThreadID = strings.TrimSpace(threadID)
	} else if startNew || latestThreadID == "" {
		threadStart := time.Now()
		threadResult, err := client.request(ctx, timeout, "thread/start", safeThreadParams(p.Path, model, modelProvider))
		if err != nil {
			result.Error = "thread/start: " + err.Error()
			return result
		}
		result.ThreadLatencyMS += elapsedMS(threadStart)
		result.ThreadID = threadIDFromThreadResult(threadResult)
		result.StartedNewThread = true
	} else {
		result.ThreadID = latestThreadID
	}
	if result.ThreadID == "" {
		result.Error = "未拿到 thread id"
		return result
	}

	if !result.StartedNewThread {
		resumeStart := time.Now()
		if _, err := client.request(ctx, timeout, "thread/resume", withThreadID(safeThreadParams(p.Path, model, modelProvider), result.ThreadID)); err != nil {
			result.Error = "thread/resume: " + err.Error()
			return result
		}
		result.ThreadLatencyMS += elapsedMS(resumeStart)
	}
	if goalGet {
		_, _ = client.request(ctx, timeout, "thread/goal/get", map[string]any{"threadId": result.ThreadID})
	}

	turnStart := time.Now()
	clientMessageID := fmt.Sprintf("probe-%d-%s", worker, shortNonce())
	turnResult, err := client.request(ctx, timeout, "turn/start", map[string]any{
		"threadId":            result.ThreadID,
		"cwd":                 p.Path,
		"input":               []any{map[string]any{"type": "text", "text": prompt}},
		"clientUserMessageId": clientMessageID,
		"model":               model,
		"approvalPolicy":      "on-request",
		"approvalsReviewer":   "user",
		// probe 必须模拟 iPad 新协议：普通执行显式退出 Plan Mode；model 来自 model/list 的账号默认项。
		"collaborationMode": map[string]any{
			"mode": "default",
			"settings": map[string]any{
				"model":                  model,
				"reasoning_effort":       "xhigh",
				"developer_instructions": nil,
			},
		},
		"sandboxPolicy": map[string]any{
			"type":                "workspaceWrite",
			"writableRoots":       []any{p.Path},
			"networkAccess":       false,
			"excludeTmpdirEnvVar": false,
			"excludeSlashTmp":     false,
		},
	})
	if err != nil {
		result.Error = "turn/start: " + err.Error()
		return result
	}
	result.TurnStartLatencyMS = elapsedMS(turnStart)
	result.TurnID = turnIDFromTurnResult(turnResult)

	// turn/start 只代表 app-server 接受了回合；这里继续监听事件，统计首包/首 delta/完成耗时。
	listenCtx, cancel := context.WithTimeout(ctx, listenAfterTurn)
	defer cancel()
	hasAssistantOutput := false
	for {
		select {
		case <-listenCtx.Done():
			result.Duration = time.Since(started)
			if result.EventCount == 0 {
				result.Error = "turn/start 已接受，但监听窗口内没有收到任何事件"
			} else if !hasAssistantOutput {
				result.Error = "收到运行时事件，但没有收到非空 assistant 回复"
			}
			return result
		case <-client.closed:
			result.Duration = time.Since(started)
			if err := client.err(); err != nil {
				result.Error = "websocket closed: " + err.Error()
			} else {
				result.Error = "websocket closed"
			}
			return result
		case event := <-client.events:
			if event.Method == "" {
				continue
			}
			result.EventCount++
			result.EventMethods = appendUnique(result.EventMethods, event.Method)
			if result.FirstEventMS == 0 {
				result.FirstEventMS = elapsedMS(turnStart)
			}
			assistantText, eventFailure := probeEventObservation(event)
			if assistantText != "" {
				hasAssistantOutput = true
				result.AssistantTextBytes += len([]byte(assistantText))
			}
			if eventFailure != "" {
				result.Duration = time.Since(started)
				result.Error = eventFailure
				return result
			}
			if strings.Contains(event.Method, "delta") {
				result.DeltaCount++
				if result.FirstDeltaMS == 0 {
					result.FirstDeltaMS = elapsedMS(turnStart)
				}
			}
			if event.Method == "turn/completed" {
				result.CompletedMS = elapsedMS(turnStart)
				result.Duration = time.Since(started)
				result.Error = completedTurnFailure(hasAssistantOutput, event)
				return result
			}
			if event.Method == "turn/failed" || event.Method == "thread/closed" {
				result.Duration = time.Since(started)
				result.Error = "received " + event.Method
				return result
			}
		}
	}
}

// probeEventObservation 同时提取有效回复和运行时错误。不能只看 turn/completed：
// Claude CLI 鉴权失败时也可能正常结束协议回合，但 item 本身明确标记为 API 错误。
func probeEventObservation(event rpcFrame) (assistantText string, failure string) {
	switch event.Method {
	case "item/agentMessage/delta":
		assistantText = firstString(event.Params, "delta", "text")
	case "item/completed":
		if item, ok := event.Params["item"].(map[string]any); ok && firstString(item, "type") == "agentMessage" {
			assistantText = firstString(item, "text", "content")
		}
	case "error", "turn/failed":
		return assistantText, "received " + event.Method + ": " + eventFailureDetail(event.Params)
	}

	raw, _ := json.Marshal(event.Params)
	lower := strings.ToLower(string(raw))
	if strings.Contains(lower, `"isapierrormessage":true`) ||
		strings.Contains(lower, "authentication_failed") ||
		strings.Contains(lower, "invalid authentication credentials") ||
		strings.Contains(lower, "failed to authenticate") {
		return assistantText, "runtime error: " + eventFailureDetail(event.Params)
	}
	return assistantText, ""
}

func completedTurnFailure(hasAssistantOutput bool, event rpcFrame) string {
	turn := event.Params
	if nested, ok := event.Params["turn"].(map[string]any); ok {
		turn = nested
	}
	status := strings.ToLower(firstString(turn, "status", "state"))
	if status != "" && status != "completed" {
		return "turn completed with status=" + status + ": " + eventFailureDetail(turn)
	}
	if !hasAssistantOutput {
		return "turn/completed 但没有收到非空 assistant 回复"
	}
	return ""
}

func eventFailureDetail(params map[string]any) string {
	if nested, ok := params["error"].(map[string]any); ok {
		if detail := firstString(nested, "message", "code", "type"); detail != "" {
			return detail
		}
	}
	if item, ok := params["item"].(map[string]any); ok {
		if detail := firstString(item, "text", "message", "error"); detail != "" {
			return detail
		}
	}
	if detail := firstString(params, "message", "error", "code"); detail != "" {
		return detail
	}
	return "unknown runtime failure"
}

func appendUnique(values []string, value string) []string {
	for _, current := range values {
		if current == value {
			return values
		}
	}
	return append(values, value)
}

func listThreads(ctx context.Context, wsURL string, token string, p project, listLimit int, useStateDBOnly bool, timeout time.Duration) ([]listedThread, error) {
	client, err := dialRPC(ctx, "list", wsURL, token)
	if err != nil {
		return nil, err
	}
	defer client.close()
	if err := initializeClient(ctx, client, timeout); err != nil {
		return nil, err
	}
	raw, err := client.request(ctx, timeout, "thread/list", threadListParams(p, listLimit, useStateDBOnly))
	if err != nil {
		return nil, err
	}
	return listedThreadsFromResult(raw), nil
}

func threadListParams(p project, listLimit int, useStateDBOnly bool) map[string]any {
	return map[string]any{
		"cwd":            p.Path,
		"limit":          listLimit,
		"sortKey":        "updated_at",
		"sortDirection":  "desc",
		"useStateDbOnly": useStateDBOnly,
	}
}

func listModels(ctx context.Context, wsURL string, token string, timeout time.Duration) (json.RawMessage, error) {
	client, err := dialRPC(ctx, "models", wsURL, token)
	if err != nil {
		return nil, err
	}
	defer client.close()
	if err := initializeClient(ctx, client, timeout); err != nil {
		return nil, err
	}
	// Go 的 omitempty 会省略空 map；带一个哑字段让 gateway 白名单改写成 params={}。
	return client.request(ctx, timeout, "model/list", map[string]any{"_probe": true})
}

func defaultModelFromList(raw json.RawMessage) (listedModel, error) {
	models := parseListedModels(raw)
	if len(models) == 0 {
		return listedModel{}, errors.New("model/list 返回为空")
	}
	for _, model := range models {
		if model.IsDefault {
			return model, nil
		}
	}
	return models[0], nil
}

func parseListedModels(raw json.RawMessage) []listedModel {
	var root any
	if err := json.Unmarshal(raw, &root); err != nil {
		return nil
	}
	items := modelListItems(root)
	models := make([]listedModel, 0, len(items))
	seen := map[string]bool{}
	for _, item := range items {
		object, ok := item.(map[string]any)
		if !ok {
			continue
		}
		model := firstString(object, "model", "id", "name")
		if model == "" || seen[model] {
			continue
		}
		seen[model] = true
		models = append(models, listedModel{
			Model:     model,
			Provider:  firstString(object, "provider", "modelProvider", "model_provider"),
			IsDefault: firstBool(object, "isDefault", "default", "is_default"),
		})
	}
	return models
}

func modelListItems(root any) []any {
	switch typed := root.(type) {
	case []any:
		return typed
	case map[string]any:
		for _, key := range []string{"models", "data", "items"} {
			if items, ok := typed[key].([]any); ok {
				return items
			}
		}
	}
	return nil
}

func firstBool(object map[string]any, keys ...string) bool {
	for _, key := range keys {
		value, ok := object[key].(bool)
		if ok && value {
			return true
		}
	}
	return false
}

func dialRPC(ctx context.Context, name string, wsURL string, token string) (*rpcClient, error) {
	dialer := websocket.Dialer{HandshakeTimeout: 12 * time.Second}
	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	conn, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		if resp != nil && resp.Body != nil {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			_ = resp.Body.Close()
			return nil, fmt.Errorf("dial %s: status=%d body=%s err=%w", wsURL, resp.StatusCode, strings.TrimSpace(string(body)), err)
		}
		return nil, fmt.Errorf("dial %s: %w", wsURL, err)
	}
	client := &rpcClient{
		name:    name,
		conn:    conn,
		pending: map[string]chan rpcResponse{},
		// 压测工具本身不能静默丢 app-server 事件，否则会把客户端问题误判成服务端问题。
		events: make(chan rpcFrame, 16_384),
		closed: make(chan struct{}),
	}
	go client.readLoop()
	return client, nil
}

func initializeClient(ctx context.Context, client *rpcClient, timeout time.Duration) error {
	if _, err := client.request(ctx, timeout, "initialize", map[string]any{
		"clientInfo": map[string]any{
			"name":    "mimi_remote_probe",
			"title":   "Mimi Remote Probe",
			"version": "0.1.0",
		},
		"capabilities": map[string]any{
			"experimentalApi":    true,
			"requestAttestation": false,
		},
	}); err != nil {
		return err
	}
	return client.notify("initialized", map[string]any{})
}

func (c *rpcClient) request(ctx context.Context, timeout time.Duration, method string, params map[string]any) (json.RawMessage, error) {
	id := nextID()
	idBytes, _ := json.Marshal(id)
	key := string(idBytes)
	responseCh := make(chan rpcResponse, 1)
	c.pendingMu.Lock()
	c.pending[key] = responseCh
	c.pendingMu.Unlock()
	frame := rpcFrame{ID: id, Method: method, Params: params}
	if err := c.writeJSON(frame); err != nil {
		c.forget(key)
		return nil, err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		c.forget(key)
		return nil, ctx.Err()
	case <-c.closed:
		c.forget(key)
		if err := c.err(); err != nil {
			return nil, err
		}
		return nil, errors.New("websocket closed")
	case <-timer.C:
		c.forget(key)
		return nil, fmt.Errorf("%s#%s timeout after %s", method, key, timeout)
	case response := <-responseCh:
		if response.Error != nil {
			return nil, fmt.Errorf("%s#%s app-server error %d: %s", method, key, response.Error.Code, response.Error.Message)
		}
		return response.Result, nil
	}
}

func (c *rpcClient) notify(method string, params map[string]any) error {
	return c.writeJSON(rpcFrame{Method: method, Params: params})
}

func (c *rpcClient) writeJSON(frame any) error {
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(frame); err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
	return c.conn.WriteMessage(websocket.TextMessage, bytes.TrimSpace(buf.Bytes()))
}

func (c *rpcClient) readLoop() {
	defer c.close()
	for {
		_, payload, err := c.conn.ReadMessage()
		if err != nil {
			c.closeErr.Store(err)
			return
		}
		var raw struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Result json.RawMessage `json:"result"`
			Error  *rpcError       `json:"error"`
			Params map[string]any  `json:"params"`
		}
		if err := json.Unmarshal(payload, &raw); err != nil {
			continue
		}
		if len(raw.ID) > 0 && raw.Method == "" {
			key := string(bytes.TrimSpace(raw.ID))
			c.pendingMu.Lock()
			ch := c.pending[key]
			delete(c.pending, key)
			c.pendingMu.Unlock()
			if ch != nil {
				ch <- rpcResponse{ID: raw.ID, Result: raw.Result, Error: raw.Error}
			}
			continue
		}
		if raw.Method != "" {
			c.events <- rpcFrame{ID: string(raw.ID), Method: raw.Method, Params: raw.Params, Error: raw.Error}
		}
	}
}

func (c *rpcClient) forget(key string) {
	c.pendingMu.Lock()
	delete(c.pending, key)
	c.pendingMu.Unlock()
}

func (c *rpcClient) close() {
	c.closeOnce.Do(func() {
		close(c.closed)
		_ = c.conn.Close()
	})
}

func (c *rpcClient) err() error {
	if value := c.closeErr.Load(); value != nil {
		if err, ok := value.(error); ok {
			return err
		}
	}
	return nil
}

var rpcID atomic.Int64

func nextID() int64 {
	return rpcID.Add(1)
}

func loadToken(configPath string) (string, error) {
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return "", err
	}
	var cfg agentdConfigFile
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return "", err
	}
	return strings.TrimSpace(cfg.Auth.Token), nil
}

func defaultAgentDConfigPath() string {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "config.json"
	}
	return resolveDefaultAgentDConfigPath(configDir, func(path string) bool {
		info, statErr := os.Stat(path)
		return statErr == nil && !info.IsDir()
	})
}

func resolveDefaultAgentDConfigPath(configDir string, exists func(string) bool) string {
	current := filepath.Join(configDir, "mimi-remote", "config.json")
	legacy := filepath.Join(configDir, "codex-ipad-agent", "config.json")
	// 新目录不存在时只读兼容旧安装；setup/doctor 仍负责把正式配置迁移到新目录。
	if !exists(current) && exists(legacy) {
		return legacy
	}
	return current
}

func fetchAppServerConfig(ctx context.Context, endpoint string, token string) (appServerConfig, error) {
	base, err := url.Parse(normalizedEndpoint(endpoint))
	if err != nil {
		return appServerConfig{}, err
	}
	base.Path = "/api/app-server/config"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base.String(), nil)
	if err != nil {
		return appServerConfig{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return appServerConfig{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return appServerConfig{}, err
	}
	if resp.StatusCode/100 != 2 {
		return appServerConfig{}, fmt.Errorf("status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var cfg appServerConfig
	if err := json.Unmarshal(body, &cfg); err != nil {
		return appServerConfig{}, err
	}
	return cfg, nil
}

func gatewayForRuntime(cfg appServerConfig, runtimeID string) (string, appServerChannel, error) {
	runtimeID = normalizeRuntimeID(runtimeID)
	for _, channel := range cfg.Channels {
		if normalizeRuntimeID(firstNonEmpty(channel.RuntimeID, channel.ID, channel.Provider)) != runtimeID {
			continue
		}
		if !channel.GatewayAvailable || strings.TrimSpace(channel.GatewayWSURL) == "" {
			message := fmt.Sprintf("channel=%s unavailable", runtimeID)
			if channel.Bridge.Status != "" {
				message += " bridge_status=" + channel.Bridge.Status
			}
			if channel.Bridge.Error != "" {
				message += " bridge_error=" + channel.Bridge.Error
			}
			if channel.Bridge.LastProbeError != "" {
				message += " bridge_error=" + channel.Bridge.LastProbeError
			}
			return "", channel, errors.New(message)
		}
		return strings.TrimSpace(channel.GatewayWSURL), channel, nil
	}
	if runtimeID == "codex" && cfg.Runtime.GatewayAvailable && strings.TrimSpace(cfg.GatewayWSURL) != "" {
		return strings.TrimSpace(cfg.GatewayWSURL), appServerChannel{
			ID:               "codex",
			RuntimeID:        "codex",
			Protocol:         "app_server_jsonrpc_ws",
			GatewayWSURL:     strings.TrimSpace(cfg.GatewayWSURL),
			GatewayAvailable: true,
		}, nil
	}
	return "", appServerChannel{}, fmt.Errorf("config 未返回 runtime=%s 的可用 channel", runtimeID)
}

func normalizeRuntimeID(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", "codex", "openai", "codex_app_server", "codex-app-server":
		return "codex"
	case "claude", "anthropic", "claude_code", "claude-code", "claude_code_bridge", "claude-code-bridge":
		return "claude"
	default:
		return strings.ToLower(strings.TrimSpace(raw))
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func normalizedEndpoint(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return raw
	}
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	return strings.TrimRight(raw, "/")
}

func selectProject(projects []project, cwd string, projectID string) (project, error) {
	if len(projects) == 0 {
		return project{}, errors.New("agentd 没有返回 allowlist projects")
	}
	cwd = strings.TrimSpace(cwd)
	projectID = strings.TrimSpace(projectID)
	if cwd == "" {
		if wd, err := os.Getwd(); err == nil {
			cwd = wd
		}
	}
	if cwd != "" {
		cwd = filepath.Clean(cwd)
	}
	var best *project
	for i := range projects {
		item := projects[i]
		if projectID != "" && item.ID != projectID {
			continue
		}
		if cwd != "" {
			path := filepath.Clean(item.Path)
			if cwd != path && !strings.HasPrefix(cwd, path+string(os.PathSeparator)) {
				continue
			}
		}
		if best == nil || len(item.Path) > len(best.Path) {
			best = &item
		}
	}
	if best != nil {
		return *best, nil
	}
	if projectID != "" {
		return project{}, fmt.Errorf("未找到 project=%s cwd=%s", projectID, cwd)
	}
	if cwd != "" {
		return project{}, fmt.Errorf("当前 cwd 不在 allowlist：%s；请用 -cwd 或 -project 指定", cwd)
	}
	return projects[0], nil
}

func safeThreadParams(cwd string, model string, modelProvider string) map[string]any {
	params := map[string]any{
		"cwd":               cwd,
		"model":             model,
		"approvalPolicy":    "on-request",
		"approvalsReviewer": "user",
		"sandbox":           "workspace-write",
		"ephemeral":         false,
	}
	if strings.TrimSpace(modelProvider) != "" {
		params["modelProvider"] = strings.TrimSpace(modelProvider)
	}
	return params
}

func withThreadID(params map[string]any, threadID string) map[string]any {
	out := map[string]any{}
	for key, value := range params {
		out[key] = value
	}
	out["threadId"] = threadID
	out["excludeTurns"] = true
	delete(out, "ephemeral")
	return out
}

func emptyAsAbsent(value string) string {
	if strings.TrimSpace(value) == "" {
		return "absent"
	}
	return strings.TrimSpace(value)
}

func firstThreadID(raw json.RawMessage) string {
	var decoded struct {
		Data    []map[string]any `json:"data"`
		Threads []map[string]any `json:"threads"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return ""
	}
	for _, list := range [][]map[string]any{decoded.Data, decoded.Threads} {
		if len(list) == 0 {
			continue
		}
		return firstString(list[0], "id", "threadId", "sessionId")
	}
	return ""
}

func listedThreadsFromResult(raw json.RawMessage) []listedThread {
	var decoded struct {
		Data    []map[string]any `json:"data"`
		Threads []map[string]any `json:"threads"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil
	}
	items := decoded.Data
	if len(items) == 0 {
		items = decoded.Threads
	}
	threads := make([]listedThread, 0, len(items))
	for _, item := range items {
		id := firstString(item, "id", "threadId", "sessionId")
		if id == "" {
			continue
		}
		threads = append(threads, listedThread{
			ID:        id,
			Title:     firstString(item, "name", "title"),
			Preview:   firstString(item, "preview"),
			CWD:       firstString(item, "cwd", "path"),
			Status:    threadStatusString(item["status"]),
			UpdatedAt: item["updatedAt"],
		})
	}
	return threads
}

func threadIDFromThreadResult(raw json.RawMessage) string {
	var decoded struct {
		Thread map[string]any `json:"thread"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return ""
	}
	return firstString(decoded.Thread, "id", "threadId", "sessionId")
}

func turnIDFromTurnResult(raw json.RawMessage) string {
	var decoded struct {
		Turn map[string]any `json:"turn"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return ""
	}
	return firstString(decoded.Turn, "id", "turnId")
}

func threadStatusString(raw any) string {
	switch value := raw.(type) {
	case string:
		return value
	case map[string]any:
		return firstString(value, "type", "status")
	default:
		return ""
	}
}

func firstString(object map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := object[key].(string); ok && strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func elapsedMS(start time.Time) int64 {
	return int64(math.Round(float64(time.Since(start)) / float64(time.Millisecond)))
}

func shortNonce() string {
	var raw [4]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(raw[:])
}

func printJSON(value any) {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		fatalf("输出 JSON 失败：%v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
