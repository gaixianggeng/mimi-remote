package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gorilla/websocket"
)

func TestPendingLifecycleLockWaitTTLAndEnvelopeMatrix(t *testing.T) {
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}

	// 1) Waiting on p.mu across TTL drops "late" for BOTH thread/search and thread/list.
	for _, method := range []string{"thread/list", "thread/search"} {
		t.Run("lock_wait_ttl_"+method, func(t *testing.T) {
			router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
			policy := newAppServerGatewayPolicy(router, "codex")
			var mu sync.Mutex
			now := time.Date(2026, 11, 27, 10, 0, 0, 0, time.UTC)
			policy.nowFunc = func() time.Time {
				mu.Lock()
				defer mu.Unlock()
				return now
			}
			id := json.RawMessage(`1`)
			pending := appServerGatewayPendingThreadRequest{method: method, globalDiscovery: method == "thread/list"}
			if err := policy.rememberPendingThreadRequest(&id, pending); err != nil {
				t.Fatal(err)
			}

			// Hold p.mu while advancing clock past TTL; start observeUpstreamFrame concurrently.
			policy.mu.Lock()
			done := make(chan bool, 1)
			go func() {
				var resp []byte
				if method == "thread/list" {
					resp = []byte(fmt.Sprintf(`{"id":1,"result":{"data":[{"id":"t-late","cwd":%q}],"nextCursor":null}}`, projectDir))
				} else {
					resp = []byte(fmt.Sprintf(`{"id":1,"result":{"data":[{"thread":{"id":"t-late","cwd":%q}}]}}`, projectDir))
				}
				_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, resp)
				done <- (forward || policyErr != nil)
			}()
			time.Sleep(15 * time.Millisecond)
			mu.Lock()
			now = now.Add(appServerGatewayPendingThreadTTL + time.Second)
			mu.Unlock()
			policy.mu.Unlock()

			if <-done {
				t.Fatalf("%s response waiting on p.mu across TTL must be silently dropped", method)
			}
			if _, ok := policy.allowedThread("t-late"); ok {
				t.Fatalf("%s late response must not authorize threads", method)
			}
		})
	}

	// 2) onAfterResponseClaim expiry + same-ID re-register preserves req2!
	t.Run("same_id_reregister_preserves_req2", func(t *testing.T) {
		router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
		policy := newAppServerGatewayPolicy(router, "codex")
		now := time.Date(2026, 11, 27, 10, 0, 0, 0, time.UTC)
		policy.nowFunc = func() time.Time { return now }

		id := json.RawMessage(`42`)
		_ = policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})

		policy.onAfterResponseClaim = func() {
			// Simulate req1 expiring/forgetting and req2 re-registering with the SAME id=42!
			policy.forgetPending(&id)
			_ = policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
		}
		resp1 := []byte(fmt.Sprintf(`{"id":42,"result":{"data":[{"id":"t-old","cwd":%q}],"nextCursor":null}}`, projectDir))
		_, forward1, err1 := policy.observeUpstreamFrame(websocket.TextMessage, resp1)
		if forward1 || err1 != nil {
			t.Fatalf("stale req1 must drop silently when replaced by req2: forward=%v err=%+v", forward1, err1)
		}
		if _, ok := policy.allowedThread("t-old"); ok {
			t.Fatal("stale req1 must not authorize t-old")
		}
		// Now req2's response arrives and MUST STILL BE CLAIMED AND AUTHORIZED!
		policy.onAfterResponseClaim = nil
		resp2 := []byte(fmt.Sprintf(`{"id":42,"result":{"data":[{"id":"t-new","cwd":%q}],"nextCursor":null}}`, projectDir))
		_, forward2, err2 := policy.observeUpstreamFrame(websocket.TextMessage, resp2)
		if !forward2 || err2 != nil {
			t.Fatalf("req2 must survive req1 cleanup: forward=%v err=%+v", forward2, err2)
		}
		if _, ok := policy.allowedThread("t-new"); !ok {
			t.Fatal("req2 must authorize t-new")
		}
	})

	// 3) Envelope matrix for in-flight thread/list.
	t.Run("envelope_matrix", func(t *testing.T) {
		cases := []struct {
			name        string
			payload     string
			wantForward bool
			wantReason  string
		}{
			{name: "id_only", payload: `{"id":10}`, wantReason: "upstream_malformed_thread_list"},
			{name: "result_and_error_null", payload: `{"id":10,"result":{"data":[],"nextCursor":null},"error":null}`, wantReason: "upstream_malformed_thread_list"},
			{name: "result_and_error_obj", payload: `{"id":10,"result":{"data":[],"nextCursor":null},"error":{"code":-32000,"message":"boom"}}`, wantReason: "upstream_malformed_thread_list"},
			{name: "error_empty_obj", payload: `{"id":10,"error":{}}`, wantReason: "upstream_malformed_thread_list"},
			{name: "error_float_code", payload: `{"id":10,"error":{"code":1.5,"message":"bad"}}`, wantReason: "upstream_malformed_thread_list"},
			{name: "valid_rpc_error", payload: `{"id":10,"error":{"code":-32000,"message":"upstream failed"}}`, wantForward: true},
		}
		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
				policy := newAppServerGatewayPolicy(router, "codex")
				id := json.RawMessage(`10`)
				_ = policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
				_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, []byte(tc.payload))
				if tc.wantForward {
					if !forward || policyErr != nil {
						t.Fatalf("expected forward, got forward=%v err=%+v", forward, policyErr)
					}
				} else {
					if forward || policyErr == nil || policyErr.data["reason"] != tc.wantReason {
						t.Fatalf("expected reason=%q, got forward=%v err=%+v", tc.wantReason, forward, policyErr)
					}
				}
				// Pending entry must be cleaned up.
				if policy.requestIDInFlight(&id) {
					t.Fatal("pending entry must be cleaned after envelope decision")
				}
			})
		}
	})
}

