package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gorilla/websocket"
)

func TestSanitizeThreadListMetaMatrix(t *testing.T) {
	tests := []struct {
		name      string
		raw       string
		wantHas   bool
		wantErr   bool
		wantCheck func(t *testing.T, meta map[string]any)
	}{
		{
			name:    "absent",
			raw:     "",
			wantHas: false,
		},
		{
			name:    "explicit_null",
			raw:     `null`,
			wantHas: false,
		},
		{
			name:    "valid_healthy",
			raw:     `{"schemaVersion":1,"complete":true}`,
			wantHas: true,
			wantCheck: func(t *testing.T, meta map[string]any) {
				if meta["schemaVersion"] != 1 || meta["complete"] != true {
					t.Fatalf("unexpected healthy meta: %+v", meta)
				}
				if _, ok := meta["degradedReason"]; ok {
					t.Fatalf("healthy meta must not carry degradedReason: %+v", meta)
				}
			},
		},
		{
			name:    "rejects_healthy_with_null_degraded_fields",
			raw:     `{"schemaVersion":1,"complete":true,"degradedReason":null,"degradedSources":null}`,
			wantErr: true,
		},
		{
			name:    "valid_healthy_with_sources",
			raw:     `{"schemaVersion":1,"complete":true,"sources":["cli","other"]}`,
			wantHas: true,
			wantCheck: func(t *testing.T, meta map[string]any) {
				sources, ok := meta["sources"].([]string)
				if !ok || len(sources) != 2 {
					t.Fatalf("expected 2 sources, got %+v", meta["sources"])
				}
			},
		},
		{
			name:    "valid_degraded",
			raw:     `{"schemaVersion":1,"complete":false,"degradedReason":"other_timeout","degradedSources":["other"]}`,
			wantHas: true,
			wantCheck: func(t *testing.T, meta map[string]any) {
				if meta["complete"] != false || meta["degradedReason"] != "other_timeout" {
					t.Fatalf("unexpected degraded meta: %+v", meta)
				}
				sources, ok := meta["degradedSources"].([]string)
				if !ok || len(sources) != 1 || sources[0] != "other" {
					t.Fatalf("expected [other] degradedSources, got %+v", meta["degradedSources"])
				}
			},
		},
		{
			name:    "forbids_pageDisposition_injection",
			raw:     `{"schemaVersion":1,"complete":true,"pageDisposition":"advance"}`,
			wantErr: true,
		},
		{
			name:    "forbids_retryReason_injection",
			raw:     `{"schemaVersion":1,"complete":true,"retryReason":"git_ownership_pending"}`,
			wantErr: true,
		},
		{
			name:    "forbids_unknown_key",
			raw:     `{"schemaVersion":1,"complete":true,"extra":1}`,
			wantErr: true,
		},
		{
			name:    "rejects_non_object",
			raw:     `[]`,
			wantErr: true,
		},
		{
			name:    "rejects_wrong_schemaVersion",
			raw:     `{"schemaVersion":2,"complete":true}`,
			wantErr: true,
		},
		{
			name:    "rejects_float_schemaVersion",
			raw:     `{"schemaVersion":1.5,"complete":true}`,
			wantErr: true,
		},
		{
			name:    "rejects_missing_complete",
			raw:     `{"schemaVersion":1}`,
			wantErr: true,
		},
		{
			name:    "rejects_complete_true_with_degradedReason",
			raw:     `{"schemaVersion":1,"complete":true,"degradedReason":"db_locked"}`,
			wantErr: true,
		},
		{
			name:    "rejects_complete_true_with_empty_degradedReason",
			raw:     `{"schemaVersion":1,"complete":true,"degradedReason":""}`,
			wantErr: true,
		},
		{
			name:    "rejects_complete_true_with_degradedSources",
			raw:     `{"schemaVersion":1,"complete":true,"degradedSources":[]}`,
			wantErr: true,
		},
		{
			name:    "rejects_complete_false_without_degradedReason",
			raw:     `{"schemaVersion":1,"complete":false,"degradedSources":["cli_sqlite"]}`,
			wantErr: true,
		},
		{
			name:    "rejects_complete_false_without_degradedSources",
			raw:     `{"schemaVersion":1,"complete":false,"degradedReason":"db_locked","degradedSources":[]}`,
			wantErr: true,
		},
		{
			name:    "rejects_duplicate_degradedSources",
			raw:     `{"schemaVersion":1,"complete":false,"degradedReason":"db_locked","degradedSources":["cli_sqlite","cli_sqlite"]}`,
			wantErr: true,
		},
		{
			name:    "rejects_unknown_degradedSource",
			raw:     `{"schemaVersion":1,"complete":false,"degradedReason":"db_locked","degradedSources":["unknown_source"]}`,
			wantErr: true,
		},
		{
			name:    "rejects_whitespace_degradedReason",
			raw:     `{"schemaVersion":1,"complete":false,"degradedReason":"  db_locked ","degradedSources":["cli_sqlite"]}`,
			wantErr: true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta, has, err := sanitizeThreadListMeta(json.RawMessage(tc.raw))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got meta=%+v has=%v", meta, has)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if has != tc.wantHas {
				t.Fatalf("has=%v want=%v meta=%+v", has, tc.wantHas, meta)
			}
			if tc.wantCheck != nil {
				tc.wantCheck(t, meta)
			}
		})
	}
}

