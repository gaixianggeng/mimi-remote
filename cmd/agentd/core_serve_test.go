package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func unusedCoreTestAddress(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}

func TestCoreServeHelper(t *testing.T) {
	if os.Getenv("MIMI_TEST_SERVE_CORE") != "1" {
		return
	}
	inspectLegacyCodexExperimentResidue = func() (string, error) { return "", nil }
	if err := runServe([]string{"serve", "--config", config.PlatformDefaultPath()}); err != nil {
		t.Fatal(err)
	}
}

func TestUpNoPairWaitsForCoreWithOptionalDependenciesOffline(t *testing.T) {
	for _, tc := range []struct {
		name, transport     string
		codex, mountMissing bool
	}{
		{"zero assistants", "ssh", false, false}, {"only SSH offline", "ssh", true, false},
		{"enabled missing CLI", "local", true, false}, {"vanished mount", "ssh", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			isolateOnboardingCommandEnv(t)
			prepareBrewSideEffectProbe(t)
			inspect := inspectLegacyCodexExperimentResidue
			inspectLegacyCodexExperimentResidue = func() (string, error) { return "", nil }
			t.Cleanup(func() { inspectLegacyCodexExperimentResidue = inspect })
			root := filepath.Join(t.TempDir(), "workspace")
			if !tc.mountMissing {
				if err := os.Mkdir(root, 0700); err != nil {
					t.Fatal(err)
				}
			}
			path := config.PlatformDefaultPath()
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				t.Fatal(err)
			}
			upstream := map[string]any{"transport": tc.transport}
			if tc.transport == "ssh" {
				upstream["ssh_target"] = "fixture.invalid"
			} else if config.SupportsManagedAppServer() {
				tokenFile := filepath.Join(filepath.Dir(path), "fixture-ws-token")
				configtest.CreatePrivateFile(t, tokenFile, []byte("fixture-upstream-secret"))
				upstream = map[string]any{"transport": "ws", "managed": true, "listen": "ws://" + unusedCoreTestAddress(t), "ws_token_file": tokenFile}
			}
			address := unusedCoreTestAddress(t)
			const token = "fixture-core-bearer-0123456789"
			raw, err := json.Marshal(map[string]any{
				"listen": address, "auth": map[string]string{"token": token}, "app_server": upstream,
				"codex":      map[string]any{"enabled": tc.codex, "bin": filepath.Join(t.TempDir(), "missing-codex")},
				"network":    map[string]bool{"allow_tailscale": false, "allow_lan": false},
				"scan_roots": []string{root}, "browse_roots": []string{root},
			})
			if err != nil {
				t.Fatal(err)
			}
			configtest.CreatePrivateFile(t, path, raw)
			var daemonLog bytes.Buffer
			manager := "homebrew"
			if managedServicePlatform == "windows" {
				manager = "scheduled-task"
			}
			fakeCoreManager(t, manager, func(_ string, action string) error {
				if action != "start" {
					t.Fatal(action)
				}
				exe, err := os.Executable()
				if err != nil {
					return err
				}
				cmd := exec.Command(exe, "-test.run=^TestCoreServeHelper$")
				cmd.Env = append(os.Environ(), "MIMI_TEST_SERVE_CORE=1")
				cmd.Stdout, cmd.Stderr = &daemonLog, &daemonLog
				if err = cmd.Start(); err == nil {
					t.Cleanup(func() {
						_ = cmd.Process.Kill()
						_ = cmd.Wait()
						if t.Failed() {
							t.Log(daemonLog.String())
						}
					})
				}
				return err
			})
			var output bytes.Buffer
			if err = runUpWithWriters([]string{"up", "--no-pair", "--json", "--wait=12s"}, &output, io.Discard); err != nil {
				t.Fatal(err)
			}
			var receipt struct {
				OK        bool
				ServiceOK bool `json:"service_ok"`
				Version   string
			}
			if json.Unmarshal(output.Bytes(), &receipt) != nil || !receipt.OK || !receipt.ServiceOK || receipt.Version != version {
				t.Fatal("invalid core receipt", output.String())
			}
			cfg := config.ParseSetupDocument(raw).Config
			host, err := setup.FetchPreflightHost(context.Background(), cfg)
			if err != nil || !host.Ready {
				t.Fatalf("passive host readiness: %+v, %v", host, err)
			}
			if _, err := waitForServiceReadyResults(context.Background(), "http://"+address, "wrong-"+token, version, time.Nanosecond); err == nil {
				t.Fatal("wrong bearer accepted")
			}
			saved, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(raw, saved) {
				t.Fatal("start changed saved identity or workspace")
			}
		})
	}
}