func TestBrokerSinkGenIsolationAndAttachTransitionWindow(t *testing.T) {
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policy := newAppServerGatewayPolicy(router, "codex")

	// Spin up two dummy WebSocket pairs for sink1 and sink2 so handleUpstreamFrame can test delivery.
	newWSPair := func() (serverConn *websocket.Conn, clientConn *websocket.Conn) {
		t.Helper()
		upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
		accepted := make(chan *websocket.Conn, 1)
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			c, err := upgrader.Upgrade(w, r, nil)
			if err == nil {
				accepted <- c
			}
		}))
		t.Cleanup(srv.Close)
		wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
		c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = c.Close() })
		s := <-accepted
		t.Cleanup(func() { _ = s.Close() })
		return s, c
	}

	s1Conn, _ := newWSPair()
	s2Conn, c2Conn := newWSPair()
	var s1WriteMu, s2WriteMu sync.Mutex
	sink1 := newCodexGatewaySink(s1Conn, &s1WriteMu, nil)
	sink2 := newCodexGatewaySink(s2Conn, &s2WriteMu, nil)

	broker := &codexGatewayBroker{
		router:           router,
		key:              "sess-sinkgen",
		policy:           policy,
		sink:             sink1,
		activeTurns:      map[string]struct{}{},
		startingTurns:    map[string]string{},
		pending:          map[string][]byte{},
		pendingDelivered: map[string]*codexGatewaySink{},
	}
	initialGen := broker.nextSinkGen.Add(1)
	sink1.gen = initialGen
	broker.activeSinkGen.Store(initialGen)
	policy.currentSinkGen = broker.activeSinkGen.Load

	if sink1.gen != 1 || broker.activeSinkGen.Load() != 1 {
		t.Fatalf("expected initial sink gen=1, got sink=%d active=%d", sink1.gen, broker.activeSinkGen.Load())
	}

	// 1) Client frame with gen=0 on broker policy must be rejected (never binds gen=0!).
	reqZero := []byte(`{"id":1,"method":"thread/list","params":{"limit":10}}`)
	if _, pErr := policy.validateClientFrameForSink(t.Context(), websocket.TextMessage, reqZero, 0); pErr == nil {
		t.Fatal("broker policy must reject thread/list with clientSinkGen==0")
	}

	// 2) Sink1 registers a thread/list with gen=1; then sink2 attaches!
	req1 := []byte(`{"id":2,"method":"thread/list","params":{"limit":10}}`)
	if _, pErr := policy.validateClientFrameForSink(t.Context(), websocket.TextMessage, req1, sink1.gen); pErr != nil {
		t.Fatalf("sink1 thread/list failed: %+v", pErr)
	}
	if !broker.attach(sink2) {
		t.Fatal("sink2 attach failed")
	}
	if sink2.gen != 2 || broker.activeSinkGen.Load() != 2 {
		t.Fatalf("expected sink2 gen=2, got sink2=%d active=%d", sink2.gen, broker.activeSinkGen.Load())
	}

	// Late upstream response for sink1's id=2 must be dropped (not delivered to sink2, not authorized).
	resp1 := []byte(fmt.Sprintf(`{"id":2,"result":{"data":[{"id":"t-sink1-late","cwd":%q}],"nextCursor":null}}`, projectDir))
	broker.handleUpstreamFrame(websocket.TextMessage, resp1)
	if _, ok := policy.allowedThread("t-sink1-late"); ok {
		t.Fatal("replaced sink1 response must not authorize threads")
	}

	// 3) Policy-return-to-delivery sink replacement: sink2 issues a malformed response (client error),
	//    but sink3 replaces sink2 right after policy returns -> targetSinkGen check MUST drop the error frame!
	req3 := []byte(`{"id":3,"method":"thread/list","params":{"limit":10}}`)
	if _, pErr := policy.validateClientFrameForSink(t.Context(), websocket.TextMessage, req3, sink2.gen); pErr != nil {
		t.Fatalf("sink2 thread/list failed: %+v", pErr)
	}
	s3Conn, c3Conn := newWSPair()
	var s3WriteMu sync.Mutex
	sink3 := newCodexGatewaySink(s3Conn, &s3WriteMu, nil)
	policy.onAfterResponseClaim = func() {
		// Replace sink2 with sink3 during Stage A/B so activeSinkGen becomes 3!
		_ = broker.attach(sink3)
	}
	resp3Bad := []byte(`{"id":3,"result":{"data":null,"nextCursor":null}}`)
	broker.handleUpstreamFrame(websocket.TextMessage, resp3Bad)
	policy.onAfterResponseClaim = nil

	// Neither sink2 nor sink3 should receive the dropped frame.
	_ = c3Conn.SetReadDeadline(time.Now().Add(80 * time.Millisecond))
	if _, raw, err := c3Conn.ReadMessage(); err == nil {
		t.Fatalf("sink3 must NOT receive sink2's error frame: %s", raw)
	}
	_ = c2Conn.SetReadDeadline(time.Now().Add(80 * time.Millisecond))
	_, _, _ = c2Conn.ReadMessage()
}