func TestValidateThreadListNextCursorAndRPCErrorObject(t *testing.T) {
	if has, _, _, err := validateThreadListNextCursor(map[string]json.RawMessage{}); err == nil || has {
		t.Fatalf("missing nextCursor key must fail")
	}
	if has, raw, trimmed, err := validateThreadListNextCursor(map[string]json.RawMessage{"nextCursor": json.RawMessage(`null`)}); err != nil || has || raw != "" || trimmed != "" {
		t.Fatalf("null nextCursor must succeed as exhausted, got has=%v raw=%q trimmed=%q err=%v", has, raw, trimmed, err)
	}
	if has, raw, trimmed, err := validateThreadListNextCursor(map[string]json.RawMessage{"nextCursor": json.RawMessage(`"  cur-1  "`)}); err != nil || !has || raw != "  cur-1  " || trimmed != "cur-1" {
		t.Fatalf("valid string nextCursor failed: has=%v raw=%q trimmed=%q err=%v", has, raw, trimmed, err)
	}
	for _, bad := range []string{`""`, `"   "`, `123`, `true`, `{}`, `[]`} {
		if _, _, _, err := validateThreadListNextCursor(map[string]json.RawMessage{"nextCursor": json.RawMessage(bad)}); err == nil {
			t.Fatalf("expected error for bad nextCursor=%s", bad)
		}
	}

	validErrs := []string{
		`{"code":-32602,"message":"invalid params"}`,
		`{"code":0,"message":""}`,
		`{"code":400,"message":"bad","data":{"x":1}}`,
	}
	for _, raw := range validErrs {
		if !isValidJSONRPCErrorObject(json.RawMessage(raw)) {
			t.Fatalf("expected valid JSON-RPC error: %s", raw)
		}
	}
	invalidErrs := []string{
		``, `null`, `[]`, `{}`,
		`{"code":1}`,
		`{"message":"missing code"}`,
		`{"code":"-32000","message":"string code"}`,
		`{"code":1.5,"message":"float code"}`,
		`{"code":1,"message":123}`,
		`{"code":1,"message":null}`,
	}
	for _, raw := range invalidErrs {
		if isValidJSONRPCErrorObject(json.RawMessage(raw)) {
			t.Fatalf("expected invalid JSON-RPC error: %s", raw)
		}
	}
}

