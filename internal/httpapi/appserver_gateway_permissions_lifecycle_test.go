package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
	"github.com/gorilla/websocket"
)

func TestExactPathWithinCaseSensitivityAndUNC(t *testing.T) {
	if !exactPathWithin("/tmp/foo", "/tmp/foo") {
		t.Fatal("exact equal path must match")
	}
	if !exactPathWithin("/tmp/foo", "/tmp/foo/sub/a") {
		t.Fatal("child path must match")
	}
	if exactPathWithin("/tmp/foo", "/tmp/Foo") {
		t.Fatal("different case segment must NOT match")
	}
	if exactPathWithin("/tmp/foo", "/tmp/Foo/gone") {
		t.Fatal("different case ancestor must NOT match")
	}
	if exactPathWithin("/tmp/foo", "/tmp/foobar") {
		t.Fatal("prefix sibling must NOT match")
	}
	if runtime.GOOS != "windows" {
		if exactPathWithin(`/tmp/a\b`, `/tmp/a/b`) {
			t.Fatal("POSIX literal backslash must NOT be treated as path separator")
		}
		if !exactPathWithin(`/tmp/a\b`, `/tmp/a\b/child`) {
			t.Fatal("POSIX literal backslash child must match")
		}
	}
	if exactPathWithin(`\\HOST\share`, `\\host\share\sub`) {
		t.Fatal("UNC host case mismatch must NOT match")
	}
	if !exactPathWithin(`\\HOST\share`, `\\HOST\share\sub`) {
		t.Fatal("UNC exact case child must match")
	}
}

func TestWorktreeRegistryDeleteFailureImmediatelyRevokesAuthAndFilesReadOnly(t *testing.T) {
	worktreesRoot := t.TempDir()
	repoDir := t.TempDir()
	checkoutDir := filepath.Join(t.TempDir(), "wt-checkout")
	siblingCaseDir := filepath.Join(filepath.Dir(checkoutDir), "WT-checkout")
	subDir := filepath.Join(checkoutDir, "pkg")
	if err := os.MkdirAll(subDir, 0o755); err != nil {
		t.Fatal(err)
	}
	realCheckout := canonicalPathBestEffort(checkoutDir)
	realSub := canonicalPathBestEffort(subDir)

	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "repo", Name: "Repo", Path: repoDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	var failRegistryRemove atomic.Bool
	router := &Router{
		cfg:            config.Config{WorktreesRoot: worktreesRoot},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
		managedWorktreeRegistryRemove: func(file string) error {
			if failRegistryRemove.Load() {
				return errors.New("simulated registry unlink failure")
			}
			return os.Remove(file)
		},
	}

	wt := managedWorktree{
		Path:         realCheckout,
		CheckoutPath: realCheckout,
		RootProject:  projects.Project{ID: "repo", Name: "Repo", Path: repoDir},
		Branch:       "feat/test",
		LastUsedAt:   time.Now().UTC(),
	}
	if err := router.registerManagedWorktree(wt); err != nil {
		t.Fatal(err)
	}

	// Verify positive auth is strictly bound to .Path (does not authorize sibling when Path is subdir).
	wtSubOnly := managedWorktree{
		Path:         realSub,
		CheckoutPath: realCheckout,
		RootProject:  projects.Project{ID: "repo", Name: "Repo", Path: repoDir},
		Branch:       "feat/sub",
		LastUsedAt:   time.Now().UTC(),
	}
	if err := router.registerManagedWorktree(wtSubOnly); err != nil {
		t.Fatal(err)
	}
	regFile, err := router.managedWorktreeRegistryFile(realCheckout)
	if err != nil {
		t.Fatal(err)
	}

	// Unregister realCheckout while registry file deletion fails via test hook (sandbox-safe!).
	failRegistryRemove.Store(true)
	router.managedWorktreeCleanupMu.Lock()
	removeErr := router.unregisterManagedWorktreeLocked(wt, realCheckout, "", "")
	router.managedWorktreeCleanupMu.Unlock()
	if removeErr == nil {
		t.Fatal("expected simulated registry removal error")
	}

	// Immediately revoked across exact path, subdir, generic scope, disk fallback, and Stage A!
	if _, ok := router.managedWorktreeForPath(realCheckout); ok {
		t.Fatal("revoked checkout must not be authorized by managedWorktreeForPath")
	}
	if _, ok := router.managedWorktreeForPath(realSub); ok {
		t.Fatal("subdir of revoked checkout must not be authorized via revoked checkout")
	}
	if _, ok := router.managedWorktreeForPathFromRegistry(realCheckout); ok {
		t.Fatal("revoked checkout must not be authorized via disk fallback")
	}
	if _, ok := router.gatewayScopeForPath(realCheckout); ok {
		t.Fatal("revoked checkout must not pass gatewayScopeForPath")
	}
	if _, _, _, _, ok := router.gatewayReadOnlyScopeForThreadListStageA(realCheckout, "", false); ok {
		t.Fatal("revoked checkout must not pass Stage A")
	}
	if router.hasManagedWorktreeForLexicalPath(realCheckout) {
		t.Fatal("files.go lexical check must treat revoked checkout as unauthorized")
	}
	// Case-exact revocation must NOT revoke distinct case-sensitive sibling!
	if router.isManagedWorktreeRevokedPath(siblingCaseDir) {
		t.Fatalf("case-exact revocation must NOT revoke distinct case sibling %s", siblingCaseDir)
	}

	// Allow removal and verify pruneMissingManagedWorktrees cleans pending registry delete.
	failRegistryRemove.Store(false)
	router.pruneMissingManagedWorktrees()
	if _, statErr := os.Stat(regFile); !os.IsNotExist(statErr) {
		t.Fatalf("expected pending registry file %s to be cleaned up, statErr=%v", regFile, statErr)
	}
}

func TestLegacyWorktreeWithoutCheckoutPathBlocksDeleteEvenWhenMigrationWriteFails(t *testing.T) {
	worktreesRoot := t.TempDir()
	repoDir := t.TempDir()
	checkoutDir := filepath.Join(t.TempDir(), "legacy-wt")
	subDir := filepath.Join(checkoutDir, "sub")
	if err := os.MkdirAll(subDir, 0o755); err != nil {
		t.Fatal(err)
	}
	realCheckout := canonicalPathBestEffort(checkoutDir)
	realSub := canonicalPathBestEffort(subDir)

	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "repo", Name: "Repo", Path: repoDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:            config.Config{WorktreesRoot: worktreesRoot},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}

	// Write a legacy registry record WITHOUT checkout_path directly to disk (cold start!).
	legacyWT := managedWorktree{
		Path:        realSub,
		RootProject: projects.Project{ID: "repo", Name: "Repo", Path: repoDir},
		Branch:      "feat/legacy",
		LastUsedAt:  time.Now().UTC(),
	}
	regFile, err := router.managedWorktreeRegistryFile(realSub)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(regFile), 0o700); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(legacyWT)
	if err := os.WriteFile(regFile, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	// Verify Stage A reads legacy record WITHOUT writing to disk (make isolated temp regDir read-only!).
	regDir := filepath.Dir(regFile)
	if err := os.Chmod(regDir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(regDir, 0o700) })

	// 1) files.go lexical check must NOT attempt migration write and must return true for realSub.
	if !router.hasManagedWorktreeForLexicalPath(realSub) {
		t.Fatal("legacy worktree must be visible to read-only lexical check")
	}

	// 2) Stage A + Stage B authorizes thread under legacy worktree.
	policy := newAppServerGatewayPolicy(router, "codex")
	id := json.RawMessage(`50`)
	if err := policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{
		method:          "thread/list",
		globalDiscovery: true,
	}); err != nil {
		t.Fatal(err)
	}
	resp := []byte(fmt.Sprintf(`{"id":50,"result":{"data":[{"id":"t-legacy","cwd":%q}],"nextCursor":null}}`, realSub))
	_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, resp)
	if !forward || policyErr != nil {
		t.Fatalf("legacy worktree thread/list failed: forward=%v err=%+v", forward, policyErr)
	}
	if _, ok := policy.allowedThread("t-legacy"); !ok {
		t.Fatal("expected t-legacy to be authorized")
	}

	// 3) managedWorktreeHasRunningSessionForCheckout MUST block deletion for realCheckout even though
	//    the legacy record had empty CheckoutPath and migration write failed!
	if !router.managedWorktreeHasRunningSessionForCheckout(legacyWT, realCheckout) {
		t.Fatal("delete MUST be blocked when running session exists under legacy worktree checkout")
	}
	if !router.managedWorktreeHasRunningSessionForCheckout(legacyWT, "") {
		t.Fatal("empty checkoutPath must fail-closed (return true)")
	}
}

