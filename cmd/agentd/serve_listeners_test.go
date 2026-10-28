package main

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"reflect"
	"syscall"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
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

func TestServeListenersKeepFatalErrorsAndCloseOpenedListeners(t *testing.T) {
	for _, cause := range []error{syscall.EADDRINUSE, syscall.EACCES, syscall.EAFNOSUPPORT, syscall.EPROTONOSUPPORT, errors.New("unknown bind failure")} {
		t.Run(cause.Error(), func(t *testing.T) {
			cfg := config.Config{Listen: "100.64.0.2:8787"}
			local := &startupTestListener{address: "127.0.0.1:8787"}
			listeners, localOnly, err := bindServeListeners(cfg, []string{local.address, cfg.Listen}, func(_ config.Config, address string) (net.Listener, error) {
				if address == cfg.Listen {
					return nil, startupBindError(cause)
				}
				return local, nil
			})
			if !errors.Is(err, cause) || localOnly || len(listeners) != 0 || local.closed != 1 {
				t.Fatalf("fatal error swallowed or listener leaked: err=%v localOnly=%t listeners=%v closed=%d", err, localOnly, listeners, local.closed)
			}
		})
	}
}

func TestServeListenersRequireSuccessfulPlannedLoopback(t *testing.T) {
	cfg := config.Config{Listen: "100.64.0.2:8787"}
	for _, localErr := range []error{nil, syscall.EADDRNOTAVAIL, syscall.EADDRINUSE, syscall.EACCES} {
		t.Run(fmt.Sprint(localErr), func(t *testing.T) {
			listeners, localOnly, err := bindServeListeners(cfg, moduleListenAddresses(cfg), func(_ config.Config, address string) (net.Listener, error) {
				if address == cfg.Listen {
					return nil, startupBindError(syscall.EADDRNOTAVAIL)
				}
				// A nil listener is not a successful recovery bind.
				return nil, localErr
			})
			want := localErr
			if want == nil {
				want = syscall.EADDRNOTAVAIL
			}
			if !errors.Is(err, want) || localOnly || len(listeners) != 0 {
				t.Fatalf("claimed recovery without loopback: %v %t %v", listeners, localOnly, err)
			}
		})
	}
}

func TestServeListenersDoNotRecoverOtherPlans(t *testing.T) {
	on, off := true, false
	cases := []struct {
		name string
		cfg  config.Config
		plan []string
	}{
		{"LAN", config.Config{Listen: "192.168.50.2:8787"}, nil},
		{"other ULA", config.Config{Listen: "[fd7a:115c:a1e1::2]:8787"}, nil},
		{"hostname", config.Config{Listen: "host.example:8787"}, nil},
		{"wildcard", config.Config{Listen: "0.0.0.0:8787"}, nil},
		{"IPv6 wildcard", config.Config{Listen: "[::]:8787"}, nil},
		{"loopback", config.Config{Listen: "127.0.0.1:8787"}, nil},
		{"malformed", config.Config{Listen: "bad-address"}, nil},
		{"LAN enabled", config.Config{Listen: "100.64.0.2:8787", Network: config.NetworkConfig{AllowLAN: true}}, nil},
		{"module on", config.Config{Listen: "100.64.0.2:8787", Network: config.NetworkConfig{AllowTailscale: &on}}, nil},
		{"module off", config.Config{Listen: "100.64.0.2:8787", Network: config.NetworkConfig{AllowTailscale: &off}}, nil},
		{"no loopback", config.Config{Listen: "100.64.0.2:8787"}, []string{"100.64.0.2:8787"}},
		{"wrong port", config.Config{Listen: "100.64.0.2:8787"}, []string{"100.64.0.2:8787", "127.0.0.1:8788"}},
		{"extra listener", config.Config{Listen: "100.64.0.2:8787"}, []string{"100.64.0.2:8787", "127.0.0.1:8787", "192.168.50.2:8787"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			plan := tc.plan
			if plan == nil {
				plan = moduleListenAddresses(tc.cfg)
			}
			var calls []string
			listeners, localOnly, err := bindServeListeners(tc.cfg, plan, func(_ config.Config, address string) (net.Listener, error) {
				calls = append(calls, address)
				return nil, startupBindError(syscall.EADDRNOTAVAIL)
			})
			if !errors.Is(err, syscall.EADDRNOTAVAIL) || localOnly || len(listeners) != 0 || len(calls) != 1 {
				t.Fatalf("unexpected recovery: %v %t %v calls=%v", listeners, localOnly, err, calls)
			}
		})
	}
}

