package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	"github.com/gorilla/websocket"
)

// Only Codex clients wait for preparation. Core requests, other assistants and
// daemon lifetime are independent of this transport and its managed child.
type optionalCodex struct {
	done    chan struct{}
	cancel  context.CancelFunc
	stop    sync.Once
	runtime *agentAppServerRuntime
}

func startOptionalCodex(parent context.Context, cfg config.Config, configPath string) *optionalCodex {
	ctx, cancel := context.WithCancel(parent)
	upstream := &optionalCodex{done: make(chan struct{}), cancel: cancel}
	go func() {
		defer close(upstream.done)
		if err := resolveLaunchCodex(ctx, &cfg); err != nil {
			log.Print("Codex CLI unavailable")
			return
		}
		frontDoor, err := prepareMacAppCodexFront(cfg, configPath)
		if err != nil {
			log.Print("Codex front door unavailable")
		}
		if ctx.Err() != nil {
			return
		}
		upstream.runtime, err = prepareAgentAppServerRuntimeWithFrontDoor(ctx, cfg, frontDoor)
		if err != nil {
			log.Print("Codex upstream unavailable")
		}
	}()
	return upstream
}

func (s *optionalCodex) transport() (httpapi.AppServerTransport, error) {
	select {
	case <-s.done:
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
	default:
	}
	return nil, errors.New("Codex app-server 暂不可用")
}

func (s *optionalCodex) EnsureReady(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.done:
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
		<-s.done
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
