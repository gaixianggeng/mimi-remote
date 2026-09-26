package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFetchModuleStatusDistinguishesAvailableUnsupportedAndUnavailable(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
		wantState  moduleStatusFetchState
		wantStatus bool
	}{
		{
			name: "available", statusCode: http.StatusOK,
			body:       `{"codex_enabled":true,"claude_enabled":false,"tailscale_enabled":true,"lan_enabled":false,"tailscale_available":true,"lan_available":true}`,
			wantState:  moduleStatusAvailable,
			wantStatus: true,
		},
		{name: "old daemon", statusCode: http.StatusNotFound, wantState: moduleStatusUnsupported},
		{name: "transient server failure", statusCode: http.StatusServiceUnavailable, wantState: moduleStatusUnavailable},
		{name: "invalid response", statusCode: http.StatusOK, body: `{`, wantState: moduleStatusUnavailable},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(testCase.statusCode)
				_, _ = w.Write([]byte(testCase.body))
			}))
			defer server.Close()

			status, state := fetchModuleStatusForCommand(server.URL, "test-token")
			if state != testCase.wantState || (status != nil) != testCase.wantStatus {
				t.Fatalf("status=%+v state=%q", status, state)
			}
		})
	}
}
