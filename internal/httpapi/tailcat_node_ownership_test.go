package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTailcatNodeOwnershipRequiresComputerBearer(t *testing.T) {
	server, _, _ := newLinkTestServer(t)
	const path = "/api/tailcat/node-ownership-proof"
	for _, suffix := range []string{"", "?token=test-token"} {
		response := httptest.NewRecorder()
		server.handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, path+suffix, strings.NewReader("{}")))
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("without Bearer: %d", response.Code)
		}
	}
	response := httptest.NewRecorder()
	server.handler.ServeHTTP(response, authedRequest(t, http.MethodPost, path, map[string]string{}))
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), "更新电脑端") {
		t.Fatalf("unsupported helper should give next step: %d %s", response.Code, response.Body.String())
	}
}
