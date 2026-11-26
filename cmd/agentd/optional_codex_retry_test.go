package main

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

func TestOptionalCodexRetriesSSHPreparationOnDemand(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var attempts atomic.Int32
		reachable := make(chan struct{})
		s := newOptionalCodex(t.Context(), true, func(ctx context.Context) (*agentAppServerRuntime, error) {
			if attempts.Add(1) == 1 {
				return nil, errors.New("SSH offline")
			}
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-reachable:
				transport, err := appserver.NewSSHTransport(appserver.SSHTransportOptions{Target: "fixture.invalid"})
				return &agentAppServerRuntime{transport: transport}, err
			}
		})
		defer s.Shutdown()
		synctest.Wait()
		unavailable := func() {
			t.Helper()
			if url, err := s.WebSocketURL(); url != "" || !errors.Is(err, errCodexUnavailable) {
				t.Errorf("pending URL = %q, error = %v", url, err)
			}
			if err := s.EnsureReady(t.Context()); !errors.Is(err, errCodexUnavailable) {
				t.Errorf("pending readiness error = %v", err)
			}
		}

		time.Sleep(codexSSHRetryDelay - time.Nanosecond)
		unavailable()
		synctest.Wait()
		if got := attempts.Load(); got != 1 {
			t.Fatalf("attempts during backoff = %d", got)
		}
		time.Sleep(time.Hour)
		if got := attempts.Load(); got != 1 {
			t.Fatalf("attempts without a request = %d", got)
		}

		var callers sync.WaitGroup
		for range 16 {
			callers.Go(unavailable)
		}
		callers.Wait() // every caller returns while the SSH check is still held
		synctest.Wait()
		if got := attempts.Load(); got != 2 {
			t.Fatalf("concurrent requests started %d total attempts, want 2", got)
		}
		close(reachable)
		synctest.Wait()
		time.Sleep(time.Hour)
		if url, err := s.WebSocketURL(); err != nil || url != appserver.CodexAppServerWebSocketURL {
			t.Fatalf("recovered URL = %q, error = %v", url, err)
		}
		synctest.Wait()
		if got := attempts.Load(); got != 2 {
			t.Fatalf("reprepared a healthy transport: %d attempts", got)
		}
	})
}

func TestOptionalCodexShutdownCancelsSSHRetry(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var attempts atomic.Int32
		stopped := make(chan struct{})
		s := newOptionalCodex(t.Context(), true, func(ctx context.Context) (*agentAppServerRuntime, error) {
			if attempts.Add(1) == 1 {
				return nil, errors.New("SSH offline")
			}
			<-ctx.Done()
			close(stopped)
			return nil, ctx.Err()
		})
		synctest.Wait()
		time.Sleep(codexSSHRetryDelay)
		if err := s.EnsureReady(t.Context()); !errors.Is(err, errCodexUnavailable) {
			t.Fatalf("readiness during retry = %v", err)
		}
		s.Shutdown()
		select {
		case <-stopped:
		default:
			t.Fatal("shutdown returned before the retry stopped")
		}
		time.Sleep(codexSSHRetryDelay)
		if _, err := s.WebSocketURL(); !errors.Is(err, errCodexUnavailable) {
			t.Fatalf("URL after shutdown: %v", err)
		}
		synctest.Wait()
		if got := attempts.Load(); got != 2 {
			t.Fatalf("attempts after shutdown = %d", got)
		}
	})
}
