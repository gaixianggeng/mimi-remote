package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/google/uuid"
)

func TestTailcatActivationSurvivesRequestCancellationAndDeduplicates(t *testing.T) {
	server, sidecar, _ := newLinkTestServer(t)
	entered, release := make(chan struct{}), make(chan struct{})
	sidecar.pairHook = func(ctx context.Context) error {
		close(entered)
		select {
		case <-release:
			return ctx.Err()
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	id := uuid.NewString()
	ctx, cancel := context.WithCancel(context.Background())
	req := authedRequest(t, http.MethodPost, tailcatActivationPath, map[string]string{"request_id": id}).WithContext(ctx)
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, req)
	if response.Code != http.StatusAccepted {
		t.Fatalf("start: %d %s", response.Code, response.Body.String())
	}
	cancel()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("operation not started")
	}
	retry := httptest.NewRecorder()
	server.handler.ServeHTTP(retry, authedRequest(t, http.MethodPost, tailcatActivationPath, map[string]string{"request_id": id}))
	if retry.Code != http.StatusAccepted {
		t.Fatalf("retry: %d", retry.Code)
	}
	busy := httptest.NewRecorder()
	server.handler.ServeHTTP(busy, authedRequest(t, http.MethodPost, tailcatActivationPath, map[string]string{"request_id": uuid.NewString()}))
	if busy.Code != http.StatusConflict {
		t.Fatalf("concurrent activation: %d", busy.Code)
	}
	close(release)
	server.router.tailcatActivation.wg.Wait()
	result := httptest.NewRecorder()
	server.handler.ServeHTTP(result, authedRequest(t, http.MethodGet, tailcatActivationPath+"/"+id, nil))
	var body tailcatActivationResult
	if err := json.Unmarshal(result.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.State != "completed" || body.Result == nil || sidecar.pairCalls != 1 {
		t.Fatalf("result=%+v pairs=%d", body, sidecar.pairCalls)
	}
}

func TestTailcatActivationShutdownCancelsOperation(t *testing.T) {
	server, sidecar, _ := newLinkTestServer(t)
	entered := make(chan struct{})
	sidecar.pairHook = func(ctx context.Context) error { close(entered); <-ctx.Done(); return ctx.Err() }
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, tailcatActivationPath, map[string]string{"request_id": uuid.NewString()}))
	<-entered
	server.router.tailcatActivation.close()
	if !server.router.tailcatControlMu.TryLock() {
		t.Fatal("operation did not release lock")
	}
	server.router.tailcatControlMu.Unlock()
}

func TestTailcatActivationAndFreeRouteRequireBearer(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) { cfg.DevInsecure = true; cfg.Auth.AllowQueryToken = true })
	for _, path := range []string{tailcatActivationPath, tailcatActivationPath + "/" + uuid.NewString(), "/api/tailcat/free-route"} {
		response := httptest.NewRecorder()
		server.handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, path+"?token="+testToken, nil))
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("%s: %d", path, response.Code)
		}
	}
}

func TestTailcatRelayChoiceReportsSelectionWithoutAddresses(t *testing.T) {
	const relayURL = "https://relay.example/map.json"
	for _, test := range []struct {
		name          string
		mode, freeURL string
		relay, free   string
	}{
		{"default", config.TailcatModeSelfHosted, "", "default", "default"},
		{"custom", config.TailcatModeSelfHosted, relayURL, "custom", "custom"},
		{"mimi over default", config.TailcatModeManaged, "", "mimi", "default"},
		{"mimi over custom", config.TailcatModeManaged, relayURL, "mimi", "custom"},
	} {
		t.Run(test.name, func(t *testing.T) {
			server, sidecar, _ := newLinkTestServer(t)
			sidecar.status.Mode, sidecar.status.FreeDERPMapURL = test.mode, test.freeURL
			response := httptest.NewRecorder()
			server.handler.ServeHTTP(response, authedRequest(t, http.MethodGet, "/api/tailcat/relay-choice", nil))
			if response.Code != http.StatusOK {
				t.Fatalf("status: %d %s", response.Code, response.Body.String())
			}
			if strings.Contains(response.Body.String(), "relay.example") {
				t.Fatalf("relay address leaked: %s", response.Body.String())
			}
			var body map[string]string
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body["relay_service"] != test.relay || body["free_relay_service"] != test.free {
				t.Fatalf("wrong choice: %v", body)
			}
		})
	}
}

func TestTailcatRelayChoiceRequiresBearerGetAndEnabledRoute(t *testing.T) {
	server, sidecar, _ := newLinkTestServer(t)
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/tailcat/relay-choice", nil))
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("no bearer: %d", response.Code)
	}
	response = httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, "/api/tailcat/relay-choice", map[string]string{}))
	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("post: %d", response.Code)
	}
	sidecar.status.Enabled = false
	response = httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodGet, "/api/tailcat/relay-choice", nil))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("disabled: %d", response.Code)
	}
}

func TestTailcatFreeRouteOnlyAuthorizesFreeNode(t *testing.T) {
	server, sidecar, _ := newLinkTestServer(t)
	sidecar.status.Mode, sidecar.status.FreeAddress = config.TailcatModeManaged, "tailcat:free"
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, "/api/tailcat/free-route", map[string]string{"client_key": testManagedMobileKey}))
	if response.Code != http.StatusOK || sidecar.allowCalls != 1 || sidecar.managedCalls != 0 {
		t.Fatalf("free route: %d allow=%d managed=%d", response.Code, sidecar.allowCalls, sidecar.managedCalls)
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["tailcat_address"] != "tailcat:free" {
		t.Fatalf("wrong node: %v", body)
	}
	sidecar.status.FreeAddress = ""
	response = httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, "/api/tailcat/free-route", map[string]string{"client_key": testManagedMobileKey}))
	if response.Code != http.StatusServiceUnavailable || sidecar.allowCalls != 1 {
		t.Fatal("authorized unavailable free node")
	}
}

