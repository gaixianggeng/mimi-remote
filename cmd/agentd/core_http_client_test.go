package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestManagedEnrichmentRefusesForeignPeerBeforeBearer(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	fakeCoreManager(t, "", func(string, string) error { t.Fatal("unexpected action"); return nil })
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		io.WriteString(w, "{\"runtimes\":[]}")
	}))
	defer srv.Close()
	path := config.PlatformDefaultPath()
	if !isManagedCoreConfig(filepath.Join(filepath.Dir(path), ".", filepath.Base(path))) {
		t.Fatal("missed platform default")
	}
	if _, err := fetchServiceRuntimeStatus(context.Background(), srv.URL, "fixture-credential", time.Second, false, path); err == nil {
		t.Fatal("foreign runtime accepted")
	}
	if _, state := fetchModuleStatusForCommand(srv.URL, "fixture-credential", path); state != moduleStatusUnavailable {
		t.Fatalf("foreign modules: %s", state)
	}
	if calls.Load() != 0 {
		t.Fatal("foreign peer received a credential")
	}
	if _, err := fetchServiceRuntimeStatus(context.Background(), srv.URL, "fixture-credential", time.Second, false, filepath.Join(t.TempDir(), "foreground.json")); err != nil || calls.Load() != 1 {
		t.Fatalf("custom foreground status: %v", err)
	}
}

func TestRuntimeStatusRefusesLoopbackRedirect(t *testing.T) {
	var redirected atomic.Int32
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		redirected.Add(1)
		io.WriteString(w, "{\"runtimes\":[]}")
	}))
	defer other.Close()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, other.URL, http.StatusFound) }))
	defer srv.Close()
	_, err := fetchServiceRuntimeStatus(context.Background(), srv.URL, "fixture-credential", time.Second, false, "")
	if err == nil || redirected.Load() != 0 {
		t.Fatalf("redirect followed: err=%v calls=%d", err, redirected.Load())
	}
}

func TestRestartDoesNotReusePriorPID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture" {
			w.WriteHeader(401)
			return
		}
		io.WriteString(w, "{\"ok\":true,\"version\":\"1\"}")
	}))
	defer srv.Close()
	var submits int
	fakeCoreManager(t, "gui", func(string, string) error { submits++; return nil })
	inspectCorePeer = func(context.Context, string, net.Conn) (coreServiceOwner, error) {
		return coreServiceOwner{manager: "gui", pid: 123}, nil
	}
	err := manageCoreService(context.Background(), "darwin", "restart", srv.URL, "fixture", "1", 25*time.Millisecond, io.Discard, io.Discard)
	var typed *onboardingCommandError
	if submits != 1 || !errors.As(err, &typed) || typed.code != "service_start_timeout" {
		t.Fatalf("submits=%d err=%v", submits, err)
	}
}

func TestManagerSubmissionObservesCancellation(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("launchctl command fixture uses Unix shell")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	old := coreLaunchctl
	coreLaunchctl = filepath.Join(t.TempDir(), "never-executed")
	t.Cleanup(func() { coreLaunchctl = old })
	if err := platformCoreAction(ctx, "darwin", "gui", "restart", io.Discard, io.Discard); !errors.Is(err, context.Canceled) {
		t.Fatalf("submission should be canceled: %v", err)
	}
}