func TestStageAMidProbeDeletionTriggersBoundedReprobeAndPreservesSibling(t *testing.T) {
	worktreesRoot := t.TempDir()
	repoDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "repo", Name: "Repo", Path: repoDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:            config.Config{WorktreesRoot: worktreesRoot},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	checkoutsRoot, err := router.managedWorktreeCheckoutsRoot()
	if err != nil {
		t.Fatal(err)
	}
	router.cfg.BrowseRoots = []string{checkoutsRoot}
	wtGone := filepath.Join(checkoutsRoot, "foo")
	wtKeep := filepath.Join(checkoutsRoot, "Foo-keep")
	if err := os.MkdirAll(wtGone, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(wtKeep, 0o755); err != nil {
		t.Fatal(err)
	}
	realGone := canonicalPathBestEffort(wtGone)
	realKeep := canonicalPathBestEffort(wtKeep)
	goneWT := managedWorktree{
		Path:         realGone,
		CheckoutPath: realGone,
		RootProject:  projects.Project{ID: "repo", Name: "Repo", Path: repoDir},
		Branch:       "feat/gone",
		LastUsedAt:   time.Now().UTC(),
	}
	keepWT := managedWorktree{
		Path:         realKeep,
		CheckoutPath: realKeep,
		RootProject:  projects.Project{ID: "repo", Name: "Repo", Path: repoDir},
		Branch:       "feat/keep",
		LastUsedAt:   time.Now().UTC(),
	}
	if err := router.registerManagedWorktree(goneWT); err != nil {
		t.Fatal(err)
	}
	if err := router.registerManagedWorktree(keepWT); err != nil {
		t.Fatal(err)
	}

	policy := newAppServerGatewayPolicy(router, "codex")
	var hookCalls atomic.Int32
	policy.onStageAAfterPathProbe = func(attempt int) {
		if attempt == 0 && hookCalls.Add(1) == 1 {
			// Delete wtGone right after its Stage A probe succeeded!
			_ = os.RemoveAll(realGone)
			router.managedWorktreeCleanupMu.Lock()
			_ = router.unregisterManagedWorktreeLocked(goneWT, realGone, "", "")
			router.managedWorktreeCleanupMu.Unlock()
		}
	}

	id := json.RawMessage(`60`)
	if err := policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{
		method:          "thread/list",
		globalDiscovery: true,
	}); err != nil {
		t.Fatal(err)
	}
	resp := []byte(fmt.Sprintf(`{"id":60,"result":{"data":[{"id":"t-gone","cwd":%q},{"id":"t-keep","cwd":%q}],"nextCursor":null}}`, realGone, realKeep))
	out, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, resp)
	if !forward || policyErr != nil {
		t.Fatalf("expected reprobe to succeed for surviving sibling, got forward=%v err=%+v", forward, policyErr)
	}
	if bytes.Contains(out, []byte("t-gone")) {
		t.Fatalf("deleted worktree candidate must be dropped (not missing:true fallback!): %s", out)
	}
	if !bytes.Contains(out, []byte("t-keep")) {
		t.Fatalf("surviving sibling must be preserved: %s", out)
	}
	if _, ok := policy.allowedThread("t-gone"); ok {
		t.Fatal("deleted candidate must NOT be authorized")
	}
	if _, ok := policy.allowedThread("t-keep"); !ok {
		t.Fatal("surviving sibling must be authorized")
	}

	// Continuous churn exhausting 2 reprobes -> fail-closed silent drop!
	policy2 := newAppServerGatewayPolicy(router, "codex")
	policy2.onStageAAfterPathProbe = func(attempt int) {
		router.managedWorktreeLifecycleEpoch.Add(1)
	}
	id2 := json.RawMessage(`61`)
	_ = policy2.rememberPendingThreadRequest(&id2, appServerGatewayPendingThreadRequest{
		method:          "thread/list",
		globalDiscovery: true,
	})
	resp2 := []byte(fmt.Sprintf(`{"id":61,"result":{"data":[{"id":"t-storm","cwd":%q}],"nextCursor":null}}`, realKeep))
	_, forward2, err2 := policy2.observeUpstreamFrame(websocket.TextMessage, resp2)
	if forward2 || err2 != nil {
		t.Fatalf("exhausting 2 reprobes must silently drop fail-closed, got forward=%v err=%+v", forward2, err2)
	}
	if _, ok := policy2.allowedThread("t-storm"); ok {
		t.Fatal("dropped storm page must not authorize threads")
	}
}

