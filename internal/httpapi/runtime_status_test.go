package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestRuntimeStatusRequiresAuthAndReturnsSanitizedCodexSnapshot(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	handler, router := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, nil)
	codexStartedAt := time.Now().UTC().Add(-2 * time.Hour).Truncate(time.Second)
	router.SetCodexRuntimeStartedAt(codexStartedAt)

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/runtime/status", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("runtime status 必须要求 Bearer Token，got=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}
	if connections.Load() != 0 {
		t.Fatalf("未授权请求不能连接 provider upstream，connections=%d", connections.Load())
	}

	rec, response := readRuntimeStatusEventually(t, handler)
	if strings.Contains(rec.Body.String(), "owner@example.com") ||
		strings.Contains(rec.Body.String(), "test-upstream-token") {
		t.Fatalf("runtime status 不得泄露邮箱或 upstream token：%s", rec.Body.String())
	}

	if len(response.Runtimes) != 2 {
		t.Fatalf("应始终返回 Codex 和 Claude 两行：%+v", response.Runtimes)
	}
	if response.CheckedAt == nil || response.Stale || response.Refreshing {
		t.Fatalf("完成后的 runtime status 必须是带时间的新鲜快照：%+v", response)
	}
	codex := response.Runtimes[0]
	if codex.ID != "codex" || codex.State != runtimeStateConnected ||
		codex.Version != "fake-codex" ||
		codex.AuthMode != "chatgpt" || codex.PlanType != "plus" {
		t.Fatalf("Codex 账号状态异常：%+v", codex)
	}
	if codex.StartedAt == nil || !codex.StartedAt.Equal(codexStartedAt) {
		t.Fatalf("Codex 状态应包含 resident app-server 启动时间：%+v", codex)
	}
	if codex.RateLimits == nil || codex.RateLimits.Primary == nil ||
		codex.RateLimits.Primary.UsedPercent == nil ||
		*codex.RateLimits.Primary.UsedPercent != 62.5 ||
		codex.RateLimits.Primary.WindowDurationMin == nil ||
		*codex.RateLimits.Primary.WindowDurationMin != 300 {
		t.Fatalf("Codex 额度窗口归一化异常：%+v", codex.RateLimits)
	}
	claude := response.Runtimes[1]
	if claude.ID != "claude" || claude.Enabled || claude.State != runtimeStateDisabled {
		t.Fatalf("未启用 Claude 应保留灰态行：%+v", claude)
	}
}

