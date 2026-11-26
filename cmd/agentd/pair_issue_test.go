package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

const issueTestToken = "0123456789abcdef0123456789abcdef"

func issueClientConfig(t *testing.T, server *httptest.Server) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	writeIssueClientConfig(t, server, path)
	return path
}

func writeIssueClientConfig(t *testing.T, server *httptest.Server, path string) {
	t.Helper()
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(map[string]any{"listen": server.Listener.Addr().String(), "auth": map[string]string{"token": issueTestToken}})
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, path, raw)
	if err := os.Mkdir(filepath.Join(dir, "tailcat"), 0o700); err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, filepath.Join(dir, "tailcat", "local-control.token"), []byte("test-local-control"))
}

func writeIssuedFixture(t *testing.T, w http.ResponseWriter, r *http.Request, host string, tailcat, managed bool) {
	t.Helper()
	var request struct{ Network, Version, Generation string }
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		t.Error(err)
		return
	}
	if r.URL.Path != "/api/local/pair/issue" || r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer "+issueTestToken || r.Header.Get("X-Mimi-Tailcat-Local-Control") != "test-local-control" || request.Version != version || len(request.Generation) != 64 {
		t.Error("pair command did not use the authenticated local issuer for the saved version and generation")
		return
	}
	_, port, err := net.SplitHostPort(r.Host)
	if err != nil {
		t.Error(err)
		return
	}
	network := agentsetup.PairingNetworkLAN
	endpoint := "http://" + net.JoinHostPort(host, port)
	q := url.Values{}
	if tailcat {
		if request.Network != "tailcat" {
			t.Errorf("selected network %q", request.Network)
		}
		network = agentsetup.PairingNetworkTailcat
		endpoint = "http://127.0.0.1:8787"
		q.Set("transport", "tailcat")
		q.Set("tailcat_pair_address", "test-address")
		if managed {
			q.Set("managed_mac_installation_id", "test-installation")
			q.Set("managed_mac_tailcat_public_key", "nodekey:"+strings.Repeat("a", 64))
			q.Set("managed_pair_tailcat_public_key", "nodekey:"+strings.Repeat("b", 64))
		}
	} else if request.Network != "auto" {
		t.Errorf("selected network %q", request.Network)
	}
	now := time.Now()
	ticket := auth.NewPairingTicket(endpoint, issueTestToken, now, now.Add(time.Minute))
	q.Set("endpoint", endpoint)
	q.Set("issued_at", ticket.IssuedAt)
	q.Set("expires_at", ticket.ExpiresAt)
	q.Set("pair_sig", ticket.Signature)
	_ = json.NewEncoder(w).Encode(agentsetup.Result{
		Token: issueTestToken, Network: network, Endpoint: endpoint,
		PairURL: "mimiremote://pair?" + q.Encode(), PairIssuedAt: ticket.IssuedAt, PairExpiresAt: ticket.ExpiresAt,
	})
}

func TestDirectPairCLIRejectsUndialableAndRedirectedIssuance(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	var visits atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { visits.Add(1) }))
	defer target.Close()
	for _, host := range []string{"127.0.0.1", "0.0.0.0", "redirect"} {
		t.Run(host, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if host == "redirect" {
					http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
					return
				}
				writeIssuedFixture(t, w, r, host, false, false)
			}))
			defer server.Close()
			path := issueClientConfig(t, server)
			var output, stderr strings.Builder
			if err := runPairWithWriters([]string{"pair", "--config", path, "--json", "--qr-only"}, &output, &stderr); err == nil || output.Len() != 0 {
				t.Errorf("unusable result reached CLI: %v %q", err, output.String())
			}
		})
	}
	if visits.Load() != 0 {
		t.Fatal("pair issuer followed a redirect")
	}
}

func TestServeUsesAuthenticatedForegroundIssuerAtDefaultConfig(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	fakeCoreManager(t, "", func(string, string) error { t.Fatal("unexpected manager action"); return nil })
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		writeIssuedFixture(t, w, r, "192.168.50.2", false, false)
	}))
	defer server.Close()
	path := config.PlatformDefaultPath()
	writeIssueClientConfig(t, server, path)
	_, err := requestPairIssue(t.Context(), path, agentsetup.PairingNetworkAuto)
	var issue *onboardingCommandError
	if !errors.As(err, &issue) || issue.code != "service_port_in_use" || calls.Load() != 0 {
		t.Fatalf("managed path: err=%v HTTP calls=%d", err, calls.Load())
	}
	_, err = requestPairIssueWithDial(context.Background(), path, agentsetup.PairingNetworkAuto, coreDialForOwner(false))
	if err != nil || calls.Load() != 1 {
		t.Fatalf("foreground serve: err=%v HTTP calls=%d", err, calls.Load())
	}
}