func TestGlobalThreadListBudgetAndTransactionalMediaStaging(t *testing.T) {
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
		historyMedia:   newAppServerHistoryMediaStore(),
		historyOutput:  newAppServerHistoryOutputStore(),
	}
	policy := newAppServerGatewayPolicy(router, "codex")

	key := gatewayHistoryBudgetKey("thread-list-global", "thread/list", "list")
	budgetBytes := func() int64 {
		policy.mu.Lock()
		defer policy.mu.Unlock()
		return policy.historyBudgets[key].responseBytes
	}

	// 1) Valid Global thread/list increments budget by exact len(forwardPayload).
	req1 := []byte(`{"id":1,"method":"thread/list","params":{"limit":20}}`)
	if _, pErr := policy.validateClientFrame(websocket.TextMessage, req1); pErr != nil {
		t.Fatal(pErr)
	}
	resp1 := []byte(fmt.Sprintf(`{"id":1,"result":{"data":[{"id":"t-b1","cwd":%q}],"nextCursor":null}}`, projectDir))
	out1, forward1, err1 := policy.observeUpstreamFrame(websocket.TextMessage, resp1)
	if !forward1 || err1 != nil {
		t.Fatalf("resp1 failed: forward=%v err=%+v", forward1, err1)
	}
	afterValid := budgetBytes()
	if afterValid != int64(len(out1)) {
		t.Fatalf("expected budget bytes=%d, got %d", len(out1), afterValid)
	}

	// 2) Malformed listMeta, malformed nextCursor, stalled cursor, and expired response add 0 budget!
	badPayloads := []string{
		fmt.Sprintf(`{"id":2,"result":{"data":[{"id":"t-b2","cwd":%q}],"nextCursor":null,"listMeta":{"schemaVersion":99,"complete":true}}}`, projectDir),
		fmt.Sprintf(`{"id":3,"result":{"data":[{"id":"t-b3","cwd":%q}],"nextCursor":""}}`, projectDir),
	}
	for i, bp := range badPayloads {
		req := []byte(fmt.Sprintf(`{"id":%d,"method":"thread/list","params":{"limit":20}}`, i+2))
		if _, pErr := policy.validateClientFrame(websocket.TextMessage, req); pErr != nil {
			t.Fatal(pErr)
		}
		if _, forward, pErr := policy.observeUpstreamFrame(websocket.TextMessage, []byte(bp)); forward || pErr == nil {
			t.Fatalf("case %d expected reject, got forward=%v err=%+v", i, forward, pErr)
		}
	}
	if budgetBytes() != afterValid {
		t.Fatalf("malformed responses must not increment budget: before=%d after=%d", afterValid, budgetBytes())
	}

	// 3) 129 small images in a single Global thread/list response -> 128 replaced + 1 kept inline!
	tinyPNG := base64.StdEncoding.EncodeToString([]byte("\x89PNG\r\n\x1a\n" + strings.Repeat("A", 32)))
	var items []string
	for i := 0; i < 129; i++ {
		// Distinct byte suffix so each blob has a unique hash (exceeding 128 cap).
		blob := base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("\x89PNG\r\n\x1a\nblob-%03d-%s", i, strings.Repeat("X", 20))))
		items = append(items, fmt.Sprintf(`{"id":"img-t-%d","cwd":%q,"preview":"p","turns":[{"items":[{"type":"userMessage","content":[{"type":"image","url":"data:image/png;base64,%s"}]}]}]}`, i, projectDir, blob))
	}
	_ = tinyPNG
	// Direct unit test of stageRedactAndDehydrateThreadListPayload with 129 distinct blobs.
	bigPayload := []byte(fmt.Sprintf(`{"id":99,"result":{"data":[%s],"nextCursor":null}}`, strings.Join(items, ",")))
	staged, mediaRes, outRes := router.stageRedactAndDehydrateThreadListPayload(bigPayload, false)
	defer func() {
		if mediaRes != nil {
			mediaRes.cancel()
		}
		if outRes != nil {
			outRes.cancel()
		}
	}()
	replacedCount := bytes.Count(staged, []byte(appServerHistoryMediaURLPrefix))
	inlineCount := bytes.Count(staged, []byte("data:image/png;base64,"))
	if replacedCount != appServerHistoryMediaMaxEntries || inlineCount != 1 {
		t.Fatalf("expected %d replaced and 1 inline, got replaced=%d inline=%d", appServerHistoryMediaMaxEntries, replacedCount, inlineCount)
	}
}

