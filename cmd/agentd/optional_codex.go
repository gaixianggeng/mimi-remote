package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	"github.com/gorilla/websocket"
)

const codexSSHRetryDelay = 5 * time.Second

var errCodexUnavailable = errors.New("Codex app-server 暂不可用")

type optionalCodex struct {
	ctx      context.Context
	cancel   context.CancelFunc
	stop     sync.Once
	retrySSH bool
	prepare  func(context.Context) (*agentAppServerRuntime, error)

	mu      sync.Mutex
	done    chan struct{} // closed when the latest attempt has published its result
	retryAt time.Time
	runtime *agentAppServerRuntime
}

func startOptionalCodex(parent context.Context, cfg config.Config, configPath string) *optionalCodex {
	prepare := func(ctx context.Context) (*agentAppServerRuntime, error) {
		if err := resolveLaunchCodex(ctx, &cfg); err != nil {
			log.Print("Codex CLI unavailable")
			return nil, err
		}
		frontDoor, err := prepareMacAppCodexFront(cfg, configPath)
		if err != nil {
			log.Print("Codex front door unavailable")
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		r, err := prepareAgentAppServerRuntimeWithFrontDoor(ctx, cfg, frontDoor)
		if err != nil && ctx.Err() == nil {
			log.Print("Codex upstream unavailable")
		}
		return r, err
	}
	return newOptionalCodex(parent, strings.EqualFold(strings.TrimSpace(cfg.AppServer.Transport), "ssh"), prepare)
}

func newOptionalCodex(parent context.Context, retrySSH bool, prepare func(context.Context) (*agentAppServerRuntime, error)) *optionalCodex {
	ctx, cancel := context.WithCancel(parent)
	s := &optionalCodex{ctx: ctx, cancel: cancel, retrySSH: retrySSH, prepare: prepare}
	s.startPreparation()
	return s
}

// Called before publication or with mu held. Clearing retryAt reserves the
// attempt, so concurrent requests cannot start another check.
func (s *optionalCodex) startPreparation() {
	s.done = make(chan struct{})
	s.retryAt = time.Time{}
	go func() {
		r, err := s.prepare(s.ctx)
		s.mu.Lock()
		defer s.mu.Unlock()
		s.runtime = r
		if err != nil && s.retrySSH {
			s.retryAt = time.Now().Add(codexSSHRetryDelay)
		}
		close(s.done)
	}()
}

func (s *optionalCodex) transport() (httpapi.AppServerTransport, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ctx.Err() != nil {
		return nil, errCodexUnavailable
	}
	if r := s.runtime; r != nil && r.transport != nil {
		if r.managedWS != nil {
			select {
			case <-r.managedWS.Done():
				return nil, errors.New("受管 Codex app-server 已退出")
			default:
			}
		}
		return r.transport, nil
	}
	if !s.retryAt.IsZero() && !time.Now().Before(s.retryAt) {
		s.startPreparation()
	}
	return nil, errCodexUnavailable
}

func (s *optionalCodex) EnsureReady(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	// Local and managed runtimes have a single startup attempt. SSH callers
	// observe unavailability immediately while its remote check is running.
	if !s.retrySSH {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
		}
	}
	transport, err := s.transport()
	if err != nil {
		return err
	}
	return transport.EnsureReady(ctx)
}
func (s *optionalCodex) WebSocketURL() (string, error) {
	transport, err := s.transport()
	if err != nil {
		return "", err
	}
	return transport.WebSocketURL()
}
func (s *optionalCodex) WebSocketHeaders() (http.Header, error) {
	transport, err := s.transport()
	if err != nil {
		return nil, err
	}
	return transport.WebSocketHeaders()
}
func (s *optionalCodex) WebSocketDialer(timeout time.Duration) (websocket.Dialer, error) {
	transport, err := s.transport()
	if err != nil {
		return websocket.Dialer{}, err
	}
	return transport.WebSocketDialer(timeout)
}
func (s *optionalCodex) Shutdown() {
	s.stop.Do(func() {
		s.cancel()
		s.mu.Lock()
		done := s.done
		s.mu.Unlock()
		<-done
		if r := s.runtime; r != nil {
			if t, ok := r.transport.(interface{ Shutdown() }); ok {
				t.Shutdown()
			}
			if err := r.shutdown(); err != nil {
				log.Print("Codex app-server shutdown failed")
			}
		}
	})
}
