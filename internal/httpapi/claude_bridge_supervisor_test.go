package httpapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestResidentAdapterReportsStartupExit(t *testing.T) {
	bin := copyFakeBridge(t, t.TempDir(), "early-exit")
	for _, tc := range []struct {
		name          string
		newSupervisor func() *claudeBridgeSupervisor
	}{
		{"Claude", newClaudeBridgeSupervisor},
		{"Antigravity", newAgyAdapterSupervisor},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := tc.newSupervisor()
			t.Cleanup(s.shutdown)
			started := time.Now()
			_, err := s.ensure(bin, []string{"--unsupported-test-option"}, nil)
			if err == nil || !strings.Contains(err.Error(), "启动后立即退出") {
				t.Fatalf("early exit error = %v", err)
			}
			if elapsed := time.Since(started); elapsed >= claudeBridgeStartTimeout {
				t.Fatalf("early exit took the whole startup budget: %v", elapsed)
			}
			if _, err := s.ensure(bin, nil, nil); err != nil {
				t.Fatalf("start after early exit: %v", err)
			}
		})
	}
}

func TestResidentAdapterConcurrentSlowStartAndReplacement(t *testing.T) {
	dir := t.TempDir()
	bin := copyFakeBridge(t, dir, "slow-bridge")
	startLog := filepath.Join(dir, "starts")
	args := []string{"--start-log", startLog, "--listen-delay", "100ms"}
	s := newClaudeBridgeSupervisor()
	t.Cleanup(s.shutdown)

	const callers = 6
	start := make(chan struct{})
	results := make(chan error, callers)
	for range callers {
		go func() {
			<-start
			_, err := s.ensure(bin, args, nil)
			results <- err
		}()
	}
	close(start)
	for range callers {
		if err := <-results; err != nil {
			t.Fatalf("shared slow start: %v", err)
		}
	}
	assertStarts := func(want string) {
		t.Helper()
		got, err := os.ReadFile(startLog)
		if err != nil || string(got) != want {
			t.Fatalf("launch log = %q, %v; want %q", got, err, want)
		}
	}
	assertStarts("start\n")

	oldDone := s.done
	terminateGatewayProcessGroup(s.cmd, true)
	select {
	case <-oldDone:
	case <-time.After(10 * time.Second):
		t.Fatal("old bridge was not reaped")
	}
	if _, err := s.ensure(bin, args, nil); err != nil {
		t.Fatalf("replace exited bridge: %v", err)
	}
	if s.done == oldDone || s.runningSince() == nil {
		t.Fatal("replacement did not publish a live generation")
	}
	conn, _, err := s.dial()
	if err != nil {
		t.Fatalf("dial replacement: %v", err)
	}
	_ = conn.Close()
	assertStarts("start\nstart\n")
}
