package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
)

const (
	codexRetryMin = time.Second
	codexRetryMax = 30 * time.Second
)

type managedCodexProcess interface {
	Done() <-chan struct{}
	ExitError() error
	Shutdown(context.Context) error
}

// One worker owns startup, retries and the lifetime of each Windows child.
// The HTTP router retains this stable transport while the upstream is replaced.
type codexSupervisor struct {
	mu        sync.RWMutex
	transport httpapi.AppServerTransport
	lastErr   error

	cancel      context.CancelFunc
	done        chan struct{}
	shutdownErr error // published by closing done
}

func startCodexSupervisor(connect func(context.Context) (httpapi.AppServerTransport, error), stopShared func(), retryMin time.Duration) *codexSupervisor {
	ctx, cancel := context.WithCancel(context.Background())
	s := &codexSupervisor{cancel: cancel, done: make(chan struct{}), lastErr: errors.New("Codex app-server 正在启动")}
	go func() {
		defer close(s.done)
		if stopShared != nil {
			defer stopShared()
		}
		s.run(ctx, connect, retryMin)
	}()
	return s
}

func (s *codexSupervisor) run(ctx context.Context, connect func(context.Context) (httpapi.AppServerTransport, error), retryMin time.Duration) {
	delay := retryMin
	for ctx.Err() == nil {
		attempt, cancel := context.WithTimeout(ctx, 25*time.Second)
		transport, err := connect(attempt)
		cancel()
		if err == nil {
			var exited <-chan struct{}
			process, owned := transport.(managedCodexProcess)
			if owned {
				exited = process.Done()
			}
			readyAt := time.Now()
			s.publish(transport, nil)
			log.Print("agentd Codex app-server ready")
			select {
			case <-ctx.Done():
				s.publish(nil, ctx.Err())
				if owned {
					s.shutdownErr = process.Shutdown(context.Background())
				}
				return
			case <-exited:
				err = errors.New("受管 Codex app-server 已退出")
				if exitErr := process.ExitError(); exitErr != nil {
					err = fmt.Errorf("受管 Codex app-server 异常退出：%w", exitErr)
				}
			}
			if time.Since(readyAt) >= codexRetryMax {
				delay = retryMin
			}
		}
		s.publish(nil, err)
		if ctx.Err() != nil {
			return
		}
		log.Printf("agentd Codex app-server unavailable, retry in %s: %v", delay, err)
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		delay = min(2*delay, codexRetryMax)
	}
}

func (s *codexSupervisor) publish(transport httpapi.AppServerTransport, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.transport, s.lastErr = transport, err
}

func (s *codexSupervisor) current() (httpapi.AppServerTransport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.transport, s.lastErr
}

func (s *codexSupervisor) EnsureReady(ctx context.Context) error {
	transport, err := s.current()
	if err != nil {
		return err
	}
	return transport.EnsureReady(ctx)
}

func (s *codexSupervisor) WebSocketURL() (string, error) {
	transport, err := s.current()
	if err != nil {
		return "", err
	}
	return transport.WebSocketURL()
}

func (s *codexSupervisor) WebSocketHeaders() (http.Header, error) {
	transport, err := s.current()
	if err != nil {
		return nil, err
	}
	return transport.WebSocketHeaders()
}

func (s *codexSupervisor) WebSocketDialer(timeout time.Duration) (websocket.Dialer, error) {
	transport, err := s.current()
	if err != nil {
		return websocket.Dialer{}, err
	}
	return transport.WebSocketDialer(timeout)
}

// Shutdown is also called by the router while draining its gateway connections.
func (s *codexSupervisor) Shutdown() { _ = s.shutdown() }

func (s *codexSupervisor) shutdown() error {
	s.cancel()
	<-s.done
	return s.shutdownErr
}
