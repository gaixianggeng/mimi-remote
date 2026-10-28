package main

import (
	"errors"
	"net"
	"os"
	"reflect"
	"syscall"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestServeListenersRecoverLegacyTailscaleBind(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	for _, address := range []string{"100.64.0.2:8787", "[fd7a:115c:a1e0::2]:8787", "[::ffff:100.64.0.2]:8787"} {
		t.Run(address, func(t *testing.T) {
			path := writeNetworkToggleConfig(t, address, `{}`)
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			cfg, err := config.Load(path)
			if err != nil {
				t.Fatal(err)
			}
			local := &startupTestListener{address: "127.0.0.1:8787"}
			var calls []string
			listeners, localOnly, err := bindServeListeners(cfg, moduleListenAddresses(cfg), func(_ config.Config, address string) (net.Listener, error) {
				calls = append(calls, address)
				if address == cfg.Listen {
					return nil, startupBindError(syscall.EADDRNOTAVAIL)
				}
				return local, nil
			})
			if err != nil {
				t.Fatalf("stale Tailscale bind must keep loopback recoverable: %v", err)
			}
			if !localOnly || len(listeners) != 1 || listeners[0] != local || local.closed != 0 {
				t.Fatalf("lost recovery listener: localOnly=%t listeners=%v closed=%d", localOnly, listeners, local.closed)
			}
			if !reflect.DeepEqual(calls, []string{address, local.address}) {
				t.Fatalf("bind plan expanded: %v", calls)
			}
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(before) != string(after) || cfg.Listen != address {
				t.Fatal("recovery rewrote persisted configuration")
			}
		})
	}
}

func startupBindError(err error) error {
	return &net.OpError{Op: "listen", Net: "tcp", Err: &os.SyscallError{Syscall: "bind", Err: err}}
}

type startupTestListener struct {
	address string
	closed  int
}

func (l *startupTestListener) Accept() (net.Conn, error) { return nil, errors.New("fake listener") }
func (l *startupTestListener) Close() error              { l.closed++; return nil }
func (l *startupTestListener) Addr() net.Addr {
	address, _ := net.ResolveTCPAddr("tcp", l.address)
	return address
}