func TestPermissionsSamePageOrderCrossPageRestoreAndDualConnectionCausality(t *testing.T) {
	projectDir := t.TempDir()
	missingSub := filepath.Join(projectDir, "missing-sub")
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}

	// 1) C2-5a/5b/5c: Both orders of (missing + writable) and (missing + explicit-deny) in same page produce identical result.
	for _, order := range []string{"missing_first", "writable_first"} {
		router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
		policy := newAppServerGatewayPolicy(router, "claude")
		id := json.RawMessage(`70`)
		_ = policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
		var items string
		if order == "missing_first" {
			items = fmt.Sprintf(`[{"id":"dup-1","cwd":%q,"canAcceptDirectInput":false},{"id":"dup-1","cwd":%q,"canAcceptDirectInput":true}]`, missingSub, projectDir)
		} else {
			items = fmt.Sprintf(`[{"id":"dup-1","cwd":%q,"canAcceptDirectInput":true},{"id":"dup-1","cwd":%q,"canAcceptDirectInput":false}]`, projectDir, missingSub)
		}
		resp := []byte(fmt.Sprintf(`{"id":70,"result":{"data":%s,"nextCursor":null}}`, items))
		_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, resp)
		if !forward || policyErr != nil {
			t.Fatalf("%s failed: forward=%v err=%+v", order, forward, policyErr)
		}
		got, ok := policy.allowedThread("dup-1")
		if !ok || !got.cwdMissing || !got.readOnly || got.canAcceptDirectInput {
			t.Fatalf("%s expected monotonic readOnly+cwdMissing, got %+v", order, got)
		}
	}

	// 2) Missing + explicit-deny (with claudeOwner) stays denied after path restore when next page omits canAcceptDirectInput.
	router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policy := newAppServerGatewayPolicy(router, "claude")
	id1 := json.RawMessage(`71`)
	_ = policy.rememberPendingThreadRequest(&id1, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	resp1 := []byte(fmt.Sprintf(`{"id":71,"result":{"data":[{"id":"t-owner-missing","cwd":%q,"canAcceptDirectInput":false,"claudeOwner":{"pid":99}}],"nextCursor":null}}`, missingSub))
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, resp1); !forward || err != nil {
		t.Fatalf("step 1 failed: forward=%v err=%+v", forward, err)
	}
	// Restore directory on disk, return list row omitting canAcceptDirectInput.
	if err := os.MkdirAll(missingSub, 0o755); err != nil {
		t.Fatal(err)
	}
	id2 := json.RawMessage(`72`)
	_ = policy.rememberPendingThreadRequest(&id2, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	resp2 := []byte(fmt.Sprintf(`{"id":72,"result":{"data":[{"id":"t-owner-missing","cwd":%q}],"nextCursor":null}}`, missingSub))
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, resp2); !forward || err != nil {
		t.Fatalf("step 2 failed: forward=%v err=%+v", forward, err)
	}
	gotOwner, _ := policy.allowedThread("t-owner-missing")
	if gotOwner.cwdMissing || gotOwner.readOnly || !gotOwner.explicitDirectInputDenied || gotOwner.canAcceptDirectInput {
		t.Fatalf("claudeOwner explicit deny MUST survive restore when field omitted: %+v", gotOwner)
	}
	// thread/read omitting canAcceptDirectInput must write back canAcceptDirectInput=false WITHOUT mislabeling mimiRemote.readOnly=true!
	readID := json.RawMessage(`73`)
	_ = policy.rememberPendingThreadRequest(&readID, appServerGatewayPendingThreadRequest{method: "thread/read", threadID: "t-owner-missing"})
	readResp := []byte(fmt.Sprintf(`{"id":73,"result":{"thread":{"id":"t-owner-missing","cwd":%q}}}`, missingSub))
	readOut, forwardRead, errRead := policy.observeUpstreamFrame(websocket.TextMessage, readResp)
	if !forwardRead || errRead != nil {
		t.Fatalf("thread/read failed: forward=%v err=%+v", forwardRead, errRead)
	}
	var readParsed struct {
		Result struct {
			Thread map[string]any `json:"thread"`
		} `json:"result"`
	}
	_ = json.Unmarshal(readOut, &readParsed)
	if readParsed.Result.Thread["canAcceptDirectInput"] != false {
		t.Fatalf("expected canAcceptDirectInput=false writeback: %s", readOut)
	}
	if mimi, ok := readParsed.Result.Thread["mimiRemote"].(map[string]any); ok && mimi["readOnly"] == true {
		t.Fatalf("explicitDirectInputDenied without readOnly must NOT mislabel mimiRemote.readOnly=true: %s", readOut)
	}

	// 3) Agy same-frame cwdMissing:true without claudeOwner recovers even if dir already restored before Stage A!
	agyPolicy := newAppServerGatewayPolicy(router, appServerRuntimeAgyID)
	agyID := json.RawMessage(`74`)
	_ = agyPolicy.rememberPendingThreadRequest(&agyID, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	agyResp := []byte(fmt.Sprintf(`{"id":74,"result":{"data":[{"id":"agy-recovered","cwd":%q,"cwdMissing":true,"canAcceptDirectInput":false}],"nextCursor":null}}`, missingSub))
	if _, forward, err := agyPolicy.observeUpstreamFrame(websocket.TextMessage, agyResp); !forward || err != nil {
		t.Fatalf("agy step failed: forward=%v err=%+v", forward, err)
	}
	gotAgy, _ := agyPolicy.allowedThread("agy-recovered")
	if gotAgy.explicitDirectInputDenied {
		t.Fatalf("Agy same-frame cwdMissing:true without claudeOwner must NOT solidify explicitDirectInputDenied: %+v", gotAgy)
	}

	// 4) Dual-connection causal ordering:
	//    connA deny v1 -> connB allow v2 (via thread/read) -> connA omitted list stays allow!
	//    Reverse: connA allow v1 -> connB deny v2 -> connA write rejected!
	router2 := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	connA := newAppServerGatewayPolicy(router2, "claude")
	connB := newAppServerGatewayPolicy(router2, "claude")

	// connA denies v1
	connA.allowThread(appServerGatewayAllowedThread{
		id: "causal-1", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: false, rawDirectInput: rawDirectInputDeny,
	})
	// connB allows v2
	connB.allowThread(appServerGatewayAllowedThread{
		id: "causal-1", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: true, rawDirectInput: rawDirectInputAllow,
	})
	// connA sees omitted list row -> must observe v2 allow, NOT regress to v1 deny!
	idCA := json.RawMessage(`80`)
	_ = connA.rememberPendingThreadRequest(&idCA, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	if _, forward, err := connA.observeUpstreamFrame(websocket.TextMessage, []byte(fmt.Sprintf(`{"id":80,"result":{"data":[{"id":"causal-1","cwd":%q}],"nextCursor":null}}`, projectDir))); !forward || err != nil {
		t.Fatalf("connA omitted list failed: forward=%v err=%+v", forward, err)
	}
	if st, _ := connA.allowedThread("causal-1"); st.explicitDirectInputDenied || !st.canAcceptDirectInput {
		t.Fatalf("connA should keep connB's newer v2 allow: %+v", st)
	}

	// Reverse: connB denies v3 -> connA write must be rejected!
	connB.allowThread(appServerGatewayAllowedThread{
		id: "causal-1", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: false, rawDirectInput: rawDirectInputDeny,
	})
	if st, _ := connA.allowedThread("causal-1"); !st.explicitDirectInputDenied || st.canAcceptDirectInput {
		t.Fatalf("connA must see connB's newer v3 deny: %+v", st)
	}
	turnReq := []byte(fmt.Sprintf(`{"id":81,"method":"turn/start","params":{"threadId":"causal-1","cwd":%q,"input":[{"type":"text","text":"hi"}]}}`, projectDir))
	if _, pErr := connA.validateClientFrame(websocket.TextMessage, turnReq); pErr == nil {
		t.Fatal("connA turn/start must be rejected after connB's newer deny")
	}
}

func TestRestrictionFloorEvictionEpochAndPushSeededOnlyGuards(t *testing.T) {
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	oldCap := appServerGatewayRestrictionFloorMax
	appServerGatewayRestrictionFloorMax = 2
	defer func() { appServerGatewayRestrictionFloorMax = oldCap }()

	router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policy := newAppServerGatewayPolicy(router, "claude")

	// Seed pushSeededOnly thread via restoreGatewayThreadAuthorization.
	router.restoreGatewayThreadAuthorization(pushbridge.LocateRecord{
		Runtime:  "claude",
		ThreadID: "t-push",
		CWD:      projectDir,
	})
	turnReq := []byte(fmt.Sprintf(`{"id":90,"method":"turn/start","params":{"threadId":"t-push","cwd":%q,"input":[{"type":"text","text":"hi"}]}}`, projectDir))
	if _, pErr := policy.validateClientFrame(websocket.TextMessage, turnReq); pErr == nil {
		t.Fatal("pushSeededOnly thread must reject turn/start")
	}
	takeoverReq := []byte(fmt.Sprintf(`{"id":91,"method":"thread/takeover","params":{"threadId":"t-push","cwd":%q}}`, projectDir))
	if _, pErr := policy.validateClientFrame(websocket.TextMessage, takeoverReq); pErr == nil {
		t.Fatal("pushSeededOnly thread must reject thread/takeover")
	}

	// Put an unbacked stale entry into policy.allowedThreads and another backed only by pushSeededOnly.
	policy.mu.Lock()
	policy.allowedThreads["t-stale-conn"] = appServerGatewayAllowedThread{
		id: "t-stale-conn", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: true,
	}
	policy.allowedThreads["t-push"] = appServerGatewayAllowedThread{
		id: "t-push", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: true,
	}
	policy.mu.Unlock()

	// Overflow restriction floor (cap=2) by writing 3 restricted threads -> increments gatewayRestrictionEvictionEpoch!
	for i := 0; i < 3; i++ {
		router.allowGatewayThread(appServerGatewayAllowedThread{
			id: fmt.Sprintf("restricted-%d", i), runtimeID: "claude", cwd: projectDir, scopeID: "demo",
			directInputKnown: true, canAcceptDirectInput: false, rawDirectInput: rawDirectInputDeny,
		})
	}

	// Both unbacked conn entry and pushSeededOnly-backed conn entry must be invalidated on epoch sync!
	if _, ok := policy.allowedThread("t-stale-conn"); ok {
		t.Fatal("unbacked conn cache must be invalidated after restriction floor eviction epoch bump")
	}
	if got, ok := policy.allowedThread("t-push"); ok && !got.pushSeededOnly {
		t.Fatalf("pushSeededOnly must not endorse conn write cache after eviction epoch: %+v", got)
	}

	// Verify neither thread/list nor thread/resume clears pushSeededOnly!
	listID := json.RawMessage(`911`)
	_ = policy.rememberPendingThreadRequest(&listID, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	listResp := []byte(fmt.Sprintf(`{"id":911,"result":{"data":[{"id":"t-push","cwd":%q}],"nextCursor":null}}`, projectDir))
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, listResp); !forward || err != nil {
		t.Fatalf("list on pushSeededOnly failed: forward=%v err=%+v", forward, err)
	}
	if got, ok := policy.allowedThread("t-push"); !ok || !got.pushSeededOnly {
		t.Fatalf("thread/list must NOT clear pushSeededOnly: ok=%v %+v", ok, got)
	}
	resumeID := json.RawMessage(`912`)
	_ = policy.rememberPendingThreadRequest(&resumeID, appServerGatewayPendingThreadRequest{method: "thread/resume", threadID: "t-push", cwd: projectDir, scopeID: "demo"})
	resumeResp := []byte(fmt.Sprintf(`{"id":912,"result":{"thread":{"id":"t-push","cwd":%q,"canAcceptDirectInput":true}}}`, projectDir))
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, resumeResp); !forward || err != nil {
		t.Fatalf("resume on pushSeededOnly failed: forward=%v err=%+v", forward, err)
	}
	if got, ok := policy.allowedThread("t-push"); !ok || !got.pushSeededOnly {
		t.Fatalf("thread/resume must NOT clear pushSeededOnly: ok=%v %+v", ok, got)
	}

	// thread/read recovers t-push cleanly once upstream confirms writable!
	readID := json.RawMessage(`92`)
	_ = policy.rememberPendingThreadRequest(&readID, appServerGatewayPendingThreadRequest{method: "thread/read", threadID: "t-push"})
	readResp := []byte(fmt.Sprintf(`{"id":92,"result":{"thread":{"id":"t-push","cwd":%q,"canAcceptDirectInput":true}}}`, projectDir))
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, readResp); !forward || err != nil {
		t.Fatalf("thread/read recovery failed: forward=%v err=%+v", forward, err)
	}
	if got, ok := policy.allowedThread("t-push"); !ok || got.pushSeededOnly || !got.canAcceptDirectInput {
		t.Fatalf("expected t-push to recover after thread/read, got ok=%v %+v", ok, got)
	}
}