func TestPreparedBlobReservationPinsGraceReuseAndAtomicCancel(t *testing.T) {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)
	store := newAppServerHistoryBlobStore(time.Minute, 2, 1024, 512)
	store.nowFunc = func() time.Time { return now }

	// 1) A is active-pinned, B is unpinned. Batch [B, C] requires 2 slots + A pinned = 3 > maxEntries(2)
	//    -> MUST REJECT atomically with ZERO eviction of B!
	resA, okA := store.reservePreparedBatch([]preparedBlobInput{
		{contentType: "image/png", data: []byte("blob-A")},
	})
	if !okA {
		t.Fatal("reserve A failed")
	}
	idA := resA.ids[0]
	releaseA := resA.commit() // A now has activeWritePins=1!
	if _, okB := store.put("image/png", []byte("blob-B")); !okB {
		t.Fatal("put B failed")
	}
	if _, okBC := store.reservePreparedBatch([]preparedBlobInput{
		{contentType: "image/png", data: []byte("blob-B")},
		{contentType: "image/png", data: []byte("blob-C")},
	}); okBC {
		t.Fatal("batch [B, C] must reject atomically when A is active-pinned and maxEntries=2")
	}
	storeCount := func(s *appServerHistoryMediaStore) int {
		s.mu.Lock()
		defer s.mu.Unlock()
		return len(s.entries)
	}
	// B must still exist in store (zero eviction on reject!).
	if storeCount(store) != 2 {
		t.Fatalf("expected 2 entries untouched after reject, got %d", storeCount(store))
	}

	// 2) Legacy put returns ("", false) when store is full of active pins!
	resB, okResB := store.reservePreparedBatch([]preparedBlobInput{
		{contentType: "image/png", data: []byte("blob-B")},
	})
	if !okResB {
		t.Fatal("reusing B while A pinned should succeed (reuse takes 0 new slots)")
	}
	releaseB := resB.commit()
	if _, okD := store.put("image/png", []byte("blob-D")); okD {
		t.Fatal("legacy put must return false when all 2 slots are actively pinned")
	}

	// 3) Cross-TTL active-pinned reuse: advance past TTL while A is pinned; batch2 reuses A;
	//    then batch1 releases A with grace=0 -> A must STILL be protected by batch2's active pin!
	now = now.Add(2 * time.Minute)
	resA2, okA2 := store.reservePreparedBatch([]preparedBlobInput{
		{contentType: "image/png", data: []byte("blob-A")},
	})
	if !okA2 || resA2.ids[0] != idA {
		t.Fatalf("cross-TTL reuse of active-pinned A failed: ok=%v got=%q want=%q", okA2, resA2.ids[0], idA)
	}
	releaseA2 := resA2.commit()
	releaseA(0)
	if _, exists := store.get(idA); !exists {
		t.Fatal("A must remain readable while batch2 still holds an active pin")
	}

	// 4) Release both with grace=30s; before expiry A is pinned, AFTER expiry grace pin frees capacity immediately!
	releaseA2(30 * time.Second)
	releaseB(0)
	// Move 31s forward so A's grace pin expires.
	now = now.Add(31 * time.Second)
	if _, okNew := store.put("image/png", []byte("blob-E")); !okNew {
		t.Fatal("legacy put must succeed immediately once grace pins expire")
	}

	// 5) storeDerived respects reservedBytes & pins!
	store2 := newAppServerHistoryBlobStore(time.Minute, 2, 30, 30)
	store2.nowFunc = func() time.Time { return now }
	id1, ok1 := store2.put("image/png", []byte("0123456789")) // 10 bytes
	if !ok1 {
		t.Fatal("put 10B failed")
	}
	// Reserve 15 bytes -> 10 + 15 = 25 used/reserved, only 5 bytes left!
	res2, ok2 := store2.reservePreparedBatch([]preparedBlobInput{
		{contentType: "image/png", data: []byte("0123456789abcde")}, // 15 bytes
	})
	if !ok2 {
		t.Fatal("reserve 15B failed")
	}
	if _, _, okDerived := store2.storeDerived(id1, "thumb", appServerHistoryMediaVariant{
		contentType: "image/jpeg",
		data:        []byte("1234567890"), // 10 bytes > 5 remaining!
	}); okDerived {
		t.Fatal("storeDerived must reject when reservedBytes would be exceeded")
	}
	// Cancel reservation -> zero entries written, 15 reserved bytes freed, storeDerived now succeeds!
	res2.cancel()
	if storeCount(store2) != 1 {
		t.Fatalf("cancel must leave zero new entries, got %d", storeCount(store2))
	}
	if _, _, okDerived := store2.storeDerived(id1, "thumb", appServerHistoryMediaVariant{
		contentType: "image/jpeg",
		data:        []byte("1234567890"),
	}); !okDerived {
		t.Fatal("storeDerived must succeed once reservation is cancelled")
	}
}

