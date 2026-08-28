package httpapi

import (
	"encoding/json"
	"testing"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestGatewayTurnAdmissionIsAtomicAcrossMobileAndRemoteCLI(t *testing.T) {
	router := &Router{
		cfg:                config.Config{AppServer: config.AppServerConfig{RemoteGateway: config.RemoteGatewayConfig{Enabled: true}}},
		gatewayActiveTurns: map[string]appServerGatewayTurnAdmission{},
	}
	mobile := &appServerGatewayPolicy{
		router:            router,
		clientKind:        appServerGatewayClientMobile,
		connectionID:      1,
		pendingTurnStarts: map[string]string{},
	}
	remote := &appServerGatewayPolicy{
		router:            router,
		clientKind:        appServerGatewayClientRemoteCLI,
		connectionID:      2,
		pendingTurnStarts: map[string]string{},
	}
	id1 := json.RawMessage(`1`)
	id2 := json.RawMessage(`2`)
	if err := mobile.reservePendingTurnStart(&id1, "thread-1"); err != nil {
		t.Fatal(err)
	}
	if err := remote.reservePendingTurnStart(&id2, "thread-1"); err == nil {
		t.Fatal("second surface must not start a concurrent turn")
	}

	// 连接结束不能证明上游没有接受请求，因此 close 不释放 admission。
	mobile.close()
	if err := remote.reservePendingTurnStart(&id2, "thread-1"); err == nil {
		t.Fatal("disconnect must not release uncertain turn admission")
	}
	mobile.observePendingTurnStartResponse(&appServerGatewayFrame{
		ID:     &id1,
		Result: json.RawMessage(`{"turn":{"id":"turn-1"}}`),
	}, "turn/start")
	remote.observeTurnCompletion(&appServerGatewayFrame{
		Method: "turn/completed",
		Params: json.RawMessage(`{"threadId":"thread-1","turn":{"id":"turn-1"}}`),
	})
	if err := remote.reservePendingTurnStart(&id2, "thread-1"); err != nil {
		t.Fatalf("terminal notification should release admission: %v", err)
	}
}

func TestGatewayTurnAdmissionReleasesDefiniteStartError(t *testing.T) {
	router := &Router{
		cfg:                config.Config{AppServer: config.AppServerConfig{RemoteGateway: config.RemoteGatewayConfig{Enabled: true}}},
		gatewayActiveTurns: map[string]appServerGatewayTurnAdmission{},
	}
	first := &appServerGatewayPolicy{router: router, connectionID: 1, pendingTurnStarts: map[string]string{}}
	second := &appServerGatewayPolicy{router: router, connectionID: 2, pendingTurnStarts: map[string]string{}}
	id1 := json.RawMessage(`1`)
	id2 := json.RawMessage(`2`)
	if err := first.reservePendingTurnStart(&id1, "thread-1"); err != nil {
		t.Fatal(err)
	}
	first.observePendingTurnStartResponse(&appServerGatewayFrame{
		ID:    &id1,
		Error: json.RawMessage(`{"code":-32000,"message":"rejected"}`),
	}, "turn/start")
	if err := second.reservePendingTurnStart(&id2, "thread-1"); err != nil {
		t.Fatalf("definite upstream rejection should release admission: %v", err)
	}
}

func TestGatewayTurnAdmissionIgnoresOldAndUnidentifiedTerminalNotifications(t *testing.T) {
	router := &Router{
		cfg:                config.Config{AppServer: config.AppServerConfig{RemoteGateway: config.RemoteGatewayConfig{Enabled: true}}},
		gatewayActiveTurns: map[string]appServerGatewayTurnAdmission{},
	}
	first := &appServerGatewayPolicy{router: router, connectionID: 1, pendingTurnStarts: map[string]string{}}
	second := &appServerGatewayPolicy{router: router, connectionID: 2, pendingTurnStarts: map[string]string{}}
	id1 := json.RawMessage(`1`)
	id2 := json.RawMessage(`2`)
	if err := first.reservePendingTurnStart(&id1, "thread-1"); err != nil {
		t.Fatal(err)
	}

	// 上一个 turn 的重复终态和无 turn ID 的 thread 终态都不能释放新 reservation。
	router.completeGatewayTurn("thread-1", "turn-old")
	router.completeGatewayTurn("thread-1", "")
	if err := second.reservePendingTurnStart(&id2, "thread-1"); err == nil {
		t.Fatal("old terminal notification must not release pending reservation")
	}
	first.observePendingTurnStartResponse(&appServerGatewayFrame{
		ID:     &id1,
		Result: json.RawMessage(`{"turn":{"id":"turn-new"}}`),
	}, "turn/start")
	router.completeGatewayTurn("thread-1", "turn-old")
	if err := second.reservePendingTurnStart(&id2, "thread-1"); err == nil {
		t.Fatal("old terminal notification must not release confirmed reservation")
	}
	router.completeGatewayTurn("thread-1", "turn-new")
	if err := second.reservePendingTurnStart(&id2, "thread-1"); err != nil {
		t.Fatalf("matching terminal notification should release reservation: %v", err)
	}
}

func TestGatewayTurnAdmissionMatchesCompletionThatPrecedesStartResponse(t *testing.T) {
	router := &Router{
		cfg:                config.Config{AppServer: config.AppServerConfig{RemoteGateway: config.RemoteGatewayConfig{Enabled: true}}},
		gatewayActiveTurns: map[string]appServerGatewayTurnAdmission{},
	}
	first := &appServerGatewayPolicy{router: router, connectionID: 1, pendingTurnStarts: map[string]string{}}
	second := &appServerGatewayPolicy{router: router, connectionID: 2, pendingTurnStarts: map[string]string{}}
	id1 := json.RawMessage(`1`)
	id2 := json.RawMessage(`2`)
	if err := first.reservePendingTurnStart(&id1, "thread-1"); err != nil {
		t.Fatal(err)
	}
	router.completeGatewayTurn("thread-1", "turn-fast")
	first.observePendingTurnStartResponse(&appServerGatewayFrame{
		ID:     &id1,
		Result: json.RawMessage(`{"turn":{"id":"turn-fast"}}`),
	}, "turn/start")
	if err := second.reservePendingTurnStart(&id2, "thread-1"); err != nil {
		t.Fatalf("matching completion observed before response should release reservation: %v", err)
	}
}

func TestGatewayTurnAdmissionDoesNotApplyToClaudeBridge(t *testing.T) {
	router := &Router{
		cfg:                config.Config{AppServer: config.AppServerConfig{RemoteGateway: config.RemoteGatewayConfig{Enabled: true}}},
		gatewayActiveTurns: map[string]appServerGatewayTurnAdmission{},
	}
	claude := &appServerGatewayPolicy{router: router, runtimeID: "claude", pendingTurnStarts: map[string]string{}}
	id := json.RawMessage(`1`)
	if err := claude.reservePendingTurnStart(&id, "thread-1"); err != nil {
		t.Fatalf("remote Codex admission must not change Claude bridge: %v", err)
	}
	if len(router.gatewayActiveTurns) != 0 {
		t.Fatalf("Claude bridge must not reserve Codex turns: %+v", router.gatewayActiveTurns)
	}
}

func TestGatewayTurnAdmissionCoversReviewAndRejectsUncorrelatableCompact(t *testing.T) {
	if !gatewayMethodStartsTurnWork("turn/start") || !gatewayMethodStartsTurnWork("review/start") {
		t.Fatal("turn/start and inline review/start must share the same admission")
	}
	if gatewayMethodStartsTurnWork("thread/compact/start") {
		t.Fatal("compact response has no turn ID and cannot use turn admission")
	}
	router := &Router{
		cfg:                config.Config{AppServer: config.AppServerConfig{RemoteGateway: config.RemoteGatewayConfig{Enabled: true}}},
		gatewayActiveTurns: map[string]appServerGatewayTurnAdmission{},
	}
	policy := &appServerGatewayPolicy{router: router, runtimeID: "codex", clientKind: appServerGatewayClientMobile}
	id := json.RawMessage(`1`)
	payload := []byte(`{"id":1,"method":"thread/compact/start","params":{"threadId":"thread-1"}}`)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, payload); policyErr == nil || policyErr.id == nil || string(*policyErr.id) != string(id) {
		t.Fatalf("compact must fail closed while remote gateway is enabled: %+v", policyErr)
	}
}

