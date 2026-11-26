package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Run a second instance of this test executable from a different file. It
// behaves like a ready HTTP daemon, but should receive no HTTP credentials.
func TestForegroundPeerHelper(t *testing.T) {
	marker := os.Getenv("MIMI_TEST_FOREGROUND_HTTP_MARKER")
	if marker == "" {
		return
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := os.WriteFile(marker, []byte("request"), 0600); err != nil {
			t.Error(err)
		}
		io.WriteString(w, "{\"ok\":true,\"version\":\"test\"}")
	}))
	defer srv.Close()
	fmt.Fprintln(os.Stdout, srv.URL)
	_, _ = io.Copy(io.Discard, os.Stdin)
}

func TestForegroundCredentialRequiresSameExecutable(t *testing.T) {
	dir := t.TempDir()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	copyPath := filepath.Join(dir, "other-agent"+filepath.Ext(self))
	source, err := os.Open(self)
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.OpenFile(copyPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0700)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	_, err = io.Copy(target, source)
	source.Close()
	if closeErr := target.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		t.Fatal(err)
	}
	fixtureCtx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	child := exec.CommandContext(fixtureCtx, copyPath, "-test.run=^TestForegroundPeerHelper$")
	marker := filepath.Join(dir, "received")
	child.Env = append(os.Environ(), "MIMI_TEST_FOREGROUND_HTTP_MARKER="+marker)
	input, err := child.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		input.Close()
		if err := child.Wait(); err != nil {
			t.Error(err)
		}
	}()
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	endpoint := strings.TrimSpace(line)
	cfg := filepath.Join(dir, "foreground.json")
	if _, err := waitForServiceReadyResults(fixtureCtx, endpoint, "fixture-credential", "test", time.Second); err == nil {
		t.Fatal("accepted foreign readyz")
	}
	if _, err := fetchServiceRuntimeStatus(fixtureCtx, endpoint, "fixture-credential", time.Second, false, cfg); err == nil {
		t.Fatal("accepted foreign runtime")
	}
	if _, state := fetchModuleStatusForCommand(endpoint, "fixture-credential", cfg); state != moduleStatusUnavailable {
		t.Fatalf("foreign modules %s", state)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("foreign executable received HTTP request: %v", err)
	}
}

func TestCoreSocketIdentityWaitsOnlyForPendingEvidence(t *testing.T) {
	for _, tc := range []struct {
		name      string
		foundAt   int
		lookupErr error
		wantCalls int
		wantOK    bool
	}{
		{"published after accept", 2, nil, 2, true},
		{"known foreign", 0, errUnknownCoreOwner, 1, false},
		{"never accepted", 0, nil, 4, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			pid, err := waitCoreSocketIdentity(context.Background(), func() (int, error) {
				calls++
				if calls == tc.foundAt {
					return 42, nil
				}
				return 0, tc.lookupErr
			})
			wantErr := tc.lookupErr
			if !tc.wantOK && wantErr == nil {
				wantErr = errCoreOwnerPending
			}
			if calls != tc.wantCalls || (err == nil && pid == 42) != tc.wantOK || !errors.Is(err, wantErr) {
				t.Fatalf("pid=%d err=%v calls=%d", pid, err, calls)
			}
		})
	}
}