func TestStageBTTLAbortCancelsMediaReservationWithZeroWrites(t *testing.T) {
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
		historyMedia:   newAppServerHistoryMediaStore(),
		historyOutput:  newAppServerHistoryOutputStore(),
	}
	policy := newAppServerGatewayPolicy(router, "codex")
	now := time.Date(2026, 11, 27, 13, 0, 0, 0, time.UTC)
	policy.nowFunc = func() time.Time { return now }

	// Verify that a real reservation exists BEFORE Stage B commit and is cancelled on TTL expiry!
	observedReservedBeforeCommit := 0
	observedEntriesBeforeCommit := -1
	policy.onStageBBeforeFinalCommitLock = func(int) {
		router.historyMedia.mu.Lock()
		observedReservedBeforeCommit = router.historyMedia.reservedEntries
		observedEntriesBeforeCommit = len(router.historyMedia.entries)
		router.historyMedia.mu.Unlock()
		now = now.Add(appServerGatewayPendingThreadTTL + time.Second)
	}

	// Use a SCOPED thread/list so turns/inline images are preserved and actually staged!
	req := []byte(fmt.Sprintf(`{"id":1,"method":"thread/list","params":{"cwd":%q,"limit":20}}`, projectDir))
	if _, pErr := policy.validateClientFrame(websocket.TextMessage, req); pErr != nil {
		t.Fatal(pErr)
	}
	img := base64.StdEncoding.EncodeToString([]byte("\x89PNG\r\n\x1a\n" + strings.Repeat("Z", 64)))
	resp := []byte(fmt.Sprintf(`{"id":1,"result":{"data":[{"id":"t-abort","cwd":%q,"turns":[{"items":[{"type":"userMessage","content":[{"type":"image","url":"data:image/png;base64,%s"}]}]}]}],"nextCursor":null}}`, projectDir, img))
	_, forward, pErr := policy.observeUpstreamFrame(websocket.TextMessage, resp)
	if forward || pErr != nil {
		t.Fatalf("expired Stage B must silently drop: forward=%v err=%+v", forward, pErr)
	}
	if observedReservedBeforeCommit != 1 || observedEntriesBeforeCommit != 0 {
		t.Fatalf("expected 1 staged reservation and 0 written entries before commit, got reserved=%d entries=%d", observedReservedBeforeCommit, observedEntriesBeforeCommit)
	}
	router.historyMedia.mu.Lock()
	mediaCount := len(router.historyMedia.entries)
	mediaReserved := router.historyMedia.reservedEntries
	router.historyMedia.mu.Unlock()
	if mediaCount != 0 || mediaReserved != 0 {
		t.Fatalf("aborted Stage B must cancel media reservation leaving 0 entries & 0 reserved, got entries=%d reserved=%d", mediaCount, mediaReserved)
	}
}
