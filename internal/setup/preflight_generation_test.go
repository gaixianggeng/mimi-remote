package setup

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
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

func TestInspectPreflightConfigRestartRequiredMatchesAppliedGeneration(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	raw, err := json.Marshal(map[string]any{
		"listen": "127.0.0.1:8787", "auth": map[string]string{"token": "fixture-agent-token-0123456789"},
		"app_server": map[string]string{"transport": "ssh", "ssh_target": "fixture.invalid"},
		"codex":      map[string]any{"enabled": true},
		"network":    map[string]any{"allow_lan": true, "allow_tailscale": false},
		"scan_roots": []string{dir}, "browse_roots": []string{dir},
	})
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, path, raw)
	savedGen := config.ReadPreflightSnapshot(path).Config.SourceGeneration()
	oldGen := config.ParseSetupDocument(append(raw, ' ')).Config.SourceGeneration()
	empty := ""

	cases := []struct {
		name              string
		host              PreflightHost
		wantRestartNeeded bool
	}{
		{
			name: "applied_generation_matches",
			host: PreflightHost{
				Generation: savedGen, AppliedGeneration: &savedGen, Version: "test", Ready: true,
				Assistants: map[string]bool{"codex": true}, Networks: map[string]bool{"lan": true},
			},
			wantRestartNeeded: false,
		},
		{
			name: "live_tailcat_applied_without_restart",
			host: PreflightHost{
				Generation: oldGen, AppliedGeneration: &savedGen, Version: "test", Ready: true,
				Assistants: map[string]bool{"codex": true}, Networks: map[string]bool{"tailcat": true},
			},
			wantRestartNeeded: false,
		},
		{
			name: "unapplied_config_edit_sets_restart_required",
			host: PreflightHost{
				Generation: oldGen, AppliedGeneration: &empty, Version: "test", Ready: true,
				Assistants: map[string]bool{"codex": true}, Networks: map[string]bool{"lan": true},
			},
			wantRestartNeeded: true,
		},
		{
			name: "legacy_daemon_generation_mismatch",
			host: PreflightHost{
				Generation: oldGen, Version: "test", Ready: true,
				Assistants: map[string]bool{"codex": true}, Networks: map[string]bool{"lan": true},
			},
			wantRestartNeeded: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			yes := true
			report := InspectPreflight(t.Context(), PreflightOptions{Stage: "pair", ConfigPath: path, Version: "test"}, PreflightProbes{
				Platform: "linux",
				Host: func(context.Context, config.Config) (PreflightHost, error) {
					return tc.host, nil
				},
				Member: func(_ context.Context, id string, _ config.Config, _ string, _ PreflightHost) PreflightObservation {
					if id == "assistant_codex" || id == "network_lan" || id == "network_tailcat" {
						return PreflightObservation{Available: &yes}
					}
					return PreflightObservation{Code: "probe_timeout"}
				},
			}, nil)
			if report.ConfigRestartRequired != tc.wantRestartNeeded {
				t.Fatalf("ConfigRestartRequired=%v, want %v", report.ConfigRestartRequired, tc.wantRestartNeeded)
			}
		})
	}
}
