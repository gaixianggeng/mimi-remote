//go:build windows

package httpapi

import (
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestWindowsTailcatSidecarExitUsesControlShutdown(t *testing.T) {
	var shutdowns atomic.Int32
	socket := startFakeTailcatControl(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodPost && req.URL.Path == "/shutdown" {
			shutdowns.Add(1)
			writeJSON(w, http.StatusAccepted, map[string]bool{"stopping": true})
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	supervisor := &tailcatSidecarSupervisor{controlPath: socket}
	if !supervisor.requestSidecarExit(nil) || shutdowns.Load() != 1 {
		t.Fatalf("Windows stop must ask the helper to shut down over the control socket, calls=%d", shutdowns.Load())
	}
}

func TestWindowsTailcatSidecarExitRejectsHelperWithoutShutdown(t *testing.T) {
	socket := startFakeTailcatControl(t, http.NotFoundHandler())
	supervisor := &tailcatSidecarSupervisor{controlPath: socket}
	if supervisor.requestSidecarExit(nil) {
		t.Fatal("a helper without /shutdown must be terminated instead of waiting for a grace period")
	}
}

func TestWindowsTailcatSidecarStopTerminatesUnreachableHelperPromptly(t *testing.T) {
	ping := filepath.Join(os.Getenv("SystemRoot"), "System32", "PING.EXE")
	cmd := exec.Command(ping, "-n", "60", "127.0.0.1")
	prepareTailcatSidecarProcess(cmd)
	if err := startTailcatSidecarProcess(cmd); err != nil {
		t.Fatalf("start helper stand-in: %v", err)
	}
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		releaseTailcatSidecarProcess(cmd)
		close(done)
	}()
	supervisor := &tailcatSidecarSupervisor{controlPath: filepath.Join(t.TempDir(), "missing.sock")}
	started := time.Now()
	if err := supervisor.stopProcess(t.Context(), cmd, done); err != nil {
		t.Fatalf("stop helper: %v", err)
	}
	if elapsed := time.Since(started); elapsed >= tailcatSidecarStopGrace {
		t.Fatalf("unreachable helper waited %s instead of being terminated immediately", elapsed)
	}
	select {
	case <-done:
	default:
		t.Fatal("helper process is still running after stop")
	}
}