func TestAppServerConfigDeclaresGlobalListPageDispositionCapability(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	claudeBridge := writeTestBridgeWithVersion(t, "alleycat-claude-bridge 0.2.15")
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = claudeBridge
		cfg.Agy.Enabled = true
	})
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/app-server/config", nil))
	body := decodeJSON(t, rec)
	channels, ok := body["channels"].([]any)
	if !ok || len(channels) < 3 {
		t.Fatalf("expected at least 3 channels, got %+v", body["channels"])
	}
	seen := map[string]bool{}
	for _, ch := range channels {
		m, _ := ch.(map[string]any)
		id, _ := m["id"].(string)
		caps, _ := m["capabilities"].(map[string]any)
		if id == "codex" || id == "claude" || id == "agy" {
			if caps["global_list_page_disposition_v1"] != true {
				t.Fatalf("channel %s missing global_list_page_disposition_v1=true: %+v", id, caps)
			}
			seen[id] = true
		}
	}
	if len(seen) != 3 {
		t.Fatalf("expected codex/claude/agy channels, got %+v", seen)
	}
}

func TestPhase0FixturesReplayThroughObserveUpstreamFrame(t *testing.T) {
	fixtureRoot := filepath.Join("..", "..", "scripts", "testdata", "all-runtimes-phase0")
	projectDir := t.TempDir()
	alphaDir := filepath.Join(projectDir, "alpha")
	if err := os.MkdirAll(alphaDir, 0o755); err != nil {
		t.Fatal(err)
	}
	deletedDir := filepath.Join(projectDir, "deleted-repo")

	newFixturePolicy := func(runtimeID string) (*Router, *appServerGatewayPolicy) {
		registry, err := projects.NewRegistry([]config.ProjectConfig{
			{ID: "proj-alpha", Name: "Alpha", Path: alphaDir},
		})
		if err != nil {
			t.Fatal(err)
		}
		router := &Router{
			cfg:            config.Config{BrowseRoots: []string{projectDir}},
			projects:       registry,
			gatewayThreads: map[string]appServerGatewayAllowedThread{},
		}
		return router, newAppServerGatewayPolicy(router, runtimeID)
	}

	replaceDemoPaths := func(raw []byte) []byte {
		out := bytes.ReplaceAll(raw, []byte("/Users/demo/workspace/alpha"), []byte(alphaDir))
		out = bytes.ReplaceAll(out, []byte("/Users/demo/workspace/deleted-repo"), []byte(deletedDir))
		return out
	}

	t.Run("accepted_codex_and_claude_sdk_and_legacy_rust_and_agy", func(t *testing.T) {
		type acceptedCase struct {
			file       string
			runtimeID  string
			exchangeIx int // -1 means top-level .response
			global     bool
			wantID     string
			wantCLI    string
			wantBack   bool
		}
		cases := []acceptedCase{
			{file: "accepted/codex-recency-at-null.json", runtimeID: "codex", exchangeIx: 0, global: false, wantID: "01961f3a-0000-7000-8000-000000000002"},
			{file: "accepted/codex-recency-at-null.json", runtimeID: "codex", exchangeIx: 0, global: true, wantID: "01961f3a-0000-7000-8000-000000000002", wantCLI: "0.171.0"},
			{file: "accepted/claude-sdk-empty-cwd.json", runtimeID: "claude", exchangeIx: -1, global: true, wantID: "22222222-2222-4222-8222-222222222222", wantCLI: "mimi-claude-adapter/0.3.0"},
			{file: "accepted/claude-sdk-empty-cwd.json", runtimeID: "claude", exchangeIx: -1, global: false, wantID: "22222222-2222-4222-8222-222222222222"},
			{file: "accepted/claude-legacy-rust-ms.json", runtimeID: "claude", exchangeIx: 0, global: false, wantID: "thr_rust_001_x", wantBack: true},
			{file: "accepted/claude-legacy-rust-ms.json", runtimeID: "claude", exchangeIx: 0, global: true, wantID: "thr_rust_001_x", wantCLI: "alleycat-claude-bridge/0.2.15"},
			{file: "accepted/agy-acp-current-list.json", runtimeID: "agy", exchangeIx: -1, global: true, wantID: "agy-cli-0001", wantCLI: "mimi-agy-adapter/0.1.0"},
			{file: "accepted/agy-acp-current-list.json", runtimeID: "agy", exchangeIx: -1, global: false, wantID: "agy-cli-0001"},
		}
		for _, tc := range cases {
			raw, err := os.ReadFile(filepath.Join(fixtureRoot, tc.file))
			if err != nil {
				t.Fatalf("read %s: %v", tc.file, err)
			}
			var doc struct {
				Response  json.RawMessage `json:"response"`
				Exchanges []struct {
					Response json.RawMessage `json:"response"`
				} `json:"exchanges"`
			}
			if err := json.Unmarshal(raw, &doc); err != nil {
				t.Fatalf("unmarshal %s: %v", tc.file, err)
			}
			resp := doc.Response
			if tc.exchangeIx >= 0 {
				resp = doc.Exchanges[tc.exchangeIx].Response
			}
			resp = replaceDemoPaths(resp)

			var frame appServerGatewayFrame
			if err := json.Unmarshal(resp, &frame); err != nil {
				t.Fatalf("parse response frame %s: %v", tc.file, err)
			}

			_, policy := newFixturePolicy(tc.runtimeID)
			pending := appServerGatewayPendingThreadRequest{
				method:          "thread/list",
				globalDiscovery: tc.global,
			}
			if !tc.global {
				pending.cwd = alphaDir
				pending.scopeID = "proj-alpha"
			}
			if err := policy.rememberPendingThreadRequest(frame.ID, pending); err != nil {
				t.Fatalf("rememberPending %s: %v", tc.file, err)
			}
			out, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, resp)
			if !forward || policyErr != nil {
				t.Fatalf("%s (global=%v) expected forward, got forward=%v err=%+v", tc.file, tc.global, forward, policyErr)
			}
			var decoded struct {
				Result map[string]any `json:"result"`
			}
			if err := json.Unmarshal(out, &decoded); err != nil {
				t.Fatalf("decode output %s: %v", tc.file, err)
			}
			items, _ := decoded.Result["data"].([]any)
			found := false
			for _, it := range items {
				m, _ := it.(map[string]any)
				if m["id"] == tc.wantID {
					found = true
					if tc.wantCLI != "" && m["cliVersion"] != tc.wantCLI {
						t.Fatalf("%s (global=%v) lost cliVersion: got=%v want=%q", tc.file, tc.global, m["cliVersion"], tc.wantCLI)
					}
				}
			}
			if !found {
				t.Fatalf("%s (global=%v) missing expected thread %s in %s", tc.file, tc.global, tc.wantID, out)
			}
			if tc.wantBack {
				if _, ok := decoded.Result["backwardsCursor"].(string); !ok {
					t.Fatalf("%s scoped response must preserve backwardsCursor: %s", tc.file, out)
				}
			}
		}
	})

	t.Run("malformed_fixtures_rejected_across_global_and_scoped", func(t *testing.T) {
		malformedFiles := []string{
			"malformed/missing-next-cursor-key.json",
			"malformed/non-array-data.json",
			"malformed/blank-thread-id.json",
			"malformed/invalid-cwd-type.json",
		}
		for _, file := range malformedFiles {
			raw, err := os.ReadFile(filepath.Join(fixtureRoot, file))
			if err != nil {
				t.Fatalf("read %s: %v", file, err)
			}
			var doc struct {
				Response json.RawMessage `json:"response"`
			}
			if err := json.Unmarshal(raw, &doc); err != nil {
				t.Fatalf("unmarshal %s: %v", file, err)
			}
			resp := replaceDemoPaths(doc.Response)
			var frame appServerGatewayFrame
			_ = json.Unmarshal(resp, &frame)

			for _, global := range []bool{true, false} {
				_, policy := newFixturePolicy("codex")
				pending := appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: global}
				if !global {
					pending.cwd = alphaDir
					pending.scopeID = "proj-alpha"
				}
				if err := policy.rememberPendingThreadRequest(frame.ID, pending); err != nil {
					t.Fatal(err)
				}
				_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, resp)
				if forward || policyErr == nil || policyErr.data["reason"] != "upstream_malformed_thread_list" {
					t.Fatalf("%s (global=%v) expected upstream_malformed_thread_list, got forward=%v err=%+v", file, global, forward, policyErr)
				}
			}
		}
	})
}

