//go:build windows

package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gorilla/websocket"
	"golang.org/x/sys/windows"
)

// Only children launched with this fixture's explicit codex.env override enter
// this branch. This makes the native test executable a hermetic Codex stand-in.
func init() {
	if dir := os.Getenv("MIMI_TEST_CODEX_EXIT_DIR"); dir != "" {
		os.Exit(runManagedChildFixture(os.Args[1:], dir))
	}
}

func runManagedChildFixture(args []string, dir string) int {
	if slices.Equal(args, []string{"--version"}) {
		fmt.Println("codex-cli 0.150.0")
		return 0
	}
	if slices.Equal(args, []string{"app-server", "--help"}) {
		fmt.Println("--listen --ws-auth --ws-token-file")
		return 0
	}
	listen, tokenIndex := slices.Index(args, "--listen"), slices.Index(args, "--ws-token-file")
	if listen < 0 || listen+1 >= len(args) || tokenIndex < 0 || tokenIndex+1 >= len(args) {
		return 2
	}
	if os.Getenv("MIMI_TEST_CODEX_EXIT_PHASE") == "initialized" {
		// A completed initialize/initialized exchange proves the agent's actual
		// managed transport passed its startup handshake before this process exits.
		token, err := os.ReadFile(args[tokenIndex+1])
		if err != nil {
			return 3
		}
		listener, err := net.Listen("tcp4", strings.TrimPrefix(args[listen+1], "ws://"))
		if err != nil {
			return 4
		}
		initialized := make(chan struct{}, 1)
		server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer "+strings.TrimSpace(string(token)) {
				http.Error(w, "forbidden", 403)
				return
			}
			up := websocket.Upgrader{}
			conn, err := up.Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer conn.Close()
			var frame struct{ Method string }
			if conn.ReadJSON(&frame) != nil || frame.Method != "initialize" {
				return
			}
			if conn.WriteJSON(map[string]any{"id": 1, "result": map[string]any{}}) != nil {
				return
			}
			if conn.ReadJSON(&frame) == nil && frame.Method == "initialized" {
				select {
				case initialized <- struct{}{}:
				default:
				}
			}
		})}
		go server.Serve(listener)
		defer server.Close()
		select {
		case <-initialized:
		case <-time.After(20 * time.Second):
			return 5
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "child.pid"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
		return 6
	}
	for stop := time.Now().Add(20 * time.Second); time.Now().Before(stop); {
		if _, err := os.Stat(filepath.Join(dir, "exit")); err == nil {
			return 17
		}
		time.Sleep(10 * time.Millisecond)
	}
	return 7
}

func TestWindowsManagedChildExitPreservesCore(t *testing.T) {
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, phase := range []string{"before-listen", "initialized"} {
		t.Run(phase, func(t *testing.T) {
			dir := t.TempDir()
			for _, key := range []string{"USERPROFILE", "APPDATA", "LOCALAPPDATA", "HOME"} {
				t.Setenv(key, dir)
			}
			t.Setenv("AGENTD_CODEX_BIN", "")
			t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", filepath.Join(dir, "uploads"))
			// Reserve both ports together so the control and upstream sockets are distinct.
			core, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer core.Close()
			upstream, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer upstream.Close()
			disabled := false
			cfg := config.Config{
				Listen:    core.Addr().String(),
				Auth:      config.AuthConfig{Token: "fixture-control-secret-0123456789"},
				Network:   config.NetworkConfig{AllowTailscale: &disabled},
				AppServer: config.AppServerConfig{Transport: "ws", Managed: true, Listen: "ws://" + upstream.Addr().String(), WSTokenFile: filepath.Join(dir, "ws-token")},
				Codex:     config.CodexConfig{Bin: binary, Env: map[string]string{"MIMI_TEST_CODEX_EXIT_DIR": dir, "MIMI_TEST_CODEX_EXIT_PHASE": phase, "GORACE": "atexit_sleep_ms=0"}},
			}
			configtest.CreatePrivateFile(t, cfg.AppServer.WSTokenFile, []byte("fixture-ws-secret-0123456789"))
			registry, err := projects.NewRegistry(nil)
			if err != nil {
				t.Fatal(err)
			}
			checker := doctor.NewChecker(version, cfg, registry)
			stop, err := windowsManagedStopPath()
			if err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Dir(stop), 0700); err != nil {
				t.Fatal(err)
			}
			core.Close()
			upstream.Close()
			var serveErr error
			stopped := make(chan struct{})
			go func() { serveErr = serve(cfg, registry, checker, nil); close(stopped) }()
			release := func() {
				if err := os.WriteFile(filepath.Join(dir, "exit"), nil, 0600); err != nil {
					t.Error(err)
				}
			}
			t.Cleanup(func() {
				release()
				if err := os.WriteFile(stop, nil, 0600); err != nil {
					t.Error(err)
				}
				select {
				case <-stopped:
					if serveErr != nil {
						t.Errorf("child failure propagated to serve: %v", serveErr)
					}
				case <-time.After(12 * time.Second):
					t.Error("fixture service did not stop")
				}
			})
			// The helper reports PID before exiting. Hold a process handle until
			// Windows signals its actual death, independently of agentd's reaper.
			pid := 0
			for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); {
				select {
				case <-stopped:
					t.Fatalf("serve exited before child: %v", serveErr)
				default:
				}
				raw, _ := os.ReadFile(filepath.Join(dir, "child.pid"))
				pid, _ = strconv.Atoi(string(raw))
				if pid > 0 {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			if pid <= 0 {
				t.Fatal("fixture child did not reach the requested phase")
			}
			process, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
			if err != nil {
				t.Fatal(err)
			}
			defer windows.CloseHandle(process)
			checkReady := func() {
				t.Helper()
				ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
				defer cancel()
				if err := waitForServiceReady(ctx, "http://"+cfg.Listen, cfg.Auth.Token, version, 2*time.Second); err != nil {
					t.Fatalf("authenticated core is unavailable: %v", err)
				}
			}
			checkReady()
			release()
			result, err := windows.WaitForSingleObject(process, 5000)
			if err != nil || result != windows.WAIT_OBJECT_0 {
				t.Fatalf("managed child did not exit: result=%v err=%v", result, err)
			}
			checkReady()
		})
	}
}
