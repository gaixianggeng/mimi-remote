package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestSharedHostCLIRelayCases(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "contracts", "host-cli", "relay-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		ID      string        `json:"id"`
		Choice  string        `json:"choice"`
		URL     string        `json:"url"`
		Current tailcatStatus `json:"current"`
		Valid   bool          `json:"valid"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		t.Run(tc.ID, func(t *testing.T) {
			server := newTestServer(t)
			fake := &fakeTailcatSidecar{status: tc.Current, configureApplies: true}
			managed := &fakeManagedPairingService{status: tc.Current}
			managed.onConfigureMode = func(bool) { fake.status.Mode = config.TailcatModeManaged }
			managed.onConfigureRelay = func(ctx context.Context, url string) (tailcatStatus, error) {
				return fake.ConfigureRelay(ctx, url, func() error { return nil })
			}
			server.router.tailcat = fake
			server.router.managedPairing = managed
			response := tailcatRelaySetResponse(t, server, tc.Choice, tc.URL)
			want := http.StatusBadRequest
			if tc.Valid {
				want = http.StatusOK
			}
			if response.Code != want {
				t.Fatalf("expected %d, got %d: %s", want, response.Code, response.Body.String())
			}
			if !tc.Valid && (fake.configureCalls != 0 || fake.startCalls != 0 || managed.relayCalls != 0 || managed.modeCalls != 0) {
				t.Fatal("非法中转输入不应启动或修改连接")
			}
		})
	}
}