func TestTailcatActivationFailureRestoresOnlyNewlyEnabledRelay(t *testing.T) {
	for _, alreadyManaged := range []bool{false, true} {
		t.Run(map[bool]string{false: "free", true: "already-managed"}[alreadyManaged], func(t *testing.T) {
			server, sidecar, controller := newLinkTestServer(t)
			if alreadyManaged {
				if _, err := controller.ConfigureMode(context.Background(), true); err != nil {
					t.Fatal(err)
				}
			}
			sidecar.pairHook = func(context.Context) error { return errors.New("pair unavailable") }
			response := httptest.NewRecorder()
			id := uuid.NewString()
			server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, tailcatActivationPath, map[string]string{"request_id": id}))
			server.router.tailcatActivation.wg.Wait()
			if (sidecar.status.Mode == config.TailcatModeManaged) != alreadyManaged {
				t.Fatalf("failure changed previous mode: %s", sidecar.status.Mode)
			}
			if !sidecar.status.Enabled || !sidecar.status.Running {
				t.Fatal("failure stopped existing free connection")
			}
			result := httptest.NewRecorder()
			server.handler.ServeHTTP(result, authedRequest(t, http.MethodGet, tailcatActivationPath+"/"+id, nil))
			var body tailcatActivationResult
			if err := json.Unmarshal(result.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body.State != "failed" || body.Code != "tailcat_pair_failed" || body.Result != nil {
				t.Fatalf("result = %+v", body)
			}
		})
	}
}

func TestTailcatActivationExpiredResultCannotBeReused(t *testing.T) {
	server, _, _ := newLinkTestServer(t)
	id := uuid.NewString()
	server.router.tailcatActivation.operations = map[string]*tailcatActivationOperation{
		id: {result: tailcatActivationResult{ID: id, State: "completed"}, expires: time.Now().Add(-time.Second), cancel: func() {}},
	}
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodGet, tailcatActivationPath+"/"+id, nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("expired result returned %d", response.Code)
	}
}

func TestTailcatActivationRollbackAfterControlPlaneRejection(t *testing.T) {
	for _, alreadyManaged := range []bool{false, true} {
		t.Run(map[bool]string{false: "free", true: "already-managed"}[alreadyManaged], func(t *testing.T) {
			server, sidecar, _ := newLinkTestServer(t)
			if alreadyManaged {
				sidecar.status.Mode = config.TailcatModeManaged
			}
			id := uuid.NewString()
			started := httptest.NewRecorder()
			server.handler.ServeHTTP(started, authedRequest(t, http.MethodPost, tailcatActivationPath, map[string]string{"request_id": id}))
			server.router.tailcatActivation.wg.Wait()
			if sidecar.status.Mode != config.TailcatModeManaged {
				t.Fatal("activation did not select Mimi")
			}
			for attempt := 0; attempt < 2; attempt++ {
				response := httptest.NewRecorder()
				server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, tailcatActivationPath+"/"+id+"/rollback", nil))
				if response.Code != http.StatusOK {
					t.Fatalf("rollback: %d %s", response.Code, response.Body.String())
				}
			}
			if (sidecar.status.Mode == config.TailcatModeManaged) != alreadyManaged {
				t.Fatalf("wrong restored mode: %s", sidecar.status.Mode)
			}
			if !sidecar.status.Enabled || !sidecar.status.Running {
				t.Fatal("rollback stopped original connection")
			}
		})
	}
}

func TestTailcatActivationRollbackCannotOverrideLaterPairing(t *testing.T) {
	server, sidecar, _ := newLinkTestServer(t)
	id := uuid.NewString()
	server.handler.ServeHTTP(httptest.NewRecorder(), authedRequest(t, http.MethodPost, tailcatActivationPath, map[string]string{"request_id": id}))
	server.router.tailcatActivation.wg.Wait()
	sidecar.status.PairPublicKey = "nodekey:" + strings.Repeat("e", 64)
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, tailcatActivationPath+"/"+id+"/rollback", nil))
	if response.Code != http.StatusConflict || sidecar.status.Mode != config.TailcatModeManaged {
		t.Fatalf("late rollback changed newer pairing: %d", response.Code)
	}
	unauthorized := httptest.NewRecorder()
	server.handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodPost, tailcatActivationPath+"/"+id+"/rollback", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("rollback without Bearer: %d", unauthorized.Code)
	}
}

func TestTailcatActivationCanRollBackWhilePairingIsPending(t *testing.T) {
	server, sidecar, _ := newLinkTestServer(t)
	entered := make(chan struct{})
	sidecar.pairHook = func(ctx context.Context) error { close(entered); <-ctx.Done(); return ctx.Err() }
	id := uuid.NewString()
	server.handler.ServeHTTP(httptest.NewRecorder(), authedRequest(t, http.MethodPost, tailcatActivationPath, map[string]string{"request_id": id}))
	<-entered
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, tailcatActivationPath+"/"+id+"/rollback", nil))
	if response.Code != http.StatusAccepted {
		t.Fatalf("pending rollback: %d", response.Code)
	}
	server.router.tailcatActivation.wg.Wait()
	if sidecar.status.Mode == config.TailcatModeManaged || !sidecar.status.Enabled {
		t.Fatal("cancelled activation did not restore original route")
	}
}