func TestRuntimeStatusKeepsSlowCodexQuotaProbeOffRequestPath(t *testing.T) {
	baseResponder := runtimeStatusCodexResponder(t)
	upstreamURL, _, _ := fakeAppServerUpstream(t, func(
		conn *websocket.Conn,
		messageType int,
		payload []byte,
	) {
		var frame struct {
			Method string `json:"method"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("无法解析 fake app-server frame：%v", err)
			return
		}
		if frame.Method == "account/rateLimits/read" {
			// 覆盖本次回归：真实机器首次额度读取超过旧的 3 秒预算。
			time.Sleep(3500 * time.Millisecond)
		}
		baseResponder(conn, messageType, payload)
	})
	handler, _ := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, nil)

	startedAt := time.Now()
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodGet, "/api/runtime/status", nil)
	req.RemoteAddr = "127.0.0.1:43210"
	handler.ServeHTTP(rec, req)
	if elapsed := time.Since(startedAt); elapsed >= 100*time.Millisecond {
		t.Fatalf("慢 Codex 额度探测不能阻塞菜单请求：elapsed=%s", elapsed)
	}
	var first runtimeStatusResponse
	if err := json.NewDecoder(rec.Body).Decode(&first); err != nil {
		t.Fatal(err)
	}
	if !first.Refreshing {
		t.Fatalf("首次请求应立即返回后台刷新占位：%+v", first)
	}

	_, response := readRuntimeStatusEventually(t, handler)
	codex := response.Runtimes[0]
	if codex.RateLimits == nil || codex.RateLimits.Secondary == nil ||
		codex.RateLimits.Secondary.UsedPercent == nil {
		t.Fatalf("后台慢查询完成后必须恢复 Codex 圆环数据：%+v", codex)
	}
}

func TestCodexRuntimeKeepsRecentQuotaOnTransientProbeFailure(t *testing.T) {
	baseResponder := runtimeStatusCodexResponder(t)
	var quotaCalls atomic.Int32
	upstreamURL, _, _ := fakeAppServerUpstream(t, func(
		conn *websocket.Conn,
		messageType int,
		payload []byte,
	) {
		var frame struct {
			Method string `json:"method"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("无法解析 fake app-server frame：%v", err)
			return
		}
		if frame.Method == "account/rateLimits/read" && quotaCalls.Add(1) > 1 {
			_ = conn.Close()
			return
		}
		baseResponder(conn, messageType, payload)
	})
	_, router := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, nil)

	first := router.probeCodexRuntime(context.Background())
	if first.RateLimits == nil || first.RateLimits.Secondary == nil {
		t.Fatalf("首次探测应写入额度缓存：%+v", first)
	}
	second := router.probeCodexRuntime(context.Background())
	if second.RateLimits == nil || second.RateLimits.Secondary == nil ||
		second.RateLimits.Secondary.UsedPercent == nil ||
		*second.RateLimits.Secondary.UsedPercent !=
			*first.RateLimits.Secondary.UsedPercent {
		t.Fatalf("临时失败时应保留最近一次圆环数据：first=%+v second=%+v", first, second)
	}
	if second.State != runtimeStateConnected {
		t.Fatalf("额度临时失败不能降低 Codex 连接状态：%+v", second)
	}
}