func TestServeListenersSuccessAndRecoveryInEitherOrder(t *testing.T) {
	cfg := config.Config{Listen: "100.64.0.2:8787"}
	for _, reverse := range []bool{false, true} {
		for _, unavailable := range []bool{false, true} {
			t.Run(fmt.Sprintf("reverse=%t/unavailable=%t", reverse, unavailable), func(t *testing.T) {
				plan := moduleListenAddresses(cfg)
				if reverse {
					plan[0], plan[1] = plan[1], plan[0]
				}
				var opened []*startupTestListener
				listeners, localOnly, err := bindServeListeners(cfg, plan, func(_ config.Config, address string) (net.Listener, error) {
					if unavailable && address == cfg.Listen {
						return nil, startupBindError(syscall.EADDRNOTAVAIL)
					}
					l := &startupTestListener{address: address}
					opened = append(opened, l)
					return l, nil
				})
				want := 2
				if unavailable {
					want = 1
				}
				if err != nil || localOnly != unavailable || len(listeners) != want {
					t.Fatalf("bind result: %v %t %v", listeners, localOnly, err)
				}
				for _, l := range opened {
					if l.closed != 0 {
						t.Fatal("closed a live listener")
					}
				}
			})
		}
	}
}

func TestServeListenersModulePolicyAndOptionalIPv6Unchanged(t *testing.T) {
	on := true
	cfg := config.Config{Listen: "100.64.0.2:8787", Network: config.NetworkConfig{AllowTailscale: &on}}
	v4 := &startupTestListener{address: "0.0.0.0:8787"}
	listeners, localOnly, err := bindServeListeners(cfg, moduleListenAddresses(cfg), func(_ config.Config, address string) (net.Listener, error) {
		if address == "[::]:8787" {
			return nil, nil
		} // Existing listenModuleAddress IPv6 skip.
		return v4, nil
	})
	if err != nil || localOnly || len(listeners) != 1 || listeners[0] == v4 {
		t.Fatalf("module policy wrapper lost: %v %t %v", listeners, localOnly, err)
	}
	if err := listeners[0].Close(); err != nil || v4.closed != 1 {
		t.Fatalf("wrapped listener cleanup: %v %d", err, v4.closed)
	}
}

func TestServeListenersCloseRemoteWhenLoopbackFails(t *testing.T) {
	cfg := config.Config{Listen: "100.64.0.2:8787"}
	remote := &startupTestListener{address: cfg.Listen}
	listeners, localOnly, err := bindServeListeners(cfg, moduleListenAddresses(cfg), func(_ config.Config, address string) (net.Listener, error) {
		if address == cfg.Listen {
			return remote, nil
		}
		return nil, startupBindError(syscall.EADDRINUSE)
	})
	if !errors.Is(err, syscall.EADDRINUSE) || localOnly || len(listeners) != 0 || remote.closed != 1 {
		t.Fatalf("loopback failure leaked remote listener: %v %t %v closed=%d", listeners, localOnly, err, remote.closed)
	}
}

func TestServeListenersRecoveryKeepsAuthenticatedLocalControl(t *testing.T) {
	clearAgentdEnvForMainTest(t)
	// Only an ephemeral loopback socket is real; never bind the synthetic tailnet
	// address or start agentd, a runtime, Tailscale, or a service manager.
	local, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer local.Close()
	_, port, err := net.SplitHostPort(local.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	path := writeNetworkToggleConfig(t, net.JoinHostPort("100.64.0.2", port), `{}`)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	off := false
	cfg.Codex.Enabled = &off
	cfg.Claude.Enabled, cfg.Tailcat.Enabled, cfg.Push.Enabled = false, false, false
	listeners, localOnly, err := bindServeListeners(cfg, moduleListenAddresses(cfg), func(_ config.Config, address string) (net.Listener, error) {
		if address == cfg.Listen {
			return nil, startupBindError(syscall.EADDRNOTAVAIL)
		}
		if address != local.Addr().String() {
			t.Fatalf("unexpected bind: %s", address)
		}
		return local, nil
	})
	if err != nil || !localOnly || len(listeners) != 1 {
		t.Fatalf("recovery: %v %t %v", listeners, localOnly, err)
	}
	handler, router := httpapi.NewRouterWithInstallationIDAndOptions(cfg, nil, nil, "test", "synthetic-installation", httpapi.RouterOptions{ConfigPath: path})
	defer router.Shutdown()
	server := &http.Server{Handler: handler, ReadHeaderTimeout: time.Second}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listeners[0]) }()
	defer func() {
		_ = server.Close()
		if err := <-done; !errors.Is(err, http.ErrServerClosed) {
			t.Errorf("HTTP shutdown: %v", err)
		}
	}()
	client := lifecycleHTTPClient()
	defer client.CloseIdleConnections()
	for _, token := range []string{"", "wrong-token", cfg.Auth.Token} {
		req, err := http.NewRequest(http.MethodGet, "http://"+local.Addr().String()+"/api/host/modules", nil)
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		want := http.StatusUnauthorized
		if token == cfg.Auth.Token {
			want = http.StatusOK
		}
		_ = resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("local control status=%d want=%d", resp.StatusCode, want)
		}
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("local control rewrote configuration")
	}
}
