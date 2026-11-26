package setup

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestPreflightHostUsesEvidenceFromSavedGeneration(t *testing.T) {
	key := "fixture-agent-token-0123456789"
	var generation atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+key {
			http.Error(w, "forbidden", 401)
			return
		}
		host := PreflightHost{Generation: generation.Load().(string), Version: "test", Ready: true, FolderDenied: true, Accounts: map[string]string{"codex": "connected"}, Assistants: map[string]bool{"codex": true}, Networks: map[string]bool{"lan": true}}
		json.NewEncoder(w).Encode(host)
	}))
	defer srv.Close()
	dir := t.TempDir()
	raw, err := json.Marshal(map[string]any{
		"listen": strings.TrimPrefix(srv.URL, "http://"), "auth": map[string]string{"token": key},
		"app_server": map[string]string{"transport": "ssh", "ssh_target": "fixture.invalid"},
		"scan_roots": []string{dir}, "browse_roots": []string{dir},
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.ParseSetupDocument(raw).Config
	gen := cfg.SourceGeneration()
	if gen == "" {
		t.Fatal("missing source generation")
	}
	for _, test := range []struct {
		name, generation string
		observed         bool
	}{
		{"same", gen, true}, {"replaced", config.ParseSetupDocument(append(raw, ' ')).Config.SourceGeneration(), false}, {"legacy", "", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			generation.Store(test.generation)
			got, err := FetchPreflightHost(context.Background(), cfg)
			if err != nil || !got.Ready || !got.Assistants["codex"] || !got.Networks["lan"] {
				t.Fatalf("lost core or applied modules: %+v, %v", got, err)
			}
			if got.FolderDenied != test.observed || (got.Accounts["codex"] == "connected") != test.observed {
				t.Fatalf("cross-generation evidence: %+v", got)
			}
		})
	}
}

func TestPreflightRejectsUnverifiedManagedConnection(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { calls.Add(1) }))
	defer srv.Close()
	cfg := config.Config{Listen: strings.TrimPrefix(srv.URL, "http://"), Auth: config.AuthConfig{Token: "test-credential"}}
	dial := func(context.Context, string, string) (net.Conn, error) {
		return nil, PreflightHostError("service_port_in_use")
	}
	_, err := fetchPreflightHost(context.Background(), cfg, dial)
	var typed PreflightHostError
	if !errors.As(err, &typed) || string(typed) != "service_port_in_use" || calls.Load() != 0 {
		t.Fatalf("err=%v calls=%d", err, calls.Load())
	}
}