func TestRuntimeStatusDoesNotTreatServerRequestAsRPCResponse(t *testing.T) {
	var rejectedServerRequest atomic.Bool
	upstreamURL, _, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Error  *struct {
				Code int `json:"code"`
			} `json:"error"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("无法解析 runtime status RPC frame：%v", err)
			return
		}
		if frame.Method == "" {
			if frame.Error != nil && frame.Error.Code == -32601 {
				rejectedServerRequest.Store(true)
			}
			return
		}

		var result any
		switch frame.Method {
		case "initialize":
			result = map[string]any{"userAgent": "fake-codex"}
		case "initialized":
			return
		case "account/read":
			// 双向 JSON-RPC 的 request/response id namespace 相互独立。
			// 服务端 request 故意复用当前客户端 request id，验证客户端不会误判。
			if err := conn.WriteJSON(map[string]any{
				"id":     frame.ID,
				"method": "account/chatgptAuthTokens/refresh",
				"params": map[string]any{"reason": "unauthorized"},
			}); err != nil {
				t.Errorf("写入服务端 request 失败：%v", err)
				return
			}
			result = map[string]any{
				"account": map[string]any{
					"type":     "chatgpt",
					"planType": "plus",
				},
				"requiresOpenaiAuth": true,
			}
		case "account/rateLimits/read":
			result = map[string]any{}
		default:
			t.Errorf("fake app-server 收到未知方法：%s", frame.Method)
			return
		}
		response, err := json.Marshal(map[string]any{
			"id":     frame.ID,
			"result": result,
		})
		if err != nil {
			t.Error(err)
			return
		}
		if err := conn.WriteMessage(messageType, response); err != nil {
			t.Errorf("fake app-server 写响应失败：%v", err)
		}
	})
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, nil)

	_, response := readRuntimeStatusEventually(t, handler)
	codex := response.Runtimes[0]
	if codex.State != runtimeStateConnected || codex.AuthMode != "chatgpt" {
		t.Fatalf("服务端 request 不能吞掉 account/read 响应：%+v", codex)
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if rejectedServerRequest.Load() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("runtime status 客户端没有拒绝不支持的服务端 request")
}

func TestApplyCodexAccountDoesNotClaimUnverifiedCredentialsAreConnected(t *testing.T) {
	testCases := []struct {
		name       string
		account    string
		wantMode   string
		wantReason string
	}{
		{
			name:       "API key",
			account:    `{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}`,
			wantMode:   "api_key",
			wantReason: "api_key_configured_unverified",
		},
		{
			name:       "Bedrock",
			account:    `{"account":{"type":"amazonBedrock","credentialSource":"awsManaged"},"requiresOpenaiAuth":false}`,
			wantMode:   "bedrock",
			wantReason: "bedrock_credentials_configured_unverified",
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			var response runtimeAccountResponse
			if err := json.Unmarshal([]byte(testCase.account), &response); err != nil {
				t.Fatal(err)
			}
			status := runtimeAccountStatus{
				ID:      "codex",
				Title:   "Codex",
				Enabled: true,
				State:   runtimeStateUnavailable,
			}

			applyCodexAccount(&status, response)

			if status.State != runtimeStateAvailable ||
				status.AuthMode != testCase.wantMode ||
				status.Reason != testCase.wantReason {
				t.Fatalf("未验证凭据不能标记为 connected：%+v", status)
			}
		})
	}
}

func TestRuntimeStatusUsesClaudeOAuthUsageAsAuthenticatedEvidence(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	bridgePath := writeTestBridge(t, `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"userAgent":"fake-claude"}}\n'
IFS= read -r initialized
IFS= read -r rate_limit
printf '{"id":2,"result":{"rateLimits":{"limitId":"claude","limitName":"Claude","planType":"pro","availability":"available","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1780494300},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1781099100}}}}\n'
while IFS= read -r line; do :; done
`)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
		cfg.Claude.MaxConcurrentBridges = 3
	})

	_, response := readRuntimeStatusEventually(t, handler)
	claude := response.Runtimes[1]
	if claude.ID != "claude" || claude.State != runtimeStateConnected ||
		claude.Version != "fake-claude" ||
		claude.AuthMode != "oauth" || claude.PlanType != "pro" {
		t.Fatalf("Claude OAuth 连接状态异常：%+v", claude)
	}
	if claude.StartedAt == nil || time.Since(*claude.StartedAt) > time.Minute {
		t.Fatalf("Claude 状态应包含当前 resident bridge 启动时间：%+v", claude)
	}
	if claude.RateLimits == nil || claude.RateLimits.Secondary == nil ||
		claude.RateLimits.Secondary.WindowDurationMin == nil ||
		*claude.RateLimits.Secondary.WindowDurationMin != 10_080 {
		t.Fatalf("Claude 周额度窗口异常：%+v", claude.RateLimits)
	}
}

func TestRuntimeStatusDoesNotWaitForSlowClaudeQuotaProbe(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	bridgePath := writeTestBridge(t, `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"userAgent":"fake-claude"}}\n'
IFS= read -r initialized
IFS= read -r rate_limit
sleep 4
printf '{"id":2,"result":{"rateLimits":{"limitId":"claude","availability":"available"}}}\n'
while IFS= read -r line; do :; done
`)
	handler, router := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
		cfg.Claude.MaxConcurrentBridges = 3
	})

	startedAt := time.Now()
	_, response := readRuntimeStatusEventually(t, handler)
	if elapsed := time.Since(startedAt); elapsed >= 3*time.Second {
		t.Fatalf("慢额度查询不能阻塞运行时连接状态：elapsed=%s", elapsed)
	}
	claude := response.Runtimes[1]
	if claude.State != runtimeStateAvailable ||
		claude.Version != "fake-claude" ||
		claude.Reason != "quota_refresh_in_progress" {
		t.Fatalf("额度超时时应先保留 Claude 连接与版本：%+v", claude)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cached := router.cachedClaudeRuntimeQuota(time.Now().UTC()); cached != nil {
			if cached.Availability != "available" {
				t.Fatalf("后台额度缓存异常：%+v", cached)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("慢额度查询完成后没有写入 Router 缓存")
}

func TestRuntimeVersionFromUserAgent(t *testing.T) {
	tests := map[string]string{
		"codex_cli_rs/0.146.0-alpha.3.1":  "0.146.0-alpha.3.1",
		"alleycat-claude-bridge/0.2.7":    "0.2.7",
		"codex-cli v1.2.3-beta.1 (macOS)": "1.2.3-beta.1",
		"  fake-runtime  ":                "fake-runtime",
		"":                                "",
	}
	for input, want := range tests {
		if got := runtimeVersionFromUserAgent(input); got != want {
			t.Fatalf("runtime userAgent 版本解析错误：input=%q got=%q want=%q", input, got, want)
		}
	}
}

func TestRuntimeStatusDoesNotMixConfiguredClaudeAPIKeyWithOAuthQuota(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	bridgePath := writeTestBridge(t, `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"userAgent":"fake-claude"}}\n'
IFS= read -r initialized
IFS= read -r rate_limit
printf '{"id":2,"result":{"rateLimits":{"limitId":"claude","planType":"pro","availability":"available","primary":{"usedPercent":25,"windowDurationMins":300}}}}\n'
while IFS= read -r line; do :; done
`)
	const apiKey = "configured-api-key-must-not-leak"
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
		cfg.Claude.MaxConcurrentBridges = 3
		if cfg.Claude.Env == nil {
			cfg.Claude.Env = map[string]string{}
		}
		cfg.Claude.Env["ANTHROPIC_API_KEY"] = apiKey
	})

	rec, response := readRuntimeStatusEventually(t, handler)
	claude := response.Runtimes[1]
	if claude.State != runtimeStateAvailable || claude.AuthMode != "api_key" ||
		claude.PlanType != "" || claude.RateLimits != nil ||
		claude.Reason != "api_key_configured_unverified" {
		t.Fatalf("API Key 应仅标记已配置，不得混入 OAuth 套餐额度：%+v", claude)
	}
	if strings.Contains(rec.Body.String(), apiKey) {
		t.Fatalf("runtime status 不得泄露 Claude API Key：%s", rec.Body.String())
	}
}

func TestRuntimeStatusIgnoresParentClaudeAPIKeyNotPassedToBridge(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "parent-only-key-must-not-leak")
	upstreamURL, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	bridgePath := writeTestBridge(t, `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"userAgent":"fake-claude"}}\n'