func TestStageBPermissionBaselineDriftRetriesAndExhaustionDrops(t *testing.T) {
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}

	// 1) Single drift during Stage B triggers re-merge and commits the tightened permission!
	policy := newAppServerGatewayPolicy(router, "claude")
	var drifted atomic.Bool
	policy.onStageBBeforeFinalCommitLock = func(int) {
		if drifted.CompareAndSwap(false, true) {
			router.allowGatewayThread(appServerGatewayAllowedThread{
				id: "t-drift", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
				readOnly: true, readOnlySubagent: true, readOnlyPermanent: true,
			})
		}
	}
	id1 := json.RawMessage(`100`)
	_ = policy.rememberPendingThreadRequest(&id1, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	resp1 := []byte(fmt.Sprintf(`{"id":100,"result":{"data":[{"id":"t-drift","cwd":%q,"canAcceptDirectInput":true}],"nextCursor":null}}`, projectDir))
	out1, forward1, err1 := policy.observeUpstreamFrame(websocket.TextMessage, resp1)
	if !forward1 || err1 != nil {
		t.Fatalf("single drift should re-merge and forward: forward=%v err=%+v", forward1, err1)
	}
	if !bytes.Contains(out1, []byte(`"readOnly":true`)) || !bytes.Contains(out1, []byte(`"canAcceptDirectInput":false`)) {
		t.Fatalf("re-merged response must reflect tightened readOnly: %s", out1)
	}

	// 2) Continuous baseline drift exhausting 4 retries silently drops!
	policy2 := newAppServerGatewayPolicy(router, "claude")
	var step atomic.Int32
	policy2.onStageBBeforeFinalCommitLock = func(int) {
		n := step.Add(1)
		raw := rawDirectInputDeny
		if n%2 == 0 {
			raw = rawDirectInputAllow
		}
		router.allowGatewayThread(appServerGatewayAllowedThread{
			id: "t-drift-loop", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
			directInputKnown: true, canAcceptDirectInput: raw == rawDirectInputAllow, rawDirectInput: raw,
		})
	}
	id2 := json.RawMessage(`101`)
	_ = policy2.rememberPendingThreadRequest(&id2, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	resp2 := []byte(fmt.Sprintf(`{"id":101,"result":{"data":[{"id":"t-drift-loop","cwd":%q,"canAcceptDirectInput":true}],"nextCursor":null}}`, projectDir))
	_, forward2, err2 := policy2.observeUpstreamFrame(websocket.TextMessage, resp2)
	if forward2 || err2 != nil {
		t.Fatalf("exhausting 4 Stage B permission retries must silently drop: forward=%v err=%+v", forward2, err2)
	}
}

func TestOwnershipReleaseNotificationFreshListAndEvictedFloorAllow(t *testing.T) {
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}

	// 1) Claude desktop owner exits -> thread/status/changed notification re-enables sending on existing connection,
	//    AND fresh thread/list with explicit canAcceptDirectInput=true also re-enables sending (preserving structural readOnly!).
	router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policy := newAppServerGatewayPolicy(router, "claude")

	id1 := json.RawMessage(`201`)
	_ = policy.rememberPendingThreadRequest(&id1, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	heldResp := []byte(fmt.Sprintf(`{"id":201,"result":{"data":[{"id":"t-held-notif","cwd":%q,"canAcceptDirectInput":false,"claudeOwner":{"pid":11}},{"id":"t-held-list","cwd":%q,"canAcceptDirectInput":false,"claudeOwner":{"pid":22}},{"id":"t-sub-ro","parentThreadId":"p-1","cwd":%q,"canAcceptDirectInput":false,"claudeOwner":{"pid":33}}],"nextCursor":null}}`, projectDir, projectDir, projectDir))
	if _, forward, pErr := policy.observeUpstreamFrame(websocket.TextMessage, heldResp); !forward || pErr != nil {
		t.Fatalf("held list failed: forward=%v err=%+v", forward, pErr)
	}

	// Owner release notification for t-held-notif & t-sub-ro.
	releaseNotif := []byte(`{"method":"thread/status/changed","params":{"threadId":"t-held-notif","status":{"type":"idle"},"canAcceptDirectInput":true,"claudeOwner":null}}`)
	if _, forward, pErr := policy.observeUpstreamFrame(websocket.TextMessage, releaseNotif); !forward || pErr != nil {
		t.Fatalf("release notif failed: forward=%v err=%+v", forward, pErr)
	}
	releaseSubNotif := []byte(`{"method":"thread/status/changed","params":{"threadId":"t-sub-ro","status":{"type":"idle"},"canAcceptDirectInput":true,"claudeOwner":null}}`)
	if _, forward, pErr := policy.observeUpstreamFrame(websocket.TextMessage, releaseSubNotif); !forward || pErr != nil {
		t.Fatalf("release sub notif failed: forward=%v err=%+v", forward, pErr)
	}
	if st, ok := policy.allowedThread("t-held-notif"); !ok || st.explicitDirectInputDenied || !st.canAcceptDirectInput {
		t.Fatalf("t-held-notif should be writable after owner release notification: ok=%v %+v", ok, st)
	}
	if st, ok := policy.allowedThread("t-sub-ro"); !ok || !st.readOnly || st.canAcceptDirectInput {
		t.Fatalf("structural readOnly subagent must stay readOnly even after owner release: ok=%v %+v", ok, st)
	}

	// Fresh thread/list explicitly reporting canAcceptDirectInput=true for t-held-list (no claudeOwner).
	id2 := json.RawMessage(`202`)
	_ = policy.rememberPendingThreadRequest(&id2, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	freshResp := []byte(fmt.Sprintf(`{"id":202,"result":{"data":[{"id":"t-held-list","cwd":%q,"canAcceptDirectInput":true}],"nextCursor":null}}`, projectDir))
	if _, forward, pErr := policy.observeUpstreamFrame(websocket.TextMessage, freshResp); !forward || pErr != nil {
		t.Fatalf("fresh list failed: forward=%v err=%+v", forward, pErr)
	}
	if st, ok := policy.allowedThread("t-held-list"); !ok || st.explicitDirectInputDenied || !st.canAcceptDirectInput {
		t.Fatalf("t-held-list should become writable after fresh explicit allow list: ok=%v %+v", ok, st)
	}

	// 2) Evicted main cache entry with newer explicit allow in restriction floor:
	//    connA has deny v1, connB writes allow v2, main entry evicted -> connA MUST see allow v2 (NOT unknown false)!
	router2 := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	connA := newAppServerGatewayPolicy(router2, "claude")
	connB := newAppServerGatewayPolicy(router2, "claude")
	connA.allowThread(appServerGatewayAllowedThread{
		id: "t-floor-allow", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: false, rawDirectInput: rawDirectInputDeny,
	})
	connB.allowThread(appServerGatewayAllowedThread{
		id: "t-floor-allow", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: true, rawDirectInput: rawDirectInputAllow,
	})
	// Evict main gatewayThreads entry while keeping gatewayThreadRestrictions floor!
	router2.gatewayThreadsMu.Lock()
	delete(router2.gatewayThreads, gatewayThreadCacheKey("claude", "t-floor-allow"))
	router2.gatewayThreadsMu.Unlock()

	if st, ok := connA.allowedThread("t-floor-allow"); !ok || st.explicitDirectInputDenied || !st.directInputKnown || !st.canAcceptDirectInput {
		t.Fatalf("connA must see newer affirmative allow from restriction floor after main cache eviction: ok=%v %+v", ok, st)
	}
	// An omitted list row on connA must preserve allow v2 (not revert to denied at v2)!
	id3 := json.RawMessage(`203`)
	_ = connA.rememberPendingThreadRequest(&id3, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	omittedResp := []byte(fmt.Sprintf(`{"id":203,"result":{"data":[{"id":"t-floor-allow","cwd":%q}],"nextCursor":null}}`, projectDir))
	if _, forward, pErr := connA.observeUpstreamFrame(websocket.TextMessage, omittedResp); !forward || pErr != nil {
		t.Fatalf("omitted list failed: forward=%v err=%+v", forward, pErr)
	}
	if st, ok := connA.allowedThread("t-floor-allow"); !ok || st.explicitDirectInputDenied || !st.canAcceptDirectInput {
		t.Fatalf("omitted list row after main cache eviction must preserve newer allow v2: ok=%v %+v", ok, st)
	}
}

func TestThreadListDoesNotBlockOnBatchCleanupMutexAndFollowsRetargetedProjectSymlink(t *testing.T) {
	// 1) Holding managedWorktreeCleanupMu (simulating slow batch Git cleanup) MUST NOT block unrelated thread/list!
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:            config.Config{WorktreesRoot: t.TempDir()},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := newAppServerGatewayPolicy(router, "codex")
	id := json.RawMessage(`301`)
	_ = policy.rememberPendingThreadRequest(&id, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})

	router.managedWorktreeCleanupMu.Lock()
	done := make(chan bool, 1)
	go func() {
		resp := []byte(fmt.Sprintf(`{"id":301,"result":{"data":[{"id":"t-unblocked","cwd":%q}],"nextCursor":null}}`, projectDir))
		_, forward, pErr := policy.observeUpstreamFrame(websocket.TextMessage, resp)
		done <- (forward && pErr == nil)
	}()
	select {
	case ok := <-done:
		router.managedWorktreeCleanupMu.Unlock()
		if !ok {
			t.Fatal("unrelated thread/list should succeed while cleanup mutex is held")
		}
	case <-time.After(1 * time.Second):
		router.managedWorktreeCleanupMu.Unlock()
		t.Fatal("unrelated thread/list blocked on managedWorktreeCleanupMu!")
	}

	// 2) Retargeting a configured project symlink updates Global discovery attribution from repoV1 to repoV2!
	if runtime.GOOS == "windows" {
		return
	}
	relaxGlobalListGitWait(t)
	base := t.TempDir()
	repoV1 := filepath.Join(base, "repo-v1")
	repoV2 := filepath.Join(base, "repo-v2")
	browseRoot := filepath.Join(base, "browse")
	if err := os.MkdirAll(repoV1, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(repoV2, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(browseRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, repo := range []string{repoV1, repoV2} {
		runGitTestCommand(t, repo, "init")
		runGitTestCommand(t, repo, "-c", "user.email=test@example.invalid", "-c", "user.name=Test", "commit", "--allow-empty", "-m", "init")
	}
	wtV1 := filepath.Join(browseRoot, "wt-v1")
	wtV2 := filepath.Join(browseRoot, "wt-v2")
	runGitTestCommand(t, repoV1, "worktree", "add", "--detach", wtV1)
	runGitTestCommand(t, repoV2, "worktree", "add", "--detach", wtV2)

	projLink := filepath.Join(base, "proj-link")
	if err := os.Symlink(repoV1, projLink); err != nil {
		t.Fatal(err)
	}
	regSym, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "sym-proj", Name: "SymProj", Path: projLink},
	})
	if err != nil {
		t.Fatal(err)
	}
	// Retarget symlink to repoV2 AFTER startup!
	if err := os.Remove(projLink); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(repoV2, projLink); err != nil {
		t.Fatal(err)
	}

	routerSym := &Router{
		cfg:            config.Config{BrowseRoots: []string{browseRoot}, WorktreesRoot: t.TempDir()},
		projects:       regSym,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policySym := newAppServerGatewayPolicy(routerSym, "codex")
	idSym := json.RawMessage(`302`)
	_ = policySym.rememberPendingThreadRequest(&idSym, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	respSym := []byte(fmt.Sprintf(`{"id":302,"result":{"data":[{"id":"t-wt-v1","cwd":%q},{"id":"t-wt-v2","cwd":%q}],"nextCursor":null}}`, wtV1, wtV2))
	outSym, forwardSym, errSym := policySym.observeUpstreamFrame(websocket.TextMessage, respSym)
	if !forwardSym || errSym != nil {
		t.Fatalf("symlink retarget list failed: forward=%v err=%+v", forwardSym, errSym)
	}
	if bytes.Contains(outSym, []byte("t-wt-v1")) {
		t.Fatalf("worktree of old symlink target repoV1 must NOT be attributed after retarget: %s", outSym)
	}
	if !bytes.Contains(outSym, []byte("t-wt-v2")) {
		t.Fatalf("worktree of new symlink target repoV2 MUST be attributed after retarget: %s", outSym)
	}
	// Regular request gate (gatewayScopeForPath) must ALSO authorize repoV2 after symlink retarget!
	if scopeV2, ok := routerSym.gatewayScopeForPath(repoV2); !ok || scopeV2.id != "sym-proj" {
		t.Fatalf("gatewayScopeForPath must resolve retargeted symlink repoV2 to sym-proj: ok=%v %+v", ok, scopeV2)
	}
	if scopeV1, ok := routerSym.gatewayScopeForPath(repoV1); ok && scopeV1.id == "sym-proj" {
		t.Fatalf("gatewayScopeForPath must NOT attribute old symlink target repoV1 to sym-proj: %+v", scopeV1)
	}
}

func TestRound2RegressionsStaleListRetryPushSeedGuardsWindowsSpellingAndAutoTitle(t *testing.T) {
	projectDir := t.TempDir()
	otherProjectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
		{ID: "other", Name: "Other", Path: otherProjectDir},
	})
	if err != nil {
		t.Fatal(err)
	}

	// 1) [P1 #1] Staged list response with canAcceptDirectInput=true MUST NOT overwrite a newer concurrent denial
	//    written after claimUpstreamResponse!
	router := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policy := newAppServerGatewayPolicy(router, "claude")
	id1 := json.RawMessage(`401`)
	_ = policy.rememberPendingThreadRequest(&id1, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	var injected atomic.Bool
	policy.onStageBBeforeFinalCommitLock = func(int) {
		if injected.CompareAndSwap(false, true) {
			router.allowGatewayThread(appServerGatewayAllowedThread{
				id: "t-race-deny", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
				directInputKnown: true, canAcceptDirectInput: false, rawDirectInput: rawDirectInputDeny,
			})
		}
	}
	respRace := []byte(fmt.Sprintf(`{"id":401,"result":{"data":[{"id":"t-race-deny","cwd":%q,"canAcceptDirectInput":true}],"nextCursor":null}}`, projectDir))
	outRace, forwardRace, errRace := policy.observeUpstreamFrame(websocket.TextMessage, respRace)
	if !forwardRace || errRace != nil {
		t.Fatalf("stale list retry failed: forward=%v err=%+v", forwardRace, errRace)
	}
	if !bytes.Contains(outRace, []byte(`"canAcceptDirectInput":false`)) {
		t.Fatalf("stale list retry MUST preserve newer concurrent denial on wire: %s", outRace)
	}
	if st, ok := policy.allowedThread("t-race-deny"); !ok || !st.explicitDirectInputDenied || st.canAcceptDirectInput {
		t.Fatalf("stale list retry MUST NOT overwrite newer concurrent denial: ok=%v %+v", ok, st)
	}

	// 2) [P1 #2, #3, #4] Evicted main cache + surviving restriction floor -> push seed stays pushSeededOnly,
	//    lists emit canAcceptDirectInput=false, rejection directs to thread/read, and forged cross-scope thread/read is rejected!
	router2 := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	router2.allowGatewayThread(appServerGatewayAllowedThread{
		id: "t-push-floor", runtimeID: "claude", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: true, rawDirectInput: rawDirectInputAllow,
	})
	router2.gatewayThreadsMu.Lock()
	delete(router2.gatewayThreads, gatewayThreadCacheKey("claude", "t-push-floor"))
	router2.gatewayThreadsMu.Unlock()

	router2.restoreGatewayThreadAuthorization(pushbridge.LocateRecord{
		Runtime: "claude", ThreadID: "t-push-floor", CWD: projectDir,
	})
	policy2 := newAppServerGatewayPolicy(router2, "claude")
	if st, ok := policy2.allowedThread("t-push-floor"); !ok || !st.pushSeededOnly {
		t.Fatalf("push seed after main-cache eviction with surviving floor MUST stay pushSeededOnly: ok=%v %+v", ok, st)
	}
	// Turn write rejection must direct client to thread/read (NOT list refresh).
	turnReq := []byte(fmt.Sprintf(`{"id":402,"method":"turn/start","params":{"threadId":"t-push-floor","cwd":%q,"input":[{"type":"text","text":"hi"}]}}`, projectDir))
	if _, pErr := policy2.validateClientFrame(websocket.TextMessage, turnReq); pErr == nil || !bytes.Contains([]byte(pErr.message), []byte("thread/read")) {
		t.Fatalf("pushSeededOnly rejection must direct to thread/read: %+v", pErr)
	}
	// Global list MUST advertise canAcceptDirectInput=false while pushSeededOnly is active!
	idList := json.RawMessage(`403`)
	_ = policy2.rememberPendingThreadRequest(&idList, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	listOut, forwardList, errList := policy2.observeUpstreamFrame(websocket.TextMessage, []byte(fmt.Sprintf(`{"id":403,"result":{"data":[{"id":"t-push-floor","cwd":%q,"canAcceptDirectInput":true}],"nextCursor":null}}`, projectDir)))
	if !forwardList || errList != nil || !bytes.Contains(listOut, []byte(`"canAcceptDirectInput":false`)) {
		t.Fatalf("list must emit canAcceptDirectInput=false while pushSeededOnly is active: forward=%v err=%+v out=%s", forwardList, errList, listOut)
	}
	// Forged thread/read returning another configured workspace cwd MUST be rejected and MUST NOT clear pushSeededOnly!
	readBadID := json.RawMessage(`404`)
	_ = policy2.rememberPendingThreadRequest(&readBadID, appServerGatewayPendingThreadRequest{method: "thread/read", threadID: "t-push-floor"})
	readBadResp := []byte(fmt.Sprintf(`{"id":404,"result":{"thread":{"id":"t-push-floor","cwd":%q,"canAcceptDirectInput":true}}}`, otherProjectDir))
	if _, forwardBad, errBad := policy2.observeUpstreamFrame(websocket.TextMessage, readBadResp); forwardBad || errBad == nil {
		t.Fatalf("forged cross-scope thread/read for pushSeededOnly must be rejected: forward=%v err=%+v", forwardBad, errBad)
	}
	if st, ok := policy2.allowedThread("t-push-floor"); !ok || !st.pushSeededOnly {
		t.Fatalf("rejected thread/read must keep pushSeededOnly intact: ok=%v %+v", ok, st)
	}

	// 3) [P2 #7] syncRestrictionEvictionEpochLocked preserves connection-local autoTitleEligible!
	oldCap := appServerGatewayRestrictionFloorMax
	appServerGatewayRestrictionFloorMax = 1
	defer func() { appServerGatewayRestrictionFloorMax = oldCap }()
	router3 := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policy3 := newAppServerGatewayPolicy(router3, "codex")
	policy3.allowThread(appServerGatewayAllowedThread{
		id: "t-autotitle", runtimeID: "codex", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: true, autoTitleEligible: true,
	})
	// Trigger floor eviction epoch bump.
	for i := 0; i < 2; i++ {
		router3.allowGatewayThread(appServerGatewayAllowedThread{
			id: fmt.Sprintf("floor-bump-%d", i), runtimeID: "codex", cwd: projectDir, scopeID: "demo",
			directInputKnown: true, canAcceptDirectInput: false, rawDirectInput: rawDirectInputDeny,
		})
	}
	if st, ok := policy3.allowedThread("t-autotitle"); !ok || !st.autoTitleEligible {
		t.Fatalf("restriction floor eviction refresh must preserve connection-local autoTitleEligible: ok=%v %+v", ok, st)
	}

	// 4) [P2 #4] Oversized valid thread/list JSON-RPC error frame must be blocked by the history cap!
	oldCapBytes := appServerGatewayHistoryResponseCapBytes
	appServerGatewayHistoryResponseCapBytes = 256
	defer func() { appServerGatewayHistoryResponseCapBytes = oldCapBytes }()
	errID := json.RawMessage(`405`)
	_ = policy3.rememberPendingThreadRequest(&errID, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	hugeErrFrame := []byte(fmt.Sprintf(`{"id":405,"error":{"code":-32603,"message":%q}}`, string(bytes.Repeat([]byte("E"), 512))))
	if _, fwd, pErr := policy3.observeUpstreamFrame(websocket.TextMessage, hugeErrFrame); fwd || pErr == nil {
		t.Fatalf("oversized valid thread/list RPC error must be bounded by response cap: fwd=%v err=%+v", fwd, pErr)
	}
	appServerGatewayHistoryResponseCapBytes = oldCapBytes

	// 5) [P1 #6] Windows extended-length drive spelling matches ordinary drive project root in full gateway thread/list!
	if runtime.GOOS == "windows" {
		subDir := filepath.Join(projectDir, "sub")
		if err := os.MkdirAll(subDir, 0o755); err != nil {
			t.Fatal(err)
		}
		extPath := `\\?\` + subDir
		matched, ok := projects.MatchCanonicalPathInList(registry.List(), extPath)
		if !ok || matched.ID != "demo" {
			t.Fatalf("Windows extended-length path %q must match demo project, got ok=%v %+v", extPath, ok, matched)
		}
		winID := json.RawMessage(`406`)
		_ = policy3.rememberPendingThreadRequest(&winID, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
		winResp := []byte(fmt.Sprintf(`{"id":406,"result":{"data":[{"id":"t-win-ext","cwd":%q,"canAcceptDirectInput":true}],"nextCursor":null}}`, extPath))
		winOut, winFwd, winErr := policy3.observeUpstreamFrame(websocket.TextMessage, winResp)
		if !winFwd || winErr != nil || !bytes.Contains(winOut, []byte(`"t-win-ext"`)) {
			t.Fatalf("Windows extended-length cwd %q must be attributed in global thread/list: fwd=%v err=%+v out=%s", extPath, winFwd, winErr, winOut)
		}
	}
}

func TestRound3RegressionsOverlappingListsPushSeedCodexRecoveryAndSymlinkDrift(t *testing.T) {
	projectDir := t.TempDir()
	otherDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "demo", Name: "Demo", Path: projectDir},
		{ID: "other", Name: "Other", Path: otherDir},
	})
	if err != nil {
		t.Fatal(err)
	}

	// 1) [P1-1] Two overlapping lists: List 1 (writable) claimed FIRST commits FIRST;
	//    List 2 (denial) claimed SECOND commits SECOND -> List 2's newer denial MUST win!
	router1 := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policy1A := newAppServerGatewayPolicy(router1, "claude")
	policy1B := newAppServerGatewayPolicy(router1, "claude")
	idA := json.RawMessage(`501`)
	idB := json.RawMessage(`502`)
	_ = policy1A.rememberPendingThreadRequest(&idA, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	_ = policy1B.rememberPendingThreadRequest(&idB, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	respAllow := []byte(fmt.Sprintf(`{"id":501,"result":{"data":[{"id":"t-overlap","cwd":%q,"canAcceptDirectInput":true}],"nextCursor":null}}`, projectDir))
	respDeny := []byte(fmt.Sprintf(`{"id":502,"result":{"data":[{"id":"t-overlap","cwd":%q,"canAcceptDirectInput":false}],"nextCursor":null}}`, projectDir))
	var frameA, frameB appServerGatewayFrame
	_ = json.Unmarshal(respAllow, &frameA)
	_ = json.Unmarshal(respDeny, &frameB)
	claimA := policy1A.claimUpstreamResponse(respAllow, &frameA)
	claimB := policy1B.claimUpstreamResponse(respDeny, &frameB)
	if claimA.threadListBinding == nil || claimB.threadListBinding == nil || claimB.threadListBinding.claimDirectInputVersion <= claimA.threadListBinding.claimDirectInputVersion {
		t.Fatalf("overlapping claims must allocate strictly increasing versions: A=%+v B=%+v", claimA.threadListBinding, claimB.threadListBinding)
	}
	decA := policy1A.processPendingThreadListResponse(respAllow, frameA, *claimA.threadListBinding)
	if !decA.forward || decA.policyErr != nil {
		t.Fatalf("list A failed: %+v", decA)
	}
	decB := policy1B.processPendingThreadListResponse(respDeny, frameB, *claimB.threadListBinding)
	if !decB.forward || decB.policyErr != nil {
		t.Fatalf("list B failed: %+v", decB)
	}
	if st, ok := policy1B.allowedThread("t-overlap"); !ok || !st.explicitDirectInputDenied || st.canAcceptDirectInput {
		t.Fatalf("later denial list B must win over earlier writable list A: ok=%v %+v", ok, st)
	}

	// 2) [P1-2 + P1-4 + New P1 #1] Codex push-seeded thread:
	//    - Even after main cache eviction leaves a surviving floor, listing keeps pushSeededOnly=true;
	//    - Takeover error directs to thread/read;
	//    - Listing emits synthetic canAcceptDirectInput=false ONLY on wire (NOT cached as explicitDirectInputDenied);
	//    - Subsequent valid Codex thread/read (omitting canAcceptDirectInput) clears pushSeededOnly and enables turn/start!
	router2 := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policy2 := newAppServerGatewayPolicy(router2, "codex")
	router2.allowGatewayThread(appServerGatewayAllowedThread{
		id: "t-codex-seed", runtimeID: "codex", cwd: projectDir, scopeID: "demo",
		directInputKnown: true, canAcceptDirectInput: true, rawDirectInput: rawDirectInputAllow,
	})
	// Evict main entry leaving restriction floor, then restore push seed into both router & policy2.
	router2.gatewayThreadsMu.Lock()
	delete(router2.gatewayThreads, gatewayThreadCacheKey("codex", "t-codex-seed"))
	router2.gatewayThreadsMu.Unlock()
	router2.restoreGatewayThreadAuthorization(pushbridge.LocateRecord{
		Runtime: "codex", ThreadID: "t-codex-seed", CWD: projectDir,
	})
	// Seed connection-local entry via allowedThread read + check takeover error.
	if st, ok := policy2.allowedThread("t-codex-seed"); !ok || !st.pushSeededOnly {
		t.Fatalf("expected pushSeededOnly after push restore: ok=%v %+v", ok, st)
	}
	policy2.mu.Lock()
	policy2.allowedThreads["t-codex-seed"] = appServerGatewayAllowedThread{
		id: "t-codex-seed", runtimeID: "codex", cwd: projectDir, scopeID: "demo", pushSeededOnly: true,
	}
	policy2.mu.Unlock()
	// Evict main push entry again so global baseline is floor-only while connection holds pushSeededOnly!
	router2.gatewayThreadsMu.Lock()
	delete(router2.gatewayThreads, gatewayThreadCacheKey("codex", "t-codex-seed"))
	router2.gatewayThreadsMu.Unlock()

	idCodexList := json.RawMessage(`504`)
	_ = policy2.rememberPendingThreadRequest(&idCodexList, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	codexListOut, codexListFwd, codexListErr := policy2.observeUpstreamFrame(websocket.TextMessage, []byte(fmt.Sprintf(`{"id":504,"result":{"data":[{"id":"t-codex-seed","cwd":%q}],"nextCursor":null}}`, projectDir)))
	if !codexListFwd || codexListErr != nil || !bytes.Contains(codexListOut, []byte(`"canAcceptDirectInput":false`)) {
		t.Fatalf("codex list must emit synthetic canAcceptDirectInput=false while pushSeededOnly: fwd=%v err=%+v out=%s", codexListFwd, codexListErr, codexListOut)
	}
	if st, ok := policy2.allowedThread("t-codex-seed"); !ok || !st.pushSeededOnly || st.explicitDirectInputDenied {
		t.Fatalf("floor-only baseline must keep pushSeededOnly and NOT cache synthetic explicitDirectInputDenied: ok=%v %+v", ok, st)
	}
	// Standard Codex thread/read omits canAcceptDirectInput -> must clear pushSeededOnly and allow turn/start!
	readReq := []byte(`{"id":505,"method":"thread/read","params":{"threadId":"t-codex-seed"}}`)
	if _, pErr := policy2.validateClientFrame(websocket.TextMessage, readReq); pErr != nil {
		t.Fatalf("thread/read request rejected: %+v", pErr)
	}
	readResp := []byte(fmt.Sprintf(`{"id":505,"result":{"thread":{"id":"t-codex-seed","cwd":%q}}}`, projectDir))
	if _, fwd, pErr := policy2.observeUpstreamFrame(websocket.TextMessage, readResp); !fwd || pErr != nil {
		t.Fatalf("codex thread/read failed: fwd=%v err=%+v", fwd, pErr)
	}
	turnReq := []byte(fmt.Sprintf(`{"id":506,"method":"turn/start","params":{"threadId":"t-codex-seed","cwd":%q,"input":[{"type":"text","text":"hello"}]}}`, projectDir))
	if _, pErr := policy2.validateClientFrame(websocket.TextMessage, turnReq); pErr != nil {
		t.Fatalf("codex turn/start after valid thread/read must succeed: %+v", pErr)
	}

	// 3) [P1-3 + P1-4] Push-seeded Claude thread:
	//    - thread/takeover rejection directs to thread/read;
	//    - Cache evicted while thread/read is in flight -> forged cross-scope read STILL rejected!
	router3 := &Router{projects: registry, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	router3.restoreGatewayThreadAuthorization(pushbridge.LocateRecord{Runtime: "claude", ThreadID: "t-evict-read", CWD: projectDir})
	policy3 := newAppServerGatewayPolicy(router3, "claude")
	takeoverReq := []byte(fmt.Sprintf(`{"id":503,"method":"thread/takeover","params":{"threadId":"t-evict-read","cwd":%q}}`, projectDir))
	if _, pErr := policy3.validateClientFrame(websocket.TextMessage, takeoverReq); pErr == nil || !bytes.Contains([]byte(pErr.message), []byte("thread/read")) {
		t.Fatalf("pushSeededOnly takeover rejection must direct to thread/read: %+v", pErr)
	}
	evictReadReq := []byte(`{"id":507,"method":"thread/read","params":{"threadId":"t-evict-read"}}`)
	if _, pErr := policy3.validateClientFrame(websocket.TextMessage, evictReadReq); pErr != nil {
		t.Fatalf("thread/read request failed: %+v", pErr)
	}
	// Evict BOTH router cache and conn cache while read is in flight.
	router3.gatewayThreadsMu.Lock()
	delete(router3.gatewayThreads, gatewayThreadCacheKey("claude", "t-evict-read"))
	router3.gatewayThreadsMu.Unlock()
	policy3.mu.Lock()
	delete(policy3.allowedThreads, "t-evict-read")
	policy3.mu.Unlock()
	forgedReadResp := []byte(fmt.Sprintf(`{"id":507,"result":{"thread":{"id":"t-evict-read","cwd":%q,"canAcceptDirectInput":true}}}`, otherDir))
	if _, fwd, pErr := policy3.observeUpstreamFrame(websocket.TextMessage, forgedReadResp); fwd || pErr == nil {
		t.Fatalf("forged cross-scope thread/read after cache eviction must still be rejected: fwd=%v err=%+v", fwd, pErr)
	}

	// 4) [P1-5 + New P1 #2] Mid-page symlink retarget must NOT authorize former target repoV1,
	//    and writableRoots / mentions (projectForGatewayPath) follow repoV2 and reject repoV1!
	symBase := t.TempDir()
	repoV1 := filepath.Join(symBase, "repo-v1")
	repoV2 := filepath.Join(symBase, "repo-v2")
	if err := os.MkdirAll(repoV1, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(repoV2, 0o755); err != nil {
		t.Fatal(err)
	}
	linkPath := filepath.Join(symBase, "active-link")
	if err := os.Symlink(repoV1, linkPath); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	regSym, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "sym", Name: "Sym", Path: linkPath},
	})
	if err != nil {
		t.Fatal(err)
	}
	routerSym := &Router{projects: regSym, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policySym := newAppServerGatewayPolicy(routerSym, "codex")
	var retargeted atomic.Bool
	policySym.onStageAAfterPathProbe = func(int) {
		if retargeted.CompareAndSwap(false, true) {
			_ = os.Remove(linkPath)
			_ = os.Symlink(repoV2, linkPath)
		}
	}
	idSym := json.RawMessage(`508`)
	_ = policySym.rememberPendingThreadRequest(&idSym, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	symResp := []byte(fmt.Sprintf(`{"id":508,"result":{"data":[{"id":"t-old-v1","cwd":%q},{"id":"t-new-v2","cwd":%q}],"nextCursor":null}}`, repoV1, repoV2))
	symOut, symFwd, symErr := policySym.observeUpstreamFrame(websocket.TextMessage, symResp)
	if !symFwd || symErr != nil {
		t.Fatalf("mid-page symlink retarget list failed: fwd=%v err=%+v", symFwd, symErr)
	}
	if bytes.Contains(symOut, []byte(`"t-old-v1"`)) || !bytes.Contains(symOut, []byte(`"t-new-v2"`)) {
		t.Fatalf("mid-page symlink retarget must drop old repoV1 and attribute new repoV2: %s", symOut)
	}
	if _, ok := policySym.allowedThread("t-old-v1"); ok {
		t.Fatal("former symlink target t-old-v1 must NOT be authorized")
	}
	if _, ok := routerSym.projectForGatewayPath(repoV2); !ok {
		t.Fatal("projectForGatewayPath (writableRoots/mentions) must accept retargeted repoV2")
	}
	if _, ok := routerSym.projectForGatewayPath(repoV1); ok {
		t.Fatal("projectForGatewayPath (writableRoots/mentions) must reject former target repoV1")
	}

	// 5) [Round 4 P1 #1] Project-root retry during a concurrent managed-worktree revocation MUST preserve
	//    the initial lifecycle epoch and disallow missing-directory fallback for the deleted checkout!
	revBase := t.TempDir()
	revProjV1 := filepath.Join(revBase, "proj-v1")
	revProjV2 := filepath.Join(revBase, "proj-v2")
	revDeletedCheckout := filepath.Join(revProjV2, "wt-deleted")
	for _, d := range []string{revProjV1, revProjV2, revDeletedCheckout} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	revLink := filepath.Join(revBase, "proj-link")
	if err := os.Symlink(revProjV1, revLink); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	regRev, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "rev", Name: "Rev", Path: revLink},
	})
	if err != nil {
		t.Fatal(err)
	}
	routerRev := &Router{projects: regRev, gatewayThreads: map[string]appServerGatewayAllowedThread{}}
	policyRev := newAppServerGatewayPolicy(routerRev, "codex")
	var revInjected atomic.Bool
	policyRev.onStageAAfterPathProbe = func(int) {
		if revInjected.CompareAndSwap(false, true) {
			_ = os.Remove(revLink)
			_ = os.Symlink(revProjV2, revLink)
			// Concurrently delete & revoke a managed checkout inside revProjV2 during the same scan!
			canonicalDel := canonicalPathBestEffort(revDeletedCheckout)
			_ = os.RemoveAll(revDeletedCheckout)
			routerRev.managedWorktreesMu.Lock()
			ep := routerRev.managedWorktreeLifecycleEpoch.Add(1)
			routerRev.managedWorktreeRecentDeletions = append(routerRev.managedWorktreeRecentDeletions, deletedManagedWorktreeRecord{
				checkoutPath:   canonicalDel,
				workspacePath:  canonicalDel,
				deletedAtEpoch: ep,
			})
			routerRev.managedWorktreesMu.Unlock()
		}
	}
	idRev := json.RawMessage(`509`)
	_ = policyRev.rememberPendingThreadRequest(&idRev, appServerGatewayPendingThreadRequest{method: "thread/list", globalDiscovery: true})
	revResp := []byte(fmt.Sprintf(`{"id":509,"result":{"data":[{"id":"t-old","cwd":%q},{"id":"t-revoked-wt","cwd":%q},{"id":"t-live-v2","cwd":%q}],"nextCursor":null}}`, revProjV1, revDeletedCheckout, revProjV2))
	revOut, revFwd, revErr := policyRev.observeUpstreamFrame(websocket.TextMessage, revResp)
	if !revFwd || revErr != nil {
		t.Fatalf("root-retry + worktree-revocation list failed: fwd=%v err=%+v", revFwd, revErr)
	}
	if bytes.Contains(revOut, []byte(`"t-revoked-wt"`)) {
		t.Fatalf("revoked checkout under retargeted project must NOT gain fresh missing-dir authorization: %s", revOut)
	}
	if _, ok := policyRev.allowedThread("t-revoked-wt"); ok {
		t.Fatal("revoked checkout must NOT be authorized in cache")
	}
	if !bytes.Contains(revOut, []byte(`"t-live-v2"`)) {
		t.Fatalf("healthy retargeted project row must still be returned: %s", revOut)
	}
}
