package tailscaleinfo

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os/exec"
	"testing"
	"time"
)

func TestTunnelAvailabilityCLIAndDeadline(t *testing.T) {
	for _, tc := range []struct {
		name, stdout, stderr string
		err                  error
		want                 bool
	}{
		{"no CLI", "", "", exec.ErrNotFound, true},
		{"sandbox unavailable", "", "CLI credentials are not available", errors.New("exit status 1"), true},
		{"active", "100.64.0.5", "", nil, true},
		{"signed out", "", "Logged out.", errors.New("exit status 1"), false},
		{"no login despite exit zero", "100.64.0.5", "state: NeedsLogin", nil, false},
		{"stopped on stdout", "state: Stopped", "", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := tunnelAvailable(context.Background(), func(context.Context) ([]byte, error) { return nil, exec.ErrNotFound }, func(ctx context.Context) ([]byte, []byte, error) {
				deadline, ok := ctx.Deadline()
				if !ok || time.Until(deadline) > time.Second {
					t.Fatal("CLI probe lacks its one-second budget")
				}
				return []byte(tc.stdout), []byte(tc.stderr), tc.err
			})
			if got != tc.want {
				t.Fatalf("TunnelAvailable = %t, want %t", got, tc.want)
			}
		})
	}
	t.Run("cancelled parent", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		got := tunnelAvailable(ctx, func(context.Context) ([]byte, error) { return nil, exec.ErrNotFound }, func(context.Context) ([]byte, []byte, error) {
			cancel()
			return nil, nil, context.Canceled
		})
		if got {
			t.Fatal("cancelled request accepted a fallback")
		}
	})
}

func TestAddressSelectionRejectsTailnetPrefixesOnPhysicalInterface(t *testing.T) {
	ip := selectInterfaceIPv4([]interfaceSnapshot{{name: "eth0", flags: net.FlagUp, addrs: []netip.Addr{
		netip.MustParseAddr("100.64.0.5"), netip.MustParseAddr("fd7a:115c:a1e0::5"),
	}}})
	if ip != "" {
		t.Fatalf("selected address on a physical NIC: %s", ip)
	}
}

func TestTunnelAvailabilitySignedOutStatusWinsOverStaleAddress(t *testing.T) {
	got := tunnelAvailable(context.Background(), func(context.Context) ([]byte, error) { return []byte(`{"BackendState":"NeedsLogin"}`), nil },
		func(context.Context) ([]byte, []byte, error) {
			t.Fatal("signed-out status must end the probe")
			return []byte("100.64.0.1"), nil, nil
		})
	if got {
		t.Fatal("signed-out CLI reported an available tunnel")
	}
}

func TestTunnelAvailabilitySignedOutDiagnosticPreventsFallback(t *testing.T) {
	got := tunnelAvailable(context.Background(), func(context.Context) ([]byte, error) { return nil, &exec.ExitError{Stderr: []byte("Logged out.")} },
		func(context.Context) ([]byte, []byte, error) { return []byte("100.64.0.1"), nil, nil })
	if got {
		t.Fatal("ignored explicit sign-out on stderr")
	}
}