IFS= read -r initialized
IFS= read -r rate_limit
printf '{"id":2,"result":{"rateLimits":{"limitId":"claude","availability":"unavailable","unavailableReason":"headless_statusline_unavailable"}}}\n'
while IFS= read -r line; do :; done
`)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
		cfg.Claude.MaxConcurrentBridges = 3
	})

	rec, response := readRuntimeStatusEventually(t, handler)
	claude := response.Runtimes[1]
	if claude.State != runtimeStateAvailable || claude.AuthMode != "" {
		t.Fatalf("未传给 bridge 的父进程 API Key 不能作为连接证据：%+v", claude)
	}
	if strings.Contains(rec.Body.String(), "parent-only-key-must-not-leak") {
		t.Fatalf("runtime status 不得泄露父进程 API Key：%s", rec.Body.String())
	}
}

func TestRuntimeStatusRejectsNonLoopbackWithoutStartingProviderProbe(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, nil)

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodGet, "/api/runtime/status", nil)
	req.RemoteAddr = "100.64.0.8:43210"
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("远端 runtime status 必须拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if connections.Load() != 0 {
		t.Fatalf("远端请求不能启动 provider probe：connections=%d", connections.Load())
	}
}

func TestRuntimeStatusCacheReturnsImmediatelyAndSingleFlightsRefresh(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var probes atomic.Int32
	cache := newRuntimeStatusSnapshotCache(
		func(ctx context.Context) runtimeStatusResponse {
			if probes.Add(1) == 1 {
				close(started)
			}
			select {
			case <-ctx.Done():
			case <-release:
			}
			checkedAt := time.Now().UTC()
			return runtimeStatusResponse{
				CheckedAt: &checkedAt,
				Runtimes: []runtimeAccountStatus{{
					ID: "codex", Title: "Codex", Enabled: true, State: runtimeStateConnected,
				}},
			}
		},
		func() runtimeStatusResponse {
			return runtimeStatusResponse{
				Runtimes: []runtimeAccountStatus{{
					ID: "codex", Title: "Codex", Enabled: true,
					State: runtimeStateUnavailable, Reason: "refresh_in_progress",
				}},
			}
		},
	)
	defer cache.Close()

	start := time.Now()
	first := cache.Snapshot()
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond {
		t.Fatalf("缓存 miss 不得等待 provider：%s", elapsed)
	}
	if !first.Refreshing || first.CheckedAt != nil {
		t.Fatalf("首次请求应立即返回 refreshing 占位：%+v", first)
	}
	<-started
	for range 20 {
		if snapshot := cache.Snapshot(); !snapshot.Refreshing {
			t.Fatalf("刷新未释放前必须保持 refreshing：%+v", snapshot)
		}
	}
	if probes.Load() != 1 {
		t.Fatalf("并发快照必须 single-flight：probes=%d", probes.Load())
	}
	close(release)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		snapshot := cache.Snapshot()
		if !snapshot.Refreshing {
			if snapshot.Stale || snapshot.CheckedAt == nil {
				t.Fatalf("刷新结果必须新鲜：%+v", snapshot)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("runtime status cache 没有完成刷新")
}

func TestRuntimeStatusSuccessfulSnapshotStaysFreshForFiveMinutes(t *testing.T) {
	base := time.Date(2026, time.July, 28, 2, 0, 0, 0, time.UTC)
	now := base
	var probes atomic.Int32
	cache := newRuntimeStatusSnapshotCache(
		func(context.Context) runtimeStatusResponse {
			probes.Add(1)
			checkedAt := now
			return runtimeStatusResponse{
				CheckedAt: &checkedAt,
				Runtimes: []runtimeAccountStatus{{
					ID: "codex", Title: "Codex", Enabled: true, State: runtimeStateConnected,
				}},
			}
		},
		func() runtimeStatusResponse { return runtimeStatusResponse{} },
	)
	cache.now = func() time.Time { return now }
	defer cache.Close()

	_ = cache.Snapshot()
	deadline := time.Now().Add(time.Second)
	for cache.Snapshot().Refreshing && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if probes.Load() != 1 {
		t.Fatalf("首次快照探测次数异常：%d", probes.Load())
	}

	now = base.Add(4*time.Minute + 59*time.Second)
	if snapshot := cache.Snapshot(); snapshot.Refreshing || snapshot.Stale {
		t.Fatalf("5 分钟内的成功快照应直接复用：%+v", snapshot)
	}
	if probes.Load() != 1 {
		t.Fatalf("5 分钟内不能重复探测：%d", probes.Load())
	}

	now = base.Add(5 * time.Minute)
	if snapshot := cache.Snapshot(); !snapshot.Refreshing || !snapshot.Stale {
		t.Fatalf("5 分钟后应后台刷新并继续返回旧快照：%+v", snapshot)
	}
}

func TestRuntimeStatusManualRefreshBypassesFreshTTL(t *testing.T) {
	now := time.Date(2026, time.August, 26, 8, 0, 0, 0, time.UTC)
	var probes atomic.Int32
	cache := newRuntimeStatusSnapshotCache(
		func(context.Context) runtimeStatusResponse {
			probes.Add(1)
			checkedAt := now
			return runtimeStatusResponse{
				CheckedAt: &checkedAt,
				Runtimes: []runtimeAccountStatus{{
					ID: "codex", Title: "Codex", Enabled: true, State: runtimeStateConnected,
				}},
			}
		},
		func() runtimeStatusResponse { return runtimeStatusResponse{} },
	)
	cache.now = func() time.Time { return now }
	defer cache.Close()

	first := cache.Refresh(context.Background())
	if first.Refreshing || first.Stale || probes.Load() != 1 {
		t.Fatalf("首次手动刷新结果异常：snapshot=%+v probes=%d", first, probes.Load())
	}
	now = now.Add(time.Minute)
	second := cache.Refresh(context.Background())
	if second.CheckedAt == nil || !second.CheckedAt.Equal(now) || second.Refreshing || second.Stale {
		t.Fatalf("五分钟 TTL 内的手动刷新仍应返回新快照：%+v", second)
	}
	if probes.Load() != 2 {
		t.Fatalf("手动刷新必须绕过成功 TTL：probes=%d", probes.Load())
	}
}

func TestRuntimeStatusManualRefreshRunsAfterInflightBackgroundProbe(t *testing.T) {
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	var probes atomic.Int32
	var accountState atomic.Int32
	cache := newRuntimeStatusSnapshotCache(
		func(context.Context) runtimeStatusResponse {
			probe := probes.Add(1)
			observed := accountState.Load()
			if probe == 1 {
				close(firstStarted)
				<-releaseFirst
			}
			state := runtimeStateSignedOut
			if observed == 1 {
				state = runtimeStateConnected
			}
			checkedAt := time.Now().UTC()
			return runtimeStatusResponse{
				CheckedAt: &checkedAt,
				Runtimes: []runtimeAccountStatus{{
					ID: "codex", Title: "Codex", Enabled: true, State: state,
				}},
			}
		},
		func() runtimeStatusResponse { return runtimeStatusResponse{} },
	)
	defer cache.Close()

	_ = cache.Snapshot()
	<-firstStarted
	accountState.Store(1)
	result := make(chan runtimeStatusResponse, 1)
	go func() { result <- cache.Refresh(context.Background()) }()
	time.Sleep(20 * time.Millisecond)
	if got := probes.Load(); got != 1 {
		t.Fatalf("manual refresh must wait for the in-flight probe before its follow-up: probes=%d", got)
	}
	close(releaseFirst)

	select {
	case response := <-result:
		if got := probes.Load(); got != 2 {
			t.Fatalf("manual refresh must run one follow-up probe: probes=%d", got)
		}
		if len(response.Runtimes) != 1 || response.Runtimes[0].State != runtimeStateConnected {
			t.Fatalf("manual refresh returned the pre-click sample: %+v", response)
		}
	case <-time.After(time.Second):
		t.Fatal("manual refresh did not finish after the follow-up probe")
	}
}

func TestRuntimeStatusHandlerWaitRefreshBypassesCache(t *testing.T) {
	checkedAt := time.Date(2026, time.August, 26, 9, 0, 0, 0, time.UTC)
	var probes atomic.Int32
	cache := newRuntimeStatusSnapshotCache(
		func(context.Context) runtimeStatusResponse {
			probes.Add(1)
			current := checkedAt
			return runtimeStatusResponse{
				CheckedAt: &current,
				Runtimes: []runtimeAccountStatus{{
					ID: "codex", Title: "Codex", Enabled: true, State: runtimeStateConnected,
				}},
			}
		},
		func() runtimeStatusResponse { return runtimeStatusResponse{} },
	)
	defer cache.Close()
	_ = cache.Refresh(context.Background())
	checkedAt = checkedAt.Add(time.Minute)

	router := &Router{runtimeStatus: cache}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/runtime/status?refresh=wait", nil)
	request.RemoteAddr = "127.0.0.1:12345"
	router.runtimeStatusHandler(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("强制刷新 HTTP 状态 = %d body=%s", recorder.Code, recorder.Body.String())
	}
	var response runtimeStatusResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.CheckedAt == nil || !response.CheckedAt.Equal(checkedAt) || response.Refreshing || response.Stale {
		t.Fatalf("强制刷新端点未等待新快照：%+v", response)
	}
	if probes.Load() != 2 {
		t.Fatalf("强制刷新端点必须绕过缓存：probes=%d", probes.Load())
	}
}

func TestRuntimeStatusUnavailableQuotaUsesFailureTTL(t *testing.T) {
	response := runtimeStatusResponse{
		Runtimes: []runtimeAccountStatus{{
			ID:      "claude",
			Title:   "Claude",
			Enabled: true,
			State:   runtimeStateAvailable,
			RateLimits: &runtimeRateLimits{
				Availability:      "unavailable",
				UnavailableReason: "headless_statusline_unavailable",
			},
		}},
	}
	if !runtimeStatusHasFailure(response) {
		t.Fatal("Claude 额度不可用应使用短失败 TTL，以便登录后自动重试")
	}
}

func TestClaudeUnavailableQuotaIsNotCached(t *testing.T) {
	router := &Router{}
	router.storeClaudeRuntimeQuota(&runtimeRateLimits{
		Availability:      "unavailable",
		UnavailableReason: "headless_statusline_unavailable",
	})
	if cached := router.cachedClaudeRuntimeQuota(time.Now().UTC()); cached != nil {
		t.Fatalf("不可用结果不能阻止后续 OAuth 额度重试：%+v", cached)
	}

	router.storeClaudeRuntimeQuota(&runtimeRateLimits{Availability: "available"})
	if cached := router.cachedClaudeRuntimeQuota(time.Now().UTC()); cached == nil {
		t.Fatal("可用 Claude 额度仍应进入短缓存")
	}
}

func readRuntimeStatusEventually(
	t *testing.T,
	handler http.Handler,
) (*httptest.ResponseRecorder, runtimeStatusResponse) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		rec := httptest.NewRecorder()
		req := authedRequest(t, http.MethodGet, "/api/runtime/status", nil)
		req.RemoteAddr = "127.0.0.1:43210"
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("runtime status 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
		}
		var response runtimeStatusResponse
		if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
			t.Fatalf("runtime status 响应无法解析：%v", err)
		}
		if !response.Refreshing {
			return rec, response
		}
		if time.Now().After(deadline) {
			t.Fatalf("runtime status 后台刷新超时：%+v", response)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func runtimeStatusCodexResponder(t *testing.T) func(*websocket.Conn, int, []byte) {
	t.Helper()
	return func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("无法解析 fake app-server frame：%v", err)
			return
		}
		var result any
		switch frame.Method {
		case "initialize":
			result = map[string]any{"userAgent": "fake-codex"}
		case "initialized":
			return
		case "account/read":
			result = map[string]any{
				"account": map[string]any{
					"type":     "chatgpt",
					"email":    "owner@example.com",
					"planType": "plus",
				},
				"requiresOpenaiAuth": true,
			}
		case "account/rateLimits/read":
			result = map[string]any{
				"rateLimitsByLimitId": map[string]any{
					"codex": map[string]any{
						"limitId":   "codex",
						"limitName": "Codex",
						"planType":  "plus",
						"primary": map[string]any{
							"usedPercent":        62.5,
							"windowDurationMins": 300,
							"resetsAt":           1_780_494_300,
						},
						"secondary": map[string]any{
							"usedPercent":        30,
							"windowDurationMins": 10_080,
							"resetsAt":           1_781_099_100,
						},
						"credits": map[string]any{
							"hasCredits": true,
							"unlimited":  false,
							"balance":    "12.34",
						},
					},
				},
			}
		default:
			t.Errorf("fake app-server 收到未知方法：%s", frame.Method)
			return
		}
		response, err := json.Marshal(map[string]any{
			"id":     frame.ID,
			"result": result,
		})
		if err != nil {
			t.Error(err)
			return
		}
		if err := conn.WriteMessage(messageType, response); err != nil {
			t.Errorf("fake app-server 写响应失败：%v", err)
		}
	}
}