func TestGlobalThreadListDispositionStalledCursorAndScopedPassthrough(t *testing.T) {
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:            config.Config{},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := newAppServerGatewayPolicy(router, "codex")

	// 1) Global advance page emits listMeta.pageDisposition = "advance" and mimi_ token.
	id1 := json.RawMessage(`1`)
	if err := policy.rememberPendingThreadRequest(&id1, appServerGatewayPendingThreadRequest{
		method:          "thread/list",
		globalDiscovery: true,
		upstreamCursor:  "up-cursor-1",
	}); err != nil {
		t.Fatal(err)
	}
	resp1 := []byte(fmt.Sprintf(`{"id":1,"result":{"data":[{"id":"t-1","cwd":%q,"cliVersion":"0.171.0"}],"nextCursor":"up-cursor-2","listMeta":{"schemaVersion":1,"complete":true}}}`, projectDir))
	out1, forward1, err1 := policy.observeUpstreamFrame(websocket.TextMessage, resp1)
	if !forward1 || err1 != nil {
		t.Fatalf("expected forward, got forward=%v err=%+v", forward1, err1)
	}
	var parsed1 struct {
		Result struct {
			Data       []map[string]any `json:"data"`
			NextCursor string           `json:"nextCursor"`
			ListMeta   map[string]any   `json:"listMeta"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out1, &parsed1); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(parsed1.Result.NextCursor, "mimi_") {
		t.Fatalf("expected mimi_ token, got %q", parsed1.Result.NextCursor)
	}
	if parsed1.Result.ListMeta["pageDisposition"] != "advance" || parsed1.Result.ListMeta["complete"] != true {
		t.Fatalf("unexpected listMeta: %+v", parsed1.Result.ListMeta)
	}
	if len(parsed1.Result.Data) != 1 || parsed1.Result.Data[0]["cliVersion"] != "0.171.0" {
		t.Fatalf("expected cliVersion passthrough, got %+v", parsed1.Result.Data)
	}

	// 2) Global stalled cursor (nextCursor == request.upstreamCursor when incomplete==false) is rejected with zero budget / no mimi_ token.
	id2 := json.RawMessage(`2`)
	if err := policy.rememberPendingThreadRequest(&id2, appServerGatewayPendingThreadRequest{
		method:          "thread/list",
		globalDiscovery: true,
		upstreamCursor:  "up-cursor-2",
	}); err != nil {
		t.Fatal(err)
	}
	respStalled := []byte(fmt.Sprintf(`{"id":2,"result":{"data":[{"id":"t-stalled","cwd":%q}],"nextCursor":"up-cursor-2"}}`, projectDir))
	_, forward2, err2 := policy.observeUpstreamFrame(websocket.TextMessage, respStalled)
	if forward2 || err2 == nil || err2.data["reason"] != "upstream_stalled_thread_list_cursor" {
		t.Fatalf("expected upstream_stalled_thread_list_cursor, got forward=%v err=%+v", forward2, err2)
	}
	if _, ok := policy.allowedThread("t-stalled"); ok {
		t.Fatalf("stalled cursor response must not authorize threads")
	}

	// 3) Scoped preserves raw nextCursor bytes (including surrounding spaces) and backwardsCursor.
	id3 := json.RawMessage(`3`)
	if err := policy.rememberPendingThreadRequest(&id3, appServerGatewayPendingThreadRequest{
		method:  "thread/list",
		cwd:     projectDir,
		scopeID: "demo",
	}); err != nil {
		t.Fatal(err)
	}
	respScoped := []byte(fmt.Sprintf(`{"id":3,"result":{"data":[{"id":"t-scoped","cwd":%q}],"nextCursor":"  raw-cur-3  ","backwardsCursor":"back-cur-3"}}`, projectDir))
	out3, forward3, err3 := policy.observeUpstreamFrame(websocket.TextMessage, respScoped)
	if !forward3 || err3 != nil {
		t.Fatalf("expected scoped forward, got forward=%v err=%+v", forward3, err3)
	}
	var parsed3 struct {
		Result map[string]any `json:"result"`
	}
	_ = json.Unmarshal(out3, &parsed3)
	if parsed3.Result["nextCursor"] != "  raw-cur-3  " || parsed3.Result["backwardsCursor"] != "back-cur-3" {
		t.Fatalf("scoped must preserve raw nextCursor & backwardsCursor, got %+v", parsed3.Result)
	}
}

func TestGlobalThreadListSamePageRetryAndMalformedCursorPriority(t *testing.T) {
	browseRoot := t.TempDir()
	unsettledDir := filepath.Join(browseRoot, "repo-unsettled")
	if err := os.MkdirAll(filepath.Join(unsettledDir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry(nil)
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:            config.Config{BrowseRoots: []string{browseRoot}},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	oldWait := appServerGatewayGlobalListGitWait
	appServerGatewayGlobalListGitWait = 1 * time.Nanosecond
	defer func() { appServerGatewayGlobalListGitWait = oldWait }()

	// Seed a real slow probe by using a nonexistent git binary in PATH during this subtest.
	oldPath := os.Getenv("PATH")
	slowBin := t.TempDir()
	slowGit := filepath.Join(slowBin, "git")
	if err := os.WriteFile(slowGit, []byte("#!/bin/sh\nsleep 0.2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", slowBin+string(os.PathListSeparator)+oldPath)

	policy := newAppServerGatewayPolicy(router, "codex")

	// A) Valid nextCursor + unsettled git -> same_page_retry + git_ownership_pending.
	id1 := json.RawMessage(`10`)
	if err := policy.rememberPendingThreadRequest(&id1, appServerGatewayPendingThreadRequest{
		method:          "thread/list",
		globalDiscovery: true,
		upstreamCursor:  "page-1",
	}); err != nil {
		t.Fatal(err)
	}
	respRetry := []byte(fmt.Sprintf(`{"id":10,"result":{"data":[{"id":"t-unsettled","cwd":%q}],"nextCursor":"page-2"}}`, unsettledDir))
	out1, forward1, err1 := policy.observeUpstreamFrame(websocket.TextMessage, respRetry)
	if !forward1 || err1 != nil {
		t.Fatalf("expected same_page_retry forward, got forward=%v err=%+v", forward1, err1)
	}
	var parsed1 struct {
		Result struct {
			NextCursor string         `json:"nextCursor"`
			ListMeta   map[string]any `json:"listMeta"`
		} `json:"result"`
	}
	_ = json.Unmarshal(out1, &parsed1)
	if parsed1.Result.ListMeta["pageDisposition"] != "same_page_retry" ||
		parsed1.Result.ListMeta["retryReason"] != "git_ownership_pending" ||
		!strings.HasPrefix(parsed1.Result.NextCursor, "mimi_") {
		t.Fatalf("expected same_page_retry + git_ownership_pending, got %+v cursor=%q", parsed1.Result.ListMeta, parsed1.Result.NextCursor)
	}

	// B) Malformed nextCursor MUST STILL BE REJECTED even when git is unsettled!
	id2 := json.RawMessage(`11`)
	if err := policy.rememberPendingThreadRequest(&id2, appServerGatewayPendingThreadRequest{
		method:          "thread/list",
		globalDiscovery: true,
	}); err != nil {
		t.Fatal(err)
	}
	respBadCursor := []byte(fmt.Sprintf(`{"id":11,"result":{"data":[{"id":"t-unsettled-2","cwd":%q}],"nextCursor":""}}`, unsettledDir))
	_, forward2, err2 := policy.observeUpstreamFrame(websocket.TextMessage, respBadCursor)
	if forward2 || err2 == nil || err2.data["reason"] != "upstream_malformed_thread_list" {
		t.Fatalf("malformed nextCursor must be rejected even when git unsettled, got forward=%v err=%+v", forward2, err2)
	}
}

func TestThreadListCWDCompatAndAgyC15AndScopedMissingMimiRemote(t *testing.T) {
	projectDir := t.TempDir()
	browseRoot := t.TempDir()
	missingBrowseSub := filepath.Join(browseRoot, "vanished-project")
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:            config.Config{BrowseRoots: []string{browseRoot}},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}

	// 1) C2-global-empty-cwd: dual-empty dropped, valid row kept; non-string cwd/path rejects whole page.
	policy := newAppServerGatewayPolicy(router, "claude")
	id1 := json.RawMessage(`20`)
	_ = policy.rememberPendingThreadRequest(&id1, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	respDualEmpty := []byte(fmt.Sprintf(`{"id":20,"result":{"data":[{"id":"t-empty","cwd":"","path":""},{"id":"t-valid","cwd":%q}],"nextCursor":null}}`, projectDir))
	out1, forward1, err1 := policy.observeUpstreamFrame(websocket.TextMessage, respDualEmpty)
	if !forward1 || err1 != nil {
		t.Fatalf("expected dual-empty row dropped and page forwarded, got forward=%v err=%+v", forward1, err1)
	}
	if bytes.Contains(out1, []byte("t-empty")) || !bytes.Contains(out1, []byte("t-valid")) {
		t.Fatalf("unexpected global dual-empty output: %s", out1)
	}

	// 2) C2-scoped-empty-cwd-fallback: empty cwd & path falls back to pending.cwd.
	id2 := json.RawMessage(`21`)
	_ = policy.rememberPendingThreadRequest(&id2, appServerGatewayPendingThreadRequest{method: "thread/list", cwd: projectDir, scopeID: "demo"})
	respScopedFallback := []byte(`{"id":21,"result":{"data":[{"id":"t-fallback","cwd":"","path":""}],"nextCursor":null}}`)
	out2, forward2, err2 := policy.observeUpstreamFrame(websocket.TextMessage, respScopedFallback)
	if !forward2 || err2 != nil || !bytes.Contains(out2, []byte("t-fallback")) {
		t.Fatalf("scoped empty cwd must fallback to pending.cwd, got forward=%v err=%+v out=%s", forward2, err2, out2)
	}

	// 3) Agy Global C15 browse-only missing dir end-to-end via observeUpstreamFrame.
	agyPolicy := newAppServerGatewayPolicy(router, appServerRuntimeAgyID)
	id3 := json.RawMessage(`22`)
	_ = agyPolicy.rememberPendingThreadRequest(&id3, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	respAgyMissing := []byte(fmt.Sprintf(`{"id":22,"result":{"data":[{"id":"agy-missing-browse","cwd":%q,"canAcceptDirectInput":false,"cwdMissing":true}],"nextCursor":null}}`, missingBrowseSub))
	out3, forward3, err3 := agyPolicy.observeUpstreamFrame(websocket.TextMessage, respAgyMissing)
	if !forward3 || err3 != nil || !bytes.Contains(out3, []byte("agy-missing-browse")) {
		t.Fatalf("Agy C15 browse-only missing dir must survive Global observeUpstreamFrame: forward=%v err=%+v out=%s", forward3, err3, out3)
	}
	allowedAgy, ok := agyPolicy.allowedThread("agy-missing-browse")
	if !ok || !allowedAgy.readOnly || !allowedAgy.readOnlyBrowseScope || !allowedAgy.cwdMissing {
		t.Fatalf("unexpected Agy C15 allowed state: ok=%v %+v", ok, allowedAgy)
	}

	// 4) Scoped missing mimiRemote creates {readOnly:true, cwdMissing:true} on read-only rows.
	missingSubInDemo := filepath.Join(projectDir, "gone-sub")
	id4 := json.RawMessage(`23`)
	_ = policy.rememberPendingThreadRequest(&id4, appServerGatewayPendingThreadRequest{method: "thread/list", cwd: projectDir, scopeID: "demo"})
	respScopedMissing := []byte(fmt.Sprintf(`{"id":23,"result":{"data":[{"id":"t-scoped-missing","cwd":%q,"canAcceptDirectInput":true}],"nextCursor":null}}`, missingSubInDemo))
	out4, forward4, err4 := policy.observeUpstreamFrame(websocket.TextMessage, respScopedMissing)
	if !forward4 || err4 != nil {
		t.Fatalf("expected scoped missing row forward, got forward=%v err=%+v", forward4, err4)
	}
	var parsed4 struct {
		Result struct {
			Data []map[string]any `json:"data"`
		} `json:"result"`
	}
	_ = json.Unmarshal(out4, &parsed4)
	if len(parsed4.Result.Data) != 1 {
		t.Fatalf("expected 1 row, got %s", out4)
	}
	row := parsed4.Result.Data[0]
	mimiRemote, _ := row["mimiRemote"].(map[string]any)
	if row["canAcceptDirectInput"] != false || row["cwdMissing"] != true || mimiRemote["readOnly"] != true || mimiRemote["cwdMissing"] != true {
		t.Fatalf("scoped missing row must materialize mimiRemote readOnly/cwdMissing, got %+v", row)
	}
}

func TestGlobalThreadListContinuationZeroBillingAnd512Cap(t *testing.T) {
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:            config.Config{},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := newAppServerGatewayPolicy(router, "codex")

	// Reserve page 1 via validateClientFrame -> observeUpstreamFrame -> issues cursor token + continuation.
	req1 := []byte(`{"id":1,"method":"thread/list","params":{"limit":20}}`)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, req1); policyErr != nil {
		t.Fatalf("req1 failed: %+v", policyErr)
	}
	resp1 := []byte(fmt.Sprintf(`{"id":1,"result":{"data":[{"id":"t-1","cwd":%q}],"nextCursor":"up-2"}}`, projectDir))
	out1, forward1, err1 := policy.observeUpstreamFrame(websocket.TextMessage, resp1)
	if !forward1 || err1 != nil {
		t.Fatalf("resp1 failed: forward=%v err=%+v", forward1, err1)
	}
	var p1 struct {
		Result struct {
			NextCursor string `json:"nextCursor"`
		} `json:"result"`
	}
	_ = json.Unmarshal(out1, &p1)
	token := p1.Result.NextCursor

	// Count request budget hits before using continuation cursor.
	key := gatewayHistoryBudgetKey("thread-list-global", "thread/list", "list")
	policy.mu.Lock()
	beforeCount := policy.historyBudgets[key].requests
	policy.mu.Unlock()

	// Using the issued continuation token consumes continuation (exempt from request count billing).
	req2 := []byte(fmt.Sprintf(`{"id":2,"method":"thread/list","params":{"limit":20,"cursor":%q}}`, token))
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, req2); policyErr != nil {
		t.Fatalf("continuation req2 failed: %+v", policyErr)
	}
	policy.mu.Lock()
	afterContCount := policy.historyBudgets[key].requests
	policy.mu.Unlock()
	if afterContCount != beforeCount {
		t.Fatalf("continuation cursor should not increment request count: before=%d after=%d", beforeCount, afterContCount)
	}

	// Re-using the SAME cursor token (duplicate cursor) MUST NOT have a second continuation credit; it must bill request count!
	req3 := []byte(fmt.Sprintf(`{"id":3,"method":"thread/list","params":{"limit":20,"cursor":%q}}`, token))
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, req3); policyErr != nil {
		t.Fatalf("duplicate req3 failed: %+v", policyErr)
	}
	policy.mu.Lock()
	afterDupCount := policy.historyBudgets[key].requests
	policy.mu.Unlock()
	if afterDupCount != afterContCount+1 {
		t.Fatalf("duplicate cursor must bill request count: afterCont=%d afterDup=%d", afterContCount, afterDupCount)
	}
}
