package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestFivePairingRoutesNegotiateErrors(t *testing.T) {
	s := newTestServer(t)
	for _, tc := range []struct {
		path, method, body string
		bearer             bool
		status             int
		legacy, code, step string
	}{
		{"/api/pair/claim", "POST", `{}`, false, 401, `{"error":"配对票据缺少必要字段"}`, "pair_ticket_invalid", "network_any"},
		{"/api/pair/local", "POST", "", false, 403, `{"error":"本机自动配对仅允许 Mimi Mac 客户端通过 loopback 发起"}`, "pair_local_forbidden", "service_daemon"},
		{managedPairingLinkPath, "POST", `{}`, false, 401, `{"error":"unauthorized"}`, "pair_token_mismatch", "service_daemon"},
		{tailcatActivationPath, "DELETE", "", true, 405, `{"error":"method not allowed"}`, "invalid_request", "network_any"},
		{"/api/tailcat/free-route", "POST", `{"client_key":"wrong"}`, true, 400, `{"error":"设备公钥无效"}`, "invalid_request", "network_any"},
		{tailcatActivationPath + "/missing", "GET", "", true, 404, `{"code":"tailcat_operation_expired","error":"启用记录已过期，请重试"}`, "tailcat_relay_unreachable", "network_tailcat"},
	} {
		t.Run(tc.path, func(t *testing.T) {
			for _, accept := range []string{"", "application/json", "*/*", pairingErrorMediaType + ";q=0", pairingErrorMediaType} {
				req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
				if tc.bearer {
					req.Header.Set("Authorization", "Bearer "+testToken)
				}
				req.Header.Set("Accept", accept)
				rec := httptest.NewRecorder()
				s.handler.ServeHTTP(rec, req)
				if rec.Code != tc.status || rec.Header().Get("Vary") != "Accept" {
					t.Fatalf("accept=%q status=%d vary=%q body=%s", accept, rec.Code, rec.Header().Get("Vary"), rec.Body)
				}
				if tc.path == managedPairingLinkPath && rec.Header().Get("WWW-Authenticate") != "Bearer" {
					t.Fatal("missing Bearer challenge")
				}
				if accept != pairingErrorMediaType {
					if rec.Body.String() != tc.legacy+"\n" || rec.Header().Get("Content-Type") != "application/json; charset=utf-8" {
						t.Fatalf("legacy response %q %s", rec.Header().Get("Content-Type"), rec.Body)
					}
					continue
				}
				assertPairingDiagnostic(t, rec, tc.code, tc.step)
			}
		})
	}
}

func assertPairingDiagnostic(t *testing.T, rec *httptest.ResponseRecorder, code, step string) {
	t.Helper()
	var envelope struct {
		OK    *bool                 `json:"ok"`
		Error setup.OnboardingError `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	want := setup.OnboardingDiagnostic(code, step, "pair", true, "")
	if envelope.OK == nil || *envelope.OK || envelope.Error != want || envelope.Error.Code != code || rec.Header().Get("Content-Type") != pairingErrorMediaType {
		t.Fatalf("unexpected response %q %s", rec.Header().Get("Content-Type"), rec.Body)
	}
}

func TestPairingNegotiationPreservesSuccessfulResponses(t *testing.T) {
	for _, path := range []string{"/api/pair/claim", "/api/pair/local", managedPairingLinkPath, tailcatActivationPath, "/api/tailcat/free-route"} {
		t.Run(path, func(t *testing.T) {
			next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Cache-Control", "no-store")
				writeJSON(w, http.StatusAccepted, map[string]string{"state": "pending"})
				w.(http.Flusher).Flush()
			})
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, path, nil)
			req.Header.Set("Accept", pairingErrorMediaType)
			negotiatePairingErrors(next).ServeHTTP(rec, req)
			if rec.Code != http.StatusAccepted || rec.Body.String() != "{\"state\":\"pending\"}\n" ||
				rec.Header().Get("Content-Type") != "application/json; charset=utf-8" || rec.Header().Get("Vary") != "Accept" ||
				rec.Header().Get("Cache-Control") != "no-store" || !rec.Flushed {
				t.Fatalf("unexpected success: %d %v %s", rec.Code, rec.Header(), rec.Body)
			}
		})
	}
}

func TestPairingNegotiationClassifiesAuthenticatedTimes(t *testing.T) {
	s := newTestServer(t)
	now := time.Now()
	for _, tc := range []struct {
		issued, expires time.Duration
		code            string
	}{
		{-time.Hour, -time.Second, "pair_ticket_expired"},
		{3 * time.Minute, 5 * time.Minute, "pair_clock_skew"},
	} {
		ticket := auth.NewPairingTicket("http://pair.example.invalid", testToken, now.Add(tc.issued), now.Add(tc.expires))
		req := pairingClaimHTTPRequest(t, pairingClaimRequest{
			Endpoint: ticket.Endpoint, IssuedAt: ticket.IssuedAt, ExpiresAt: ticket.ExpiresAt, Signature: ticket.Signature,
		})
		req.Header.Set("Accept", pairingErrorMediaType)
		rec := httptest.NewRecorder()
		s.handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("unexpected status %d", rec.Code)
		}
		assertPairingDiagnostic(t, rec, tc.code, "network_any")
	}
}

func TestUnauthenticatedTicketTimeKeepsLegacyBody(t *testing.T) {
	s := newPairingTestServer(t)
	now := time.Now()
	ticket := auth.NewPairingTicket(localPairingEndpoint, "unrecognized-key", now.Add(-time.Hour), now.Add(-time.Minute))
	for _, accept := range []string{"application/json", pairingErrorMediaType} {
		req := pairingClaimHTTPRequest(t, pairingClaimRequest{Endpoint: ticket.Endpoint, IssuedAt: ticket.IssuedAt, ExpiresAt: ticket.ExpiresAt, Signature: ticket.Signature})
		req.Header.Set("Accept", accept)
		rec := httptest.NewRecorder()
		s.handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("status %d", rec.Code)
		}
		if accept == pairingErrorMediaType {
			assertPairingDiagnostic(t, rec, "pair_ticket_invalid", "network_any")
		} else if rec.Body.String() != "{\"error\":\"配对二维码已过期\"}\n" {
			t.Fatalf("legacy body %q", rec.Body.String())
		}
	}
}

func TestPairingNegotiationCoversOuterBodyLimit(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/pair/claim", nil)
	req.Header.Set("Accept", pairingErrorMediaType)
	req.ContentLength = pairingRequestBodyMaxBytes + 1
	rec := httptest.NewRecorder()
	s.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("unexpected status %d", rec.Code)
	}
	assertPairingDiagnostic(t, rec, "invalid_request", "network_any")
}

func TestLegacyTailcatClaimPreservesPublicReasonAndRedactsPrivateDetail(t *testing.T) {
	for _, tc := range []struct{ input, want string }{
		{"pairing_grant_invalid", "pairing_grant_invalid"},
		{"fixture-private-detail", "Tailcat 连接尚未就绪"},
	} {
		rec := httptest.NewRecorder()
		writeTailcatClaimFailure(rec, &managedCloudError{Code: "pairing_grant_invalid", Message: tc.input})
		if rec.Code != http.StatusServiceUnavailable || rec.Body.String() != "{\"error\":\""+tc.want+"\"}\n" {
			t.Fatalf("unexpected legacy response %d %q", rec.Code, rec.Body.String())
		}
	}
}