func TestGatewayTurnAdmissionRejectsCrossMethodRequestIDReuse(t *testing.T) {
	router := &Router{
		cfg:                config.Config{AppServer: config.AppServerConfig{RemoteGateway: config.RemoteGatewayConfig{Enabled: true}}},
		gatewayActiveTurns: map[string]appServerGatewayTurnAdmission{},
	}
	policy := &appServerGatewayPolicy{
		router:                 router,
		runtimeID:              "codex",
		connectionID:           1,
		pendingTurnStarts:      map[string]string{},
		inflightClientRequests: map[string]string{},
	}
	other := &appServerGatewayPolicy{router: router, runtimeID: "codex", connectionID: 2, pendingTurnStarts: map[string]string{}}
	id := json.RawMessage(`7`)
	escapedID := json.RawMessage(`"\u0078"`)
	plainID := json.RawMessage(`"x"`)
	otherID := json.RawMessage(`8`)
	if err := policy.reserveInflightClientRequest(&id, "turn/start"); err != nil {
		t.Fatal(err)
	}
	if err := policy.reservePendingTurnStart(&id, "thread-1"); err != nil {
		t.Fatal(err)
	}
	if err := policy.reserveInflightClientRequest(&id, "turn/interrupt"); err == nil {
		t.Fatal("non-turn request must not reuse an inflight turn request ID")
	}
	policy.cancelInflightClientRequest(&id)
	if err := policy.reserveInflightClientRequest(&plainID, "turn/start"); err != nil {
		t.Fatal(err)
	}
	if err := policy.reserveInflightClientRequest(&escapedID, "turn/interrupt"); err == nil {
		t.Fatal("semantically equal escaped string ID must be treated as duplicate")
	}
	// 即使伪造一个同 ID 的普通错误响应，方法关联也不能释放 turn reservation。
	policy.observePendingTurnStartResponse(&appServerGatewayFrame{
		ID:    &id,
		Error: json.RawMessage(`{"code":-1,"message":"interrupt failed"}`),
	}, "turn/interrupt")
	if err := other.reservePendingTurnStart(&otherID, "thread-1"); err == nil {
		t.Fatal("ordinary response with reused ID must not release turn admission")
	}
}

func TestGatewayRequestIDKeyCanonicalizesAndRejectsUnsafeTypes(t *testing.T) {
	key := func(raw string) string {
		id := json.RawMessage(raw)
		return gatewayRequestIDKey(&id)
	}
	if key(`"x"`) != key(`"\u0078"`) || key(`"1"`) == key(`1`) {
		t.Fatal("request ID key must canonicalize strings while preserving string/number types")
	}
	if key(`-0`) != key(`0`) || key(`123456789012345678901234567890`) == "" {
		t.Fatal("integer request IDs must have an exact canonical representation")
	}
	for _, raw := range []string{"null", "true", "1.0", "1e0", `[]`, `{}`} {
		if got := key(raw); got != "" {
			t.Fatalf("unsafe request ID %s must be rejected, got %q", raw, got)
		}
	}
}

func TestInitializedRejectsAnyID(t *testing.T) {
	policy := &appServerGatewayPolicy{}
	for _, payload := range []string{
		`{"id":1,"method":"initialized","params":{}}`,
		`{"id":null,"method":"initialized","params":{}}`,
	} {
		if _, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(payload)); policyErr == nil {
			t.Fatalf("initialized with id must be rejected: %s", payload)
		}
	}
}
